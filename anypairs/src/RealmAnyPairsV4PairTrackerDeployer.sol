// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RealmAnyPairsDividendTrackerQuote} from "./RealmAnyPairsDividendTrackerQuote.sol";
import {RealmAnyPairsDividendTrackerBasket} from "./RealmAnyPairsDividendTrackerBasket.sol";
import {RealmAnyPairsDividendTrackerEthBasket} from "./RealmAnyPairsDividendTrackerEthBasket.sol";
import {RealmAnyPairsDividendTrackerAutoBasket} from "./RealmAnyPairsDividendTrackerAutoBasket.sol";

/// @title RealmAnyPairsV4PairTrackerDeployer
/// @notice External (linked) library holding the creation bytecode of the V4 pair reward trackers, so it
///         is not embedded in the launcher. Called by {RealmAnyPairsV4UnifiedLauncher}.
/// @dev Reached by DELEGATECALL, so `address(this)` is the calling launcher and every CREATE uses it as
///      deployer. The library address is linked into dependents' bytecode (and thus mined salts).
///      Calling it directly just creates an orphan tracker from the library's own address, wired to nothing.
library RealmAnyPairsV4PairTrackerDeployer {
    function deployQuoteTracker(RealmAnyPairsDividendTrackerQuote.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTrackerQuote(c));
    }

    function deployBasketTracker(RealmAnyPairsDividendTrackerBasket.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTrackerBasket(c));
    }

    /// @dev The native rewards-basket tracker. Lives here rather than in {RealmAnyPairsV4TokenDeployer} so
    /// that library's bytecode, and every mined 0x1110 salt depending on it, is unchanged.
    function deployEthBasketTracker(RealmAnyPairsDividendTrackerEthBasket.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTrackerEthBasket(c));
    }

    /// @dev The auto-converting basket tracker, used by every basket launch (pair, native and multi-pair).
    function deployAutoBasketTracker(RealmAnyPairsDividendTrackerAutoBasket.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTrackerAutoBasket(c));
    }
}
