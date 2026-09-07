// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Why a native -> asset conversion is not available. `OK` is the only passing value; the rest
///         exist so a frontend can say WHICH gate the asset failed instead of "not supported".
enum SwapRejection {
    OK,
    /// @dev The `from` side is not on the quote allowlist. Never the creator's fault — it means the
    ///      registry has not been configured for the chain's quote currency.
    QuoteNotAllowed,
    /// @dev The asset is blacklisted. The one admin veto left in the path.
    Blacklisted,
    /// @dev No Uniswap V2 pair exists for quote/asset. Only reachable for the empty (V2) route: an
    ///      asset whose liquidity lives on V3 or V4 answers this until the creator names a route.
    NoPair,
    /// @dev The V2 pair exists but holds less quote-side depth than the threshold for that quote token.
    InsufficientLiquidity,
    /// @dev The route is malformed: an unknown venue tag, a hop count outside the allowed range, a V3
    ///      path that is not a whole number of hops, or a route that does not end at the asset.
    MalformedRoute,
    /// @dev Every field parsed, but a pool the route names is not initialized or holds no liquidity.
    ///      The typo gate: a route that names a pool nobody ever created reads exactly like one that
    ///      names the right pool, until this checks.
    DeadPool,
    /// @dev A middle token on a multi-hop V3 path is not a currency the protocol routes through.
    IntermediateNotAllowed
}

/// @notice One leg of a Uniswap V4 route: where the leg lands, and the three fields that — together
///         with the two currencies — identify the pool it crosses.
/// @dev V4 pools are keyed by `(currency0, currency1, fee, tickSpacing, hooks)`. The two currencies are
///      implied by the route's position, but the other three CANNOT be derived from them: one pair can
///      have any number of pools, and only one of them is the liquid one. That is the whole reason a V4
///      asset needs a route while a V2 asset needs nothing.
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

/// @title ILivoDividendSwapRegistry
/// @notice The venue every dividend payout conversion crosses, and the keeper of the route each token
///         chose for each of its payout assets.
///
/// @dev WHO PICKS THE ROUTE. The token's creator, at creation, once. Livo does not review payout assets
///      and does not maintain an allowlist of them: a creator names the pools their token will convert
///      through, the registry checks that those pools exist and hold liquidity, and that is the whole
///      gate. The frontend's job is to find the candidate routes and show what each one actually
///      delivers; this contract's job is to refuse a route that cannot execute at all.
///
/// @dev WHAT THIS DELIBERATELY DOES NOT CHECK: whether the pool's price tracks the asset's real market.
///      Nothing on-chain can. A creator can point their token at a pool they control and sell their own
///      holders a worthless asset at their own price — which is the same thing the permissionless V2
///      path has always allowed, since a creator can seed a pair to the depth threshold and name it.
///      The mitigations are off-chain and social: the frontend ranks candidates by what they deliver,
///      surfaces price impact, marks every unreviewed asset as unreviewed, and the blacklist below is
///      the one lever for an asset that turns out to be hostile.
///
/// @dev WHY A SEPARATE CONTRACT. Taxable tokens are CLONES: whatever swap code their implementation was
///      compiled with is the code they die with. Putting the venue behind a proxy at an address baked
///      into the token's bytecode as a constant is the only way a fix — a new venue, a blacklisted
///      asset — ever reaches a token that is ALREADY live.
///
/// @dev WHAT THIS COSTS. Every token's dividend conversion flows native currency through one shared
///      upgradeable contract, so whoever can upgrade it can, in principle, take the native sent for a
///      conversion in flight. Bounded per token per conversion by `MAX_DIVIDEND_PER_CONVERSION`, never
///      custodial (the registry holds nothing between calls), and the calling token measures its own
///      balance delta rather than trusting the return value — so the worst case is a failed conversion,
///      which the round machinery already handles.
interface ILivoDividendSwapRegistry {
    /// @notice The token every native -> asset conversion goes through: the V2 router's canonical WETH.
    ///         Exposed so a caller can ask the registry which `quote` its own checks should name.
    function nativeQuoteToken() external view returns (address);

    /// @notice Records the route `msg.sender` will convert into `asset` through, and validates it.
    ///         Called by the token itself during initialization — the token IS the key, so no two
    ///         tokens can collide and a bad route can only ever hurt the token that chose it.
    /// @dev WRITE-ONCE per (token, asset). `initializeEarningsAllocation` runs once on a clone that
    ///      cannot be upgraded, so there is no second call to make; the guard is here anyway because a
    ///      route that could be rewritten later would be a rug lever the creator does not have today.
    /// @dev There is no admin override. A route that rots — its pool drained, its liquidity moved — is
    ///      permanent for that token: conversions fail, the buffer accrues, and after
    ///      `STALE_DIVIDEND_WINDOW` it goes to the treasury rather than to holders. That is the accepted
    ///      cost of removing the review step, and it is why `validateRoute` refuses a dead pool at
    ///      creation, when the mistake is still free to fix.
    /// @param asset the payout asset this route buys
    /// @param route the wire format from `DividendRouteLib` — empty for the permissionless V2 pair, or
    ///        a venue tag followed by that venue's path
    function registerRoute(address asset, bytes calldata route) external;

    /// @notice Whether `route` would be accepted for `asset` right now, and which gate it fails.
    ///         A pure function of the route, so a frontend can check a candidate BEFORE a token exists.
    /// @dev The same call `registerRoute` gates on. Advisory in the sense that liquidity moves between
    ///      the check and the creation — but a route that fails here will fail there.
    function validateRoute(address asset, bytes calldata route) external view returns (SwapRejection rejection);

    /// @notice Whether `token` can still convert into `asset` through the route it registered.
    /// @dev Re-read on EVERY conversion, not just at creation: an asset can be blacklisted, and a pool
    ///      can be drained, long after a token was configured for it.
    function checkSwapSupported(address token, address asset)
        external
        view
        returns (bool supported, SwapRejection rejection);

    /// @notice The route `token` registered for `asset`, in the `DividendRouteLib` wire format. Empty
    ///         means the permissionless V2 pair — which is a real answer, not a missing one.
    /// @dev A keeper needs this to price `minOut`: it names the exact pools the swap will cross.
    function routeOf(address token, address asset) external view returns (bytes memory route);

    /// @notice The V2 pair a conversion would cross when the route is empty, and its quote-side depth.
    /// @dev Answers about the V2 pair ONLY. Read `routeOf` first: a non-empty route crosses the pools it
    ///      names and never this pair.
    /// @return pair `address(0)` when no pair exists
    /// @return quoteDepth quote-side reserve, scaled to native 18-dec units
    function pairFor(address quote, address asset) external view returns (address pair, uint256 quoteDepth);

    /// @notice Buys `asset` with the native currency sent, delivering it to `recipient`, through the
    ///         route the CALLING token registered for it.
    /// @dev REVERTS on any failure — a dead pool, a missed floor, a blacklisted asset. The caller is a
    ///      dividend freeze, which must not lose its buffer to a failed conversion: reverting is what
    ///      keeps the native with the caller, so it wraps this in a low-level call and reads the boolean.
    /// @dev Holds nothing. The asset is forwarded within the same call and the registry's balance of
    ///      both currencies is zero before and after.
    /// @param minOut slippage floor in the ASSET's own decimals. Enforced by the router, not here.
    /// @return out asset delivered to `recipient`, measured as its balance delta so a fee-on-transfer
    ///         asset is counted for what it actually delivered.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient) external payable returns (uint256 out);
}
