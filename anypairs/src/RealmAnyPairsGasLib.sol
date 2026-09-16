// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title RealmAnyPairsGasLib
/// @notice The ONE place the platform-wide tracker stipend cap is written down.
/// @dev Audit round 8 (F4): the 546,000 cap was copied into four places -- the AutoBasket tracker's
/// `MAX_AUTO_SYNC_GAS`, `RealmAnyPairsTokenPlain.attachTracker`, the unified launcher's basket check, and the
/// coins' gas-constant derivations -- but only three of them enforced it, and a drift between the copies would
/// silently invalidate every gas floor derived from it. Constants only: nothing is deployed for this library.
library RealmAnyPairsGasLib {
    /// @notice The most gas any tracker may publish from `balanceSyncGas()`, i.e. the most a coin ever forwards
    /// to one `setBalance`. One quote plus three converting reward tokens (170k + 34k x 4 + 80k x 3).
    /// @dev Every derived floor assumes it: the heaviest `minDebit` is
    /// `546_000 + 546_000/63 + 16_349 = 571,015`, which is what the coins' push reserve and the tax hook's
    /// per-pool `maxCoinTail` are sized from. A tracker above it is refused at launch (the launcher), at
    /// `initTracker` and at `attachTracker` (the coins), and at construction (the AutoBasket tracker).
    uint256 internal constant MAX_TRACKER_STIPEND = 546_000;
}
