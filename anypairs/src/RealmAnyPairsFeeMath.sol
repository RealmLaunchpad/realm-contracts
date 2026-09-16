// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RealmAnyPairsFeeMath
/// @notice The platform fee, carved out of the creator's rate. The trader pays the creator's effective rate, never less than the platform floor; the platform's slice of
/// that total is a share of it, clamped between the floor and a cap, and never more than the total itself:
///
///     total    = max(effectiveRate, floor)
///     platform = min(total, max(floor, min(cap, total * share / BPS)))
///     creator  = total - platform
///
/// With the defaults (share 20%, floor 0.20%, cap 1.00%):
///
///     creator rate | trader pays | platform | creator pool
///        0.00%     |   0.20%     |  0.20%   |   0.00%
///        0.50%     |   0.50%     |  0.20%   |   0.30%
///        1.00%     |   1.00%     |  0.20%   |   0.80%
///        3.00%     |   3.00%     |  0.60%   |   2.40%
///        5.00%     |   5.00%     |  1.00%   |   4.00%
///       30% ramp   |  30.00%     |  1.00%   |  29.00%
///
/// @dev Pure and internal: inlined into the hook, and unit-testable on its own.
library RealmAnyPairsFeeMath {
    uint256 internal constant BPS = 10_000;

    /// @notice What the trader pays on a side, in bps of the trade.
    function totalBps(uint256 effectiveBps, uint256 floorBps) internal pure returns (uint256) {
        return effectiveBps > floorBps ? effectiveBps : floorBps;
    }

    /// @notice The platform's slice of `total`, in bps of the trade. Requires `floorBps <= capBps`, which the hook's
    /// setter enforces; the result is always `<= total`.
    function platformBps(uint256 total, uint256 shareBps, uint256 floorBps, uint256 capBps)
        internal
        pure
        returns (uint256 p)
    {
        p = total * shareBps / BPS;
        if (p > capBps) p = capBps;
        if (p < floorBps) p = floorBps;
        if (p > total) p = total;
    }
}
