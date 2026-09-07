// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
// The universal router is v4-periphery's client, so its `PoolKey` pin is the one `IV4Router` types
// against — building the key from this import avoids the abi round-trip `LivoUniv4BuyBacks` needs for
// the canonical `lib/v4-core` key it gets from `UniswapV4PoolConstants`.
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";

/// @title UniversalRouterVenue
/// @notice Native -> ERC20 swaps on Uniswap V3 and V4, both through the universal router. The V2 leg of
///         the same job lives in `UniswapV2Venue`, which talks to the V2 router directly.
/// @dev ETH-family only: both helpers pay with `msg.value`. A chain whose native currency is an ERC20
///      (Arc) has no counterpart here, which is why `DividendDistribution` refuses a third-asset leg
///      there rather than configuring one that could never convert.
/// @dev Every helper returns `false` instead of reverting when the swap fails. A dividend payout whose pool
///      dies must not take the token's other legs down with it — see `DividendDistribution._freezeLeg`.
/// @dev All functions are `internal` so they inline into the caller's bytecode (no deployed library);
///      `address(this)` inside them is therefore the calling token.
library UniversalRouterVenue {
    /// @notice Universal-router command bytes. `WRAP_ETH` funds the router itself before a V3 swap,
    ///         which — unlike V4 — cannot take native ETH.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant WRAP_ETH = 0x0b;
    uint8 internal constant V4_SWAP = 0x10;

    /// @notice Currency the router treats as the chain's native coin. Every route here starts there.
    address internal constant NATIVE = address(0);

    /// @notice The universal router's "the router itself" recipient sentinel (`Constants.ADDRESS_THIS`).
    address internal constant ROUTER_ITSELF = address(2);

    /// @notice Buys the token an encoded V3 `path` ends at, spending `nativeIn` and delivering the
    ///         proceeds to `address(this)`. A single-hop route is just a two-token `path`.
    /// @dev `path` is Uniswap V3's own encoding — `token (20) | fee (3) | token (20)`, repeating — so it
    ///      is handed to the router untouched. It MUST start at the router's WETH: the `WRAP_ETH`
    ///      command funds the router in WETH, and a path starting anywhere else would spend a balance
    ///      the router does not have. The registry validates that on write, not here.
    /// @param weth the token `path` starts at — the currency `WRAP_ETH` funds the router in, and so the
    ///        currency a partial fill would leave behind there.
    /// @param minOut minimum output in the FINAL token's own decimals.
    /// @return ok false if the swap reverted (dead pool anywhere along the path, slippage floor missed)
    ///         or filled only partially.
    function swapNativeToAssetV3Path(address router, address weth, bytes memory path, uint256 nativeIn, uint256 minOut)
        internal
        returns (bool ok)
    {
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ROUTER_ITSELF, nativeIn);
        // `payerIsUser = false`: the router pays with the WETH the first command just wrapped for it.
        inputs[1] = abi.encode(address(this), nativeIn, minOut, path, false);

        // A DELTA, not an absolute: the router is not supposed to hold anything between calls, but dust
        // somebody else left there must not fail an otherwise good swap of ours.
        uint256 routerHeld = IERC20(weth).balanceOf(router);

        (ok,) = router.call{value: nativeIn}(
            abi.encodeCall(
                IUniversalRouter.execute, (abi.encodePacked(WRAP_ETH, V3_SWAP_EXACT_IN), inputs, block.timestamp)
            )
        );

        // The whole `nativeIn` was wrapped up front, but a V3 exact-in swap stops at the price limit and
        // consumes only what the pool's liquidity could take. The unspent WETH stays in the router, which
        // never refunds and which anyone may sweep — while the caller debits the FULL spend. Refuse the
        // fill instead: `false` here reverts the registry, so the buffer and the native survive intact
        // and the next call retries. Same rule as `_executeAndRequireFullFill` applies to the V4 legs.
        if (ok && IERC20(weth).balanceOf(router) > routerHeld) ok = false;
    }

    /// @notice Buys `asset` on the V4 pool keyed by `(native, asset, fee, tickSpacing, hooks)`, delivering
    ///         it to `address(this)`. Native ETH is `address(0)`, which sorts below every asset, so the
    ///         pool is always native -> asset in `currency0 -> currency1` order.
    /// @param minOut minimum output in the ASSET's own decimals.
    /// @return ok false if the swap reverted (uninitialized pool, slippage floor missed, reverting hook)
    ///         or filled only partially.
    function swapNativeToAssetV4(
        address router,
        address asset,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 nativeIn,
        uint256 minOut
    ) internal returns (bool ok) {
        // The router's params are `uint128`. `nativeIn` is capped far below that by the freeze cap, but
        // `minOut` comes from whoever called `processDividends`: truncating it would SILENTLY weaken the
        // floor they asked for, so an unrepresentable one fails the swap instead.
        if (minOut > type(uint128).max || nativeIn > type(uint128).max) return false;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(asset),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // native (currency0) -> asset (currency1)
                amountIn: uint128(nativeIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, nativeIn); // SETTLE_ALL the native in
        params[2] = abi.encode(key.currency1, minOut); // TAKE_ALL the asset to this contract

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );

        ok = _executeAndRequireFullFill(router, inputs, nativeIn);
    }

    /// @notice Buys the currency at the END of `path` by spending `nativeIn` of the chain's native coin,
    ///         delivering it to `address(this)`. One hop or many: `path` is v4's own `PathKey` chain, so
    ///         `native -> USDG -> xSTOCK` is the same call shape as `native -> asset`.
    /// @dev The one venue that reaches an asset with no native pool of its own. Uniswap V4 pools are
    ///      keyed by `(fee, tickSpacing, hooks)`, which cannot be discovered from the two currencies —
    ///      so unlike the V2 path, somebody has to SUPPLY the route. See `LivoDividendSwapRegistry`.
    /// @param path each hop's destination currency and the pool key fields that identify its pool. Must
    ///        be non-empty; the last hop's `intermediateCurrency` is what the caller receives.
    /// @param minOut minimum output in the FINAL currency's own decimals.
    /// @return ok false if the swap reverted (uninitialized pool anywhere on the path, slippage floor
    ///         missed, reverting hook) or filled only partially.
    function swapNativeToAssetV4Path(address router, PathKey[] memory path, uint256 nativeIn, uint256 minOut)
        internal
        returns (bool ok)
    {
        // Same reason as the single-hop helper: the router's params are `uint128`, and silently
        // truncating a floor the caller asked for would weaken it rather than fail.
        if (minOut > type(uint128).max || nativeIn > type(uint128).max) return false;

        // A one-hop path is a single-pool swap, so send it as one. Not just cheaper: universal routers
        // in the wild disagree about `SWAP_EXACT_IN`'s calldata layout (Robinhood Chain's rejects the
        // encoding Ethereum mainnet's accepts) while `SWAP_EXACT_IN_SINGLE` is understood everywhere.
        // Almost every route is one hop, so this is the branch that actually runs.
        if (path.length == 1) {
            PathKey memory only = path[0];
            return swapNativeToAssetV4(
                router,
                Currency.unwrap(only.intermediateCurrency),
                only.fee,
                only.tickSpacing,
                address(only.hooks),
                nativeIn,
                minOut
            );
        }

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputParams({
                currencyIn: Currency.wrap(NATIVE),
                path: path,
                amountIn: uint128(nativeIn),
                amountOutMinimum: uint128(minOut)
            })
        );
        params[1] = abi.encode(Currency.wrap(NATIVE), nativeIn); // SETTLE_ALL the native in
        params[2] = abi.encode(path[path.length - 1].intermediateCurrency, minOut); // TAKE_ALL the asset out

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params
        );

        ok = _executeAndRequireFullFill(router, inputs, nativeIn);
    }

    /// @dev Runs a single `V4_SWAP` command and reports a PARTIAL FILL as a failure.
    ///      `SETTLE_ALL` settles the debt the swap actually incurred, not `nativeIn`: a pool whose
    ///      liquidity runs out mid-swap fills only part of it and the rest stays in the router, which
    ///      never refunds on its own and which anyone may sweep — while the caller has already debited
    ///      the full spend. Returning `false` reverts the registry, so nothing is stranded: the native
    ///      goes back to the caller with its buffer untouched, and the next call retries.
    /// @dev Measured as a DELTA on the router's own native balance, never an absolute — dust somebody
    ///      else left there is not ours to fail on.
    function _executeAndRequireFullFill(address router, bytes[] memory inputs, uint256 nativeIn)
        private
        returns (bool ok)
    {
        uint256 routerHeld = router.balance;
        (ok,) = router.call{value: nativeIn}(
            abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp))
        );
        if (ok && router.balance > routerHeld) ok = false;
    }
}
