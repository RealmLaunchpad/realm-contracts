// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISwapLpFeeRouter
/// @notice Receives LP fee deposits from `RealmSwapHook` and splits them between the protocol
///         treasury, the token's creator (via the master fee handler), and a future
///         liquidity-reinvestment slice, using a flat 30/70 treasury/creator split.
/// @dev This interface is intentionally minimal so the router implementation can be upgraded
///      without forcing a corresponding hook redeploy. The hook only relies on `depositLpFees`.
///      Future implementations may compute the split from different inputs internally, but the
///      `(token, ethSwapAmount, tokenSwapAmount)` signature must remain stable.
interface ISwapLpFeeRouter {
    /// @notice Routes `msg.value` ETH as LP fees for `token`.
    /// @dev The router derives the swap's avg price from `(ethSwapAmount, tokenSwapAmount)`,
    ///      multiplies it by the token's total supply to obtain the marketcap, looks up the
    ///      corresponding split tier, sends the treasury slice to the configured treasury, and
    ///      forwards the creator slice through `IRealmToken(token).accrueFees`.
    /// @dev MUST revert on any internal transfer failure so the calling hook can apply its own
    ///      try/catch fallback. The router must NOT silently drop funds.
    /// @param token           The Realm token whose LP fees are being routed.
    /// @param ethSwapAmount   ETH the pool exchanged on the swap leg that produced these fees: the
    ///                        input net of the pre-pool fee on a buy, the full ETH output on a sell.
    ///                        Excludes any hook fee skimmed after the pool, so it reflects the pool's
    ///                        execution price regardless of swap direction.
    /// @param tokenSwapAmount Token amount that crossed the pool during the same swap leg.
    function depositLpFees(address token, uint256 ethSwapAmount, uint256 tokenSwapAmount) external payable;

    /// @notice Routes `amount` of `asset` as LP fees for `token`, for a pool quoted in an ERC20 rather
    ///         than the chain's native currency.
    /// @dev PULLS: the caller must have approved this contract for `amount` beforehand. Same split,
    ///      same destinations and the same MUST-revert-on-failure contract as the payable overload, so
    ///      the calling hook's own try/catch fallback still governs what happens to a fee this refuses.
    /// @param asset           The pool's quote currency. `address(0)` is rejected — use the payable
    ///                        overload for native.
    /// @param amount          Fee to pull and split. What actually ARRIVES is what gets split, so a
    ///                        fee-on-transfer quote is handled without over-crediting anyone.
    /// @param quoteSwapAmount Quote the pool exchanged on the swap leg that produced these fees — the
    ///                        `ethSwapAmount` analogue.
    /// @param tokenSwapAmount Token amount that crossed the pool during the same swap leg.
    function depositLpFees(
        address token,
        address asset,
        uint256 amount,
        uint256 quoteSwapAmount,
        uint256 tokenSwapAmount
    ) external;
}
