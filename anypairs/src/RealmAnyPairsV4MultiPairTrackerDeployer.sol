// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RealmAnyPairsDividendTrackerMultiBasket} from "./RealmAnyPairsDividendTrackerMultiBasket.sol";

/// @title RealmAnyPairsV4MultiPairTrackerDeployer
/// @notice External (linked) library holding the creation bytecode of the multi-pair tracker. Called by
///         {RealmAnyPairsV4UnifiedLauncher.launchMultiPair}.
/// @dev Kept separate from {RealmAnyPairsV4PairTrackerDeployer} because dependents link each library's
///      address, so merging them would change linked bytecode and invalidate mined CREATE2 salts.
library RealmAnyPairsV4MultiPairTrackerDeployer {
    function deployMultiBasketTracker(RealmAnyPairsDividendTrackerMultiBasket.Config memory c)
        external
        returns (address)
    {
        return address(new RealmAnyPairsDividendTrackerMultiBasket(c));
    }
}
