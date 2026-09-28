// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice One leg of a Uniswap V4 route: where the leg lands, and the three fields that — together
///         with the two currencies — identify the pool it crosses.
/// @dev V4 pools are keyed by `(currency0, currency1, fee, tickSpacing, hooks)`. The two currencies are
///      implied by the route's position, but the other three CANNOT be derived from them: one pair can
///      have any number of pools, and only one of them is the liquid one.
/// @dev Mirrors v4-periphery's `PathKey` minus `hookData`, which is always empty here: a route is
///      configuration, not a place to hand arbitrary calldata to somebody's hook.
struct Hop {
    /// @dev Currency this leg buys. The LAST hop's currency is the dividend asset itself.
    address currency;
    /// @dev LP fee of the pool, in pips. `0x800000` for a dynamic-fee pool.
    uint24 fee;
    int24 tickSpacing;
    /// @dev `address(0)` for a hookless pool.
    address hooks;
}

/// @title IRealmDividendSwapRegistry
/// @notice The venue every dividend payout conversion crosses, and the ONE place its routes live.
///
/// @dev WHO PICKS THE ROUTE. The token's creator, at creation, per payout asset: the token registers
///      it here (`registerRoute`), keyed by the token, so no creator can affect another token's routes.
///      A registry admin can repoint any of them afterwards, per token or for every token paying an
///      asset at once, which is the fix for a route that was wrong or whose pool drained. Any ERC20 can
///      be a payout asset; one without a route simply does not convert until it gets one.
interface IRealmDividendSwapRegistry {
    /// @notice The buy route `token` converts native into `asset` through, in the `DividendRouteLib`
    ///         wire format: the admin override if set, else the token's own. Empty: none.
    function routeOf(address token, address asset) external view returns (bytes memory route);

    /// @notice The V4 route `token` sells its ERC20 `quote` into native through, walked backwards: the
    ///         admin override, else the token's own quote route, else `routeOf(token, quote)`.
    function quoteRouteOf(address token, address quote) external view returns (bytes memory route);

    /// @notice Registers the caller's buy route for `asset`. Called by a token at creation; write-once
    ///         per (caller, asset). Shape-checked only.
    function registerRoute(address asset, bytes calldata route) external;

    /// @notice Registers the caller's quote (sell) route for `quote`. V4 only; otherwise as
    ///         `registerRoute`.
    function registerQuoteRoute(address quote, bytes calldata route) external;

    /// @notice Buys `asset` with `msg.value` through its route and sends it to `recipient`.
    /// @param minOut floor on the asset received, net of the keeper's cut.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient) external payable returns (uint256 out);

    /// @notice Pulls `amountIn` of `source` from the caller, sells it to native along the caller's
    ///         `quoteRouteOf(source)` walked backwards, and buys `asset` with the proceeds (`asset == address(0)`: delivers the
    ///         native itself).
    function swapAssetToAsset(address source, address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out);
}
