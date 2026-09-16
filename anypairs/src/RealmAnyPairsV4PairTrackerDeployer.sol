// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RealmAnyPairsDividendTrackerQuote} from "./RealmAnyPairsDividendTrackerQuote.sol";
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

    // REMOVED (audit round 9 cleanup): `deployEthBasketTracker`. Nothing called it. The unified launcher's
    // `_deployNativeBasketTracker` (named `_deployEthBasketTracker` until round 17) only reads the native basket's
    // legs and then builds an AUTO-basket tracker
    // ({deployAutoBasketTracker}), which is what every basket launch has deployed since round 108. Keeping the
    // function meant embedding a whole tracker's creation bytecode in this library for no caller.
    // {RealmAnyPairsDividendTrackerEthBasket} and {RealmAnyPairsDividendTrackerMultiBasket} were deleted outright
    // in round 17 for the same reason; the launcher's `Leg` calldata types now name
    // {RealmAnyPairsDividendTrackerAutoBasket}, the contract every basket launch actually deploys.

    // REMOVED (audit round 17): `deployBasketTracker`. Its only caller was the test-harness
    // {RealmAnyPairsV4PairLauncherImmutable}, itself deleted in the same round -- no production path ever reached
    // it. It embedded {RealmAnyPairsDividendTrackerBasket}'s entire creation bytecode in this size-critical,
    // salt-linked library for nothing. That tracker was then deleted too, once removing its only deployer left it
    // constructible from nowhere. THREE TRACKER VARIANTS REMAIN: {RealmAnyPairsDividendTracker} (native),
    // {RealmAnyPairsDividendTrackerQuote} and {RealmAnyPairsDividendTrackerAutoBasket}.

    /// @dev The auto-converting basket tracker, used by every basket launch (pair, native and multi-pair).
    function deployAutoBasketTracker(RealmAnyPairsDividendTrackerAutoBasket.Config memory c) external returns (address) {
        return address(new RealmAnyPairsDividendTrackerAutoBasket(c));
    }
}
