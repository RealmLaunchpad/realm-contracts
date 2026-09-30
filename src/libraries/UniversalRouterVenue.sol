// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
// The universal router is v4-periphery's client, so its `PoolKey` pin is the one the router's params type
// against — building the key from this import avoids the abi round-trip `RealmUniv4BuyBacks` needs for
// the canonical `lib/v4-core` key it gets from `UniswapV4PoolConstants`.
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniversalRouterVenue
/// @notice Native -> ERC20 swaps on Uniswap V3 and V4, both through the universal router. The V2 leg of
///         the same job lives in `UniswapV2Venue`, which talks to the V2 router directly.
/// @dev Both helpers pay with `msg.value`.
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
        // The trailing array is the V3 twin of `IV4RouterSwaps`'s `minHopPriceX36`: the deployed router
        // decodes this input as `(address, uint256, uint256, bytes, bool, uint256[])` and slices index 5
        // unconditionally, so omitting it reverts with `SliceOutOfBounds()` before the swap is reached.
        // Zero-filled, one per hop — a V3 path is `token (20) | fee (3)` repeating, then a final token.
        inputs[1] = abi.encode(address(this), nativeIn, minOut, path, false, new uint256[]((path.length - 20) / 23));

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
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // native (currency0) -> asset (currency1)
                // Safe cast: both bounded by `type(uint128).max` above.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(nativeIn),
                // forge-lint: disable-next-line(unsafe-typecast)
                amountOutMinimum: uint128(minOut),
                minHopPriceX36: 0,
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
    ///      so unlike the V2 path, somebody has to SUPPLY the route. See `RealmDividendSwapRegistry`.
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
            IV4RouterSwaps.ExactInputParams({
                currencyIn: Currency.wrap(NATIVE),
                path: path,
                minHopPriceX36: new uint256[](path.length),
                // Safe cast: both bounded by `type(uint128).max` above.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(nativeIn),
                // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @dev The reverse leg: `amountIn` of `source` -> native along `path`, which is a native-anchored
    ///      route already REVERSED by the caller (each hop's `intermediateCurrency` is that hop's OUTPUT,
    ///      the last one native). The router pulls `source` through Permit2, so the caller must have
    ///      granted `ensureRouterPull` first. Same `uint128` rule and the same one-hop special case as
    ///      the forward legs. NOT the same full-fill rule: Permit2 pulls straight from the caller only
    ///      what the swap owes, so a partial fill's remainder stays with the CALLER and `ok` stays true.
    ///      A caller that needs a full fill measures its own `source` balance delta.
    function swapAssetToNativeV4Path(
        address router,
        address source,
        PathKey[] memory path,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (bool ok) {
        if (minOut > type(uint128).max || amountIn > type(uint128).max) return false;
        bytes[] memory params = new bytes[](3);
        bool single = path.length == 1;
        if (single) {
            PathKey memory only = path[0];
            // Native is `address(0)`, so it is always `currency0`; the source sells as `currency1`.
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(NATIVE),
                currency1: Currency.wrap(source),
                fee: only.fee,
                tickSpacing: only.tickSpacing,
                hooks: only.hooks
            });
            params[0] = abi.encode(
                IV4RouterSwaps.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: false,
                    // Safe cast: both bounded by `type(uint128).max` above.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountIn: uint128(amountIn),
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountOutMinimum: uint128(minOut),
                    minHopPriceX36: 0,
                    hookData: bytes("")
                })
            );
        } else {
            params[0] = abi.encode(
                IV4RouterSwaps.ExactInputParams({
                    currencyIn: Currency.wrap(source),
                    path: path,
                    minHopPriceX36: new uint256[](path.length),
                    // Safe cast: both bounded by `type(uint128).max` above.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountIn: uint128(amountIn),
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountOutMinimum: uint128(minOut)
                })
            );
        }
        params[1] = abi.encode(Currency.wrap(source), amountIn); // SETTLE_ALL the source, pulled via Permit2
        params[2] = abi.encode(Currency.wrap(NATIVE), minOut); // TAKE_ALL the native to this contract
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(
                uint8(single ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_IN),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );
        uint256 routerHeld = IERC20(source).balanceOf(router);
        (ok,) =
            router.call(abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(V4_SWAP), inputs, block.timestamp)));
        if (ok && IERC20(source).balanceOf(router) > routerHeld) ok = false;
    }

    /// @dev Grants Permit2, and through it `router`, the standing allowance an ERC20 settle needs. Read
    ///      then write: after the first pull of a given token both allowances are at their maximum, and
    ///      re-issuing them would cost two SSTOREs and two logs per swap.
    function ensureRouterPull(address permit2, address router, address token) internal {
        if (IERC20(token).allowance(address(this), permit2) == 0) {
            SafeERC20.forceApprove(IERC20(token), permit2, type(uint256).max);
        }
        (uint160 allowed,,) = IAllowanceTransfer(permit2).allowance(address(this), token, router);
        if (allowed == 0) {
            IAllowanceTransfer(permit2).approve(token, router, type(uint160).max, type(uint48).max);
        }
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
