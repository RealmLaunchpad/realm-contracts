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
/// @dev WHO PICKS THE ROUTE. A registry admin, per asset. Tokens name only their payout assets, never a
///      route, so a route that turns out wrong or whose pool drains is repointed here, once, for every
///      token paying that asset — existing ones included. Any ERC20 can be a payout asset; one without a
///      route simply does not convert until an admin sets one.
interface IRealmDividendSwapRegistry {
    /// @notice The route `asset` converts through, in the `DividendRouteLib` wire format. Empty: none,
    ///         so conversions into `asset` fail until one is set.
    function routeOf(address asset) external view returns (bytes memory route);

    /// @notice Buys `asset` with `msg.value` through its route and sends it to `recipient`.
    /// @param minOut floor on the asset received, net of the keeper's cut.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient) external payable returns (uint256 out);

    /// @notice Pulls `amountIn` of `source` from the caller, sells it to native along `source`'s route
    ///         walked backwards, and buys `asset` with the proceeds (`asset == address(0)`: delivers the
    ///         native itself).
    function swapAssetToAsset(address source, address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out);
}
