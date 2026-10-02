// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IRealmLpLocker
/// @notice The immutable custodian of every protocol-owned Realm V4 position (launch seed bands and
///         bid walls). Its only outflow is the fees those positions earn.
interface IRealmLpLocker {
    /// @notice `tokenId` now belongs to `token`'s set: its launch seed (`isWall == false`) or a bid wall.
    event PositionRegistered(address indexed token, address indexed quote, uint256 tokenId, bool isWall);

    /// @notice Fees collected from `token`'s positions in its `quote` pool. `quoteAmount` was routed
    ///         straight to the LP fee router's split; `tokenAmount` went to its pending bucket, which a
    ///         keeper converts into `quote` (`SwapLpFeeRouter.convertTokenFees`).
    event LpFeesCollected(address indexed token, address indexed quote, uint256 quoteAmount, uint256 tokenAmount);

    /// @notice Collects the fees of every position each of `tokens` has here. Permissionless.
    function collect(address[] calldata tokens) external;

    /// @notice Places or tops up the caller's bid wall in its `quote` pool with `amount` of `quote`
    ///         (native: `msg.value`; ERC20: pulled, so the caller approves first). Permissionless:
    ///         positions are keyed by `msg.sender`, so a caller only ever reaches its own.
    /// @return liquidity Liquidity added (0 when nothing was placed).
    /// @return usedTokenId Position that took the deposit, 0 when nothing was placed.
    /// @return usedTickLower Its lower tick, for the token's two-entry wall memory.
    /// @return spent Quote the pool took; the rest was returned to the caller.
    function addWall(address quote, uint256 amount)
        external
        payable
        returns (uint128 liquidity, uint256 usedTokenId, int24 usedTickLower, uint256 spent);

    /// @notice Uncollected fees of `token`'s positions, aggregated per pool (one entry per quote, in the
    ///         order its pools were seeded). Exact: what `collect` would take right now.
    function pendingFees(address token)
        external
        view
        returns (address[] memory quotes, uint256[] memory quoteAmounts, uint256[] memory tokenAmounts);

    /// @notice Registers the launch seed band `tokenId` (already owned by the locker) under `token`.
    ///         Only the graduator that deployed the locker.
    function registerSeed(address token, uint256 tokenId) external;
}
