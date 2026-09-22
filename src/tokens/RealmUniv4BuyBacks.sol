// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Self-aliased so the `chain-arc-*` recipes can import-swap it for the ARC pool constants.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
// The repo vendors TWO v4-core copies: lib/v4-core (used by all Realm contracts, incl.
// `UniswapV4PoolConstants.realmPoolKey`) and v4-periphery's own pin (which types the router's params).
// The structs are field-identical but nominally distinct, so the canonical key is converted at
// this periphery boundary via an abi round-trip (see `_buyBackTokensWithEth`).
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode) — see the justfile `_taxtoken` recipe.
import {DeploymentAddressesRobinhoodTestnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title RealmUniv4BuyBacks
/// @notice Buy-back primitive for Uniswap-V4 Realm tokens: swaps native ETH for THIS token on its own
///         V4 pool via the universal router. Bought tokens are TAKEn to this contract; the inheriting
///         token measures its own balance delta and decides what to do with them (burn, distribute, …).
/// @dev Abstract mixin with no storage. `address(this)` is the token (pool `currency1`); the pool
///      `hook` is supplied by the caller (the token reads it from its graduator). This keeps the
///      fiddly universal-router encoding in one place, reusable by every ETH→token buy-back use case
///      (burn today; dividends/liquidity later).
abstract contract RealmUniv4BuyBacks {
    /// @notice Universal router used for buy-back swaps.
    address public constant UNIV4_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Permit2 — the only way the universal router pulls an ERC20. Untouched by the native
    ///         buy-back, which settles from the forwarded value.
    address public constant PERMIT2 = DeploymentAddresses.PERMIT2;

    /// @notice Universal-router command byte selecting a V4 swap.
    uint8 internal constant V4_SWAP_COMMAND = 0x10;

    /// @notice Universal-router command byte returning the router's leftover native to a recipient. A
    ///         router-LEVEL command, not a v4 action: `V4Router` rejects `Actions.SWEEP` as unsupported.
    uint8 internal constant SWEEP_COMMAND = 0x04;

    /// @dev Buys this token with `ethIn` native ETH on its canonical graduated pool
    ///      (`UniswapV4PoolConstants.realmPoolKey` — the same key the graduator initialized), requiring at
    ///      least `minTokensOut`. Tokens are TAKEn to this contract.
    /// @dev The swap routes through `RealmSwapHook`, which charges the usual LP fee (and, inside the tax
    ///      window, tax). Callers must guard against reentrancy from those hooks themselves.
    /// @dev A LOW-LEVEL call, on purpose, so a router revert becomes `false` here instead of taking down
    ///      the caller. The dividend freeze needs exactly that: it reads "no tokens bought" as "the
    ///      conversion did not happen" and keeps its buffer, and its escape hatch for a pool that has
    ///      stopped swapping altogether is only reachable if the call returns rather than reverts. A
    ///      caller that does want to revert says so itself.
    /// @return ok false if the router reverted or the floor was unrepresentable. Either way — and on a
    ///         partial fill too — the native the pool did not take stays with this contract.
    function _buyBackTokensWithEth(address hook, uint256 ethIn, uint256 minTokensOut) internal returns (bool ok) {
        return _buyBackTokens(hook, address(0), ethIn, minTokensOut);
    }

    /// @dev The general form: buys this token with `amountIn` of `quote` on the pool the two share.
    ///      `quote == address(0)` is the chain's native currency and reproduces `_buyBackTokensWithEth`.
    /// @dev Orientation is resolved from the key, not assumed: against native the token is always
    ///      `currency1`, but against an ERC20 it sorts either way, so `zeroForOne` follows which side
    ///      the QUOTE landed on.
    /// @dev An ERC20 quote is settled through Permit2, the only way the universal router pulls one. The
    ///      two approvals are granted on demand and left at their maximum: this token holds the quote on
    ///      the protocol's behalf either way, and the router can only ever pull what a swap it is
    ///      executing for this token actually owes.
    function _buyBackTokens(address hook, address quote, uint256 amountIn, uint256 minTokensOut)
        internal
        returns (bool ok)
    {
        // The router's params are `uint128`. `amountIn` is capped far below that by the per-call spend
        // cap, but `minTokensOut` comes from whoever called the processor: truncating it would SILENTLY
        // weaken the floor they asked for, so an unrepresentable one fails the swap instead. Same rule
        // as `UniversalRouterVenue.swapNativeToAssetV4`.
        if (minTokensOut > type(uint128).max || amountIn > type(uint128).max) return false;

        // abi round-trip converts the canonical lib/v4-core key into v4-periphery's identical PoolKey.
        PoolKey memory key =
            abi.decode(abi.encode(UniswapV4PoolConstants.realmPoolKey(address(this), quote, hook)), (PoolKey));
        bool quoteIsC0 = quote < address(this);
        (Currency currencyIn, Currency currencyOut) =
            quoteIsC0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        if (quote != address(0)) UniversalRouterVenue.ensureRouterPull(PERMIT2, UNIV4_UNIVERSAL_ROUTER, quote);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: quoteIsC0, // quote -> token, whichever way the pair sorted
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minTokensOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(currencyIn, amountIn); // SETTLE_ALL the quote
        params[2] = abi.encode(currencyOut, minTokensOut); // TAKE_ALL token to this contract

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        // `SETTLE_ALL` settles the debt the swap ACTUALLY incurred, not `amountIn`. A pool that fills
        // only partially — or not at all, which `amountOutMinimum == 0` lets through without a revert —
        // leaves the rest sitting in the router, which never refunds on its own and which anyone may
        // sweep. This brings it back here, so "no tokens bought" also means "the quote is still ours".
        inputs[1] = abi.encode(quote, address(this), uint256(0)); // SWEEP the quote, no minimum

        (ok,) = UNIV4_UNIVERSAL_ROUTER.call{value: quote == address(0) ? amountIn : 0}(
            abi.encodeCall(
                IUniversalRouter.execute, (abi.encodePacked(V4_SWAP_COMMAND, SWEEP_COMMAND), inputs, block.timestamp)
            )
        );
    }
}
