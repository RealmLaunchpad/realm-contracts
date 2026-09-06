// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";

/// @notice A bare `DividendDistributionLogic` whose balances move through `_onDividendTransfer`, in the
///         order a real token's `_update` moves them: SETTLE FIRST, then mutate. That order is the whole
///         of the anti-sandwich argument, so the harness has to reproduce it exactly — a harness that
///         mutated first would quietly test a different (and broken) contract.
contract StreamHarness is DividendDistributionLogic {
    mapping(address account => uint256 balance) public balances;
    uint256 public eligibleSupply;

    /// @dev Every address that has ever held a balance. Only a test harness can afford this — it is
    ///      exactly the holder set the production contract deliberately refuses to store.
    address[] public tracked;
    mapping(address account => bool) internal seen;

    address[3] internal excluded;

    function configure(address asset) external {
        (address[] memory assets, uint16[] memory weights) = _soleAssetSet(asset);
        assetCount = _initializeDividends(assets, weights);
    }

    /// @dev How many payout assets the harness was configured with. The production token keeps this in
    ///      its `pair` slot; here it is plain storage.
    uint8 public assetCount;

    function _dividendAssetCount() internal view override returns (uint256) {
        return assetCount;
    }

    /// @notice Configure a multi-asset payout set, as `initializeEarningsAllocation`'s array overload does.
    function configureMulti(address[] calldata assets, uint16[] calldata weights) external {
        assetCount = _initializeDividends(assets, weights);
    }

    function activate() external {
        _activateDividends();
    }

    /// @dev The supply floor is `internal` in production (nothing outside needs it); the harness exposes
    ///      it so the pause test asserts against the real constant rather than a copy of it.
    function minDividendSupply() external pure returns (uint256) {
        return MIN_DIVIDEND_SUPPLY;
    }

    function accrue() external payable {
        _accrueDividends(msg.value);
    }

    function exclude(uint256 index, address account) external {
        excluded[index] = account;
    }

    /// @dev Seeds a balance without settling, standing in for supply that existed before dividends went
    ///      live (the bonding-curve distribution).
    function seed(address to, uint256 value) external {
        _remember(to);
        if (!_dividendExcluded(to)) eligibleSupply += value;
        balances[to] += value;
    }

    /// @dev A transfer as the token performs it: settle against the accumulator at PRE-transfer balances
    ///      and the PRE-transfer eligible supply, then move.
    function transfer(address from, address to, uint256 amount) external {
        _onDividendTransfer(from, to);

        balances[from] -= amount;
        balances[to] += amount;
        if (!_dividendExcluded(from)) eligibleSupply -= amount;
        if (!_dividendExcluded(to)) eligibleSupply += amount;
        _remember(to);
    }

    /// @notice `Σ previewDividend(a)` over every address that has ever held — what `dividendsOwed`
    ///         claims to cover. The whole solvency argument is this inequality.
    function sumOfPreviews() external view returns (uint256 total) {
        for (uint256 i; i < tracked.length; ++i) {
            total += previewDividend(tracked[i]);
        }
    }

    function _remember(address account) internal {
        if (account == address(0) || seen[account]) return;
        seen[account] = true;
        tracked.push(account);
    }

    /// @dev Single-asset conveniences the production token dropped to stay inside EIP-170. A harness is
    ///      not size-bound, so the tests keep reading them by name.
    function dividendRate() external view returns (uint96) {
        return dividendAssets[0].rate;
    }

    function dividendPrecisionExp() external view returns (uint8) {
        return dividendAssets[0].precisionExp;
    }

    function failedConversionBlock() external view returns (uint40) {
        return dividendAssets[0].failedConversionBlock;
    }

    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balances[account];
    }

    function _dividendExcluded(address account) internal view override returns (bool) {
        return account == excluded[0] || account == excluded[1] || account == excluded[2];
    }

    function _dividendEligibleSupply() internal view override returns (uint256) {
        return eligibleSupply;
    }

    receive() external payable {}
}

/// @notice A flash borrower: takes a balance and gives it back inside ONE transaction, poking the
///         accumulator on the way through. The whole design exists to make this worth zero.
contract FlashBorrower {
    StreamHarness public immutable H;

    constructor(StreamHarness h) {
        H = h;
    }

    /// @dev Borrow, touch the accumulator as many times as the attacker likes, repay. No time passes.
    function attack(address lender, uint256 amount, uint256 pokes) external {
        H.transfer(lender, address(this), amount);
        for (uint256 i; i < pokes; ++i) {
            H.transfer(address(this), address(this), 0);
        }
        H.transfer(address(this), lender, amount);
    }

    receive() external payable {}
}

/// @notice Rejects every native payout. Stands in for a holder whose `receive()` reverts — the case the
///         skip-don't-revert branch and the `NATIVE_PAYOUT_GAS` stipend exist for.
contract RejectingHolder {
    receive() external payable {
        revert("no thanks");
    }
}

/// @notice Burns far more gas than `NATIVE_PAYOUT_GAS` allows, so the send fails on the stipend rather
///         than on an explicit revert. A holder must not be able to grief a batch this way either.
contract GasGuzzlingHolder {
    uint256[] internal sink;

    receive() external payable {
        for (uint256 i; i < 200; ++i) {
            sink.push(i);
        }
    }
}

/// @notice Reenters the payout entry points from inside `receive()`. The transient
///         `nonReentrantDividends` guard must make the reentrant call revert, and the outer batch must
///         still settle without paying anyone twice.
/// @dev The reentrant call is wrapped in `try` deliberately. Letting it bubble would revert this
///      `receive()`, which the payout treats as a failed send — the attacker would be skipped and the
///      test would prove nothing about the guard. Swallowing it lets the attacker be paid its honest
///      share while `blockedReentries` records that the second entry was refused.
contract ReenteringHolder {
    DividendDistributionLogic public immutable TARGET;
    bool public useClaim;
    uint256 public blockedReentries;

    constructor(DividendDistributionLogic target) {
        TARGET = target;
    }

    function setUseClaim(bool value) external {
        useClaim = value;
    }

    receive() external payable {
        if (useClaim) {
            try TARGET.claimDividends() {}
            catch {
                ++blockedReentries;
            }
        } else {
            address[] memory batch = new address[](1);
            batch[0] = address(this);
            try TARGET.processDividends(0, batch) {}
            catch {
                ++blockedReentries;
            }
        }
    }
}

/// @notice The dividend accumulator's accounting identity and the payout-path safety properties,
///         exercised against a bare `DividendDistribution` so the assertions are about the module rather
///         than about a pool.
contract DividendAccountingTests is Test {
    StreamHarness internal h;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public {
        // `processDividends` is keeper-gated and fails closed without a registry to ask.
        installKeepersRegistry(address(this), address(this));

        h = new StreamHarness();
        h.configure(address(0));
    }

    function _live() internal {
        h.seed(alice, SUPPLY / 2);
        h.seed(bob, SUPPLY / 4);
        h.seed(carol, SUPPLY / 4);
        h.activate();
    }

    /// @dev Fresh earnings arrive in a new block: the funding leg of `processDividends` is once per
    ///      block, and none of these tests is about two conversions racing inside one.
    function _fund(uint256 amount) internal {
        vm.roll(block.number + 1);
        vm.deal(address(this), amount);
        h.accrue{value: amount}();
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _batch(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _everyone() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (alice, bob, carol);
    }

    /// @dev Funds the stream and lets it drip all the way out — one full distribution cycle.
    function _distribute(uint256 amount) internal {
        _fund(amount);
        h.processDividends(0, _noHolders());
        skip(h.DIVIDEND_DRIP_DURATION());
    }

    receive() external payable {}

    ///////////////////////// the flash-loan property /////////////////////////

    /// @dev THE property the whole design exists for. A borrowed balance exists for zero seconds, and
    ///      the accumulator integrates `balance x time`, so its integrand is zero however the rest of the
    ///      transaction is arranged: however many times it pokes the accumulator, whichever order it
    ///      borrows and repays in, whether or not a distribution lands in the same block.
    function test_aFlashLoanedBalanceEarnsExactlyZero() public {
        _live();
        _fund(1 ether);
        h.processDividends(0, _noHolders());
        skip(h.DIVIDEND_DRIP_DURATION() / 2); // mid-stream, so real money is in flight

        FlashBorrower borrower = new FlashBorrower(h);
        borrower.attack(alice, SUPPLY / 2, 3);

        assertEq(h.previewDividend(address(borrower)), 0, "a zero-duration balance accrues nothing");

        h.processDividends(0, _batch(address(borrower)));
        assertEq(address(borrower).balance, 0, "and is paid nothing");
    }

    /// @dev The same, when the borrower funds the distribution ITSELF inside the borrowed window — the
    ///      sandwich the old round machinery needed a minimum round age to rule out. There is no
    ///      instant to sandwich any more: the money arrives as a slope.
    function test_aFlashLoanCannotSandwichItsOwnDistribution() public {
        _live();
        _fund(1 ether);
        skip(h.DIVIDEND_DRIP_DURATION() / 2);

        address borrower = makeAddr("borrower");
        h.transfer(alice, borrower, SUPPLY / 2); // borrow
        h.processDividends(0, _noHolders()); // fund, in the same block
        address[] memory batch = _batch(borrower);
        h.processDividends(0, batch); // and try to take it
        h.transfer(borrower, alice, SUPPLY / 2); // repay

        assertEq(borrower.balance, 0, "borrowing across the funding instant is still worth nothing");
    }

    /// @dev The OTHER half of the ordering rule, and the one a wrong implementation would fail. The
    ///      accumulator divides the elapsed interval by the eligible supply read at settle time; if the
    ///      settle ran AFTER the mutation, an attacker could collapse the denominator inside their own
    ///      transaction and harvest a real interval at an inflated rate. Settling first books the
    ///      pending interval at the supply that was actually in effect for it.
    function test_shrinkingEligibleSupplyCannotInflateThePendingInterval() public {
        address sink = makeAddr("sink");
        h.exclude(0, sink);
        _live();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        // Half the stream elapses with nobody touching the contract, so a full interval is pending.
        skip(h.DIVIDEND_DRIP_DURATION() / 2);

        // A second, untouched harness run as the control: same stream, no denominator games.
        uint256 honest = h.previewDividend(bob);

        // Alice dumps 90% of the eligible supply into an excluded address and immediately settles.
        h.transfer(alice, sink, SUPPLY / 2);
        h.transfer(carol, sink, SUPPLY / 5);
        uint256 afterShrink = h.previewDividend(bob);

        assertEq(afterShrink, honest, "the pending interval was booked at the pre-shrink supply");
        assertLt(h.eligibleSupply(), SUPPLY / 2, "and the supply really did collapse");
    }

    ///////////////////////// the accrual identity /////////////////////////

    /// @dev Accrual is proportional to balance across a fully-dripped stream. Everything else is
    ///      downstream of this: a holder with half the eligible supply for the whole window earns half.
    function test_accrualIsProportionalToBalanceOverTheStream() public {
        _live();
        _distribute(1 ether);

        uint256 a = h.previewDividend(alice);
        uint256 b = h.previewDividend(bob);
        uint256 c = h.previewDividend(carol);

        assertApproxEqRel(a, 0.5 ether, 1e12, "half the supply earns half the stream");
        assertApproxEqRel(b, 0.25 ether, 1e12, "a quarter earns a quarter");
        assertEq(b, c, "equal balances earn equally");
        assertLe(a + b + c, h.dividendsOwed(), "and the parts never exceed the whole");
    }

    /// @dev Arriving halfway through a stream earns from the moment of arrival, not from its start. The
    ///      drip is a smoothing window, never an eligibility gate — a newcomer is not "too new", they
    ///      simply have less time under the integral.
    function test_aMidStreamArrivalEarnsOnlyItsOwnTail() public {
        h.seed(alice, SUPPLY);
        h.activate();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        skip(h.DIVIDEND_DRIP_DURATION() / 2);
        h.transfer(alice, bob, SUPPLY / 2); // bob arrives at the halfway mark
        skip(h.DIVIDEND_DRIP_DURATION() / 2);

        // Second half of the stream (0.5 ether) split evenly; alice also has the whole first half.
        assertApproxEqRel(h.previewDividend(bob), 0.25 ether, 1e12, "half of the second half");
        assertApproxEqRel(h.previewDividend(alice), 0.75 ether, 1e12, "the rest");
    }

    /// @dev Solvency, stated directly: what the module has promised holders never exceeds what it has
    ///      been given. The accumulator truncates at every step, so this is an inequality by
    ///      construction, and it has to survive an arbitrary transfer sequence mid-stream.
    function testFuzz_promisedNeverExceedsFunded(uint256[8] calldata seeds, uint96[8] calldata amounts) public {
        _live();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        address[4] memory actors = [alice, bob, carol, makeAddr("dave")];
        for (uint256 i; i < seeds.length; ++i) {
            skip(bound(seeds[i], 1, h.DIVIDEND_DRIP_DURATION() / 4));
            address from = actors[seeds[i] % actors.length];
            address to = actors[(seeds[i] / 7 + 1) % actors.length];
            if (from == to) continue;
            uint256 balance = h.balances(from);
            if (balance == 0) continue;
            h.transfer(from, to, bound(uint256(amounts[i]), 1, balance));
            assertLe(h.sumOfPreviews(), h.dividendsOwed(), "promised never exceeds funded");
        }

        skip(h.DIVIDEND_DRIP_DURATION());
        assertLe(h.sumOfPreviews(), h.dividendsOwed(), "and still not once the stream has run dry");
    }

    /// @dev An excluded address neither accrues nor is payable, and the two halves of that statement
    ///      come from two separately-written functions in the token (`_dividendExcluded` and
    ///      `_dividendEligibleSupply`). They have to agree, or the excluded balance would dilute the
    ///      denominator while earning nothing — under-distributing every stream.
    function test_excludedAddressNeitherCountsNorEarns() public {
        h.exclude(0, carol);
        _live();
        _distribute(1 ether);

        assertEq(h.previewDividend(carol), 0, "an excluded address accrues nothing");
        h.processDividends(0, _batch(carol));
        assertEq(carol.balance, 0, "and is never paid");

        // Alice and bob hold 2:1 of the ELIGIBLE supply, so the whole stream goes to them in that ratio.
        assertApproxEqRel(h.previewDividend(alice), uint256(2 ether) / 3, 1e12, "carol's balance did not dilute");
    }

    ///////////////////////// the stream, and refunding it mid-flight /////////////////////////

    /// @dev A distribution landing mid-stream is the NORMAL case and must never revert. It folds what
    ///      the running stream still owes into the new money and re-spreads the sum over a fresh full
    ///      window: the slope changes, the delivery time stays constant, nothing is deferred.
    function test_fundingMidStreamFoldsTheRemainderAndChangesTheSlope() public {
        _live();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        uint256 firstRate = h.dividendRate();
        skip(h.DIVIDEND_DRIP_DURATION() / 2); // half delivered, ~0.5 ether still owed

        _fund(1 ether);
        h.processDividends(0, _noHolders()); // no revert, no wait, no phase

        assertEq(h.dividendPeriodFinish(), block.timestamp + h.DIVIDEND_DRIP_DURATION(), "a full fresh window from now");
        assertApproxEqRel(h.dividendRate(), firstRate * 3 / 2, 1e12, "slope is (remainder + new) / duration");

        skip(h.DIVIDEND_DRIP_DURATION());
        assertApproxEqRel(h.sumOfPreviews(), 2 ether, 1e12, "and both distributions reach holders in full");
    }

    /// @dev Refunding over and over, faster than the stream can drain, must not lose money or stall it.
    ///      Every fold pushes `periodFinish` out, but the slope rises to match, so the outstanding
    ///      balance decays rather than accumulating.
    function test_repeatedMidStreamFundingDeliversEverything() public {
        _live();
        for (uint256 i; i < 5; ++i) {
            _fund(1 ether);
            h.processDividends(0, _noHolders());
            skip(h.DIVIDEND_DRIP_DURATION() / 3);
        }
        skip(h.DIVIDEND_DRIP_DURATION());

        assertApproxEqRel(h.sumOfPreviews(), 5 ether, 1e12, "everything funded is eventually promised");
        assertEq(h.dividendsOwed(), 5 ether, "and owed matches what went in");
    }

    /// @dev The stream PAUSES below `MIN_DIVIDEND_SUPPLY` — the division guard and the accumulator's
    ///      ceiling in one. Crucially the CLOCK still advances: freezing it would bank the skipped
    ///      seconds and hand them to whoever bought in first once supply recovered, which is exactly the
    ///      just-in-time capture window this design exists not to have.
    function test_streamPausesBelowTheSupplyFloorAndDoesNotBankTheSkippedTime() public {
        address sink = makeAddr("sink");
        h.exclude(0, sink);
        h.seed(alice, SUPPLY);
        h.activate();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        // Alice parks all but a dust balance out of reach, taking eligible supply under the floor.
        h.transfer(alice, sink, SUPPLY - 1);
        assertLt(h.eligibleSupply(), h.minDividendSupply(), "under the floor");

        uint256 before = h.dividendRewardPerToken(0);
        skip(h.DIVIDEND_DRIP_DURATION() / 2);
        assertEq(h.dividendRewardPerToken(0), before, "nothing accrued while paused");

        // Supply comes back. The paused half-window must NOT land on whoever is holding now.
        h.transfer(sink, bob, SUPPLY - 1);
        assertEq(h.previewDividend(bob), 0, "the skipped interval was not banked for a late arrival");
    }

    /// @dev The paused span is DEFERRED, not written off. `dividendsOwed` counted the whole distribution
    ///      when it was funded and is only ever reduced by real payouts, so an interval the accumulator
    ///      skipped would otherwise stay reserved forever: unclaimable by any holder and unreachable by
    ///      every sweep. Extending the finish line by the paused span is what makes it arrive late
    ///      instead of never — and the amount is unbounded, not dust: a stream that spends its whole
    ///      window under the floor would lose all of it.
    function test_aPausedIntervalIsDeliveredLateRatherThanWrittenOff() public {
        address sink = makeAddr("sink");
        h.exclude(0, sink);
        h.seed(alice, SUPPLY);
        h.activate();
        _fund(1 ether);
        h.processDividends(0, _noHolders());

        // Half the window spent under the floor.
        h.transfer(alice, sink, SUPPLY - 1);
        assertLt(h.eligibleSupply(), h.minDividendSupply(), "under the floor");
        skip(h.DIVIDEND_DRIP_DURATION() / 2);

        // Supply recovers; let the (now extended) stream run all the way out.
        h.transfer(sink, alice, SUPPLY - 1);
        skip(h.DIVIDEND_DRIP_DURATION());

        assertApproxEqRel(h.sumOfPreviews(), 1 ether, 1e12, "the paused half is delivered, not lost");
        assertEq(h.dividendsOwed(), 1 ether, "and owed still matches what went in");
    }

    ///////////////////////// the threshold and its bypass /////////////////////////

    /// @dev Below the threshold the buffer keeps accruing rather than funding a stream not worth its gas.
    function test_subThresholdBufferDoesNotFund() public {
        _live();
        _fund(h.DIVIDEND_THRESHOLD() / 2);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processDividends(0, _noHolders());
    }

    /// @dev A call carrying holders pushes their payouts and returns QUIETLY even when the buffer is
    ///      short. A keeper batching payouts must not be punished for the buffer happening not to
    ///      qualify — this is what makes `processDividends(0, holders)` usable as a plain `claimFor`.
    function test_aPushOnlyCallDoesNotRevertOnAShortBuffer() public {
        _live();
        _distribute(1 ether);
        _fund(h.DIVIDEND_THRESHOLD() / 2); // not fundable

        h.processDividends(0, _everyone()); // must not revert

        assertGt(alice.balance, 0, "the payouts went out anyway");
        assertEq(h.pendingNative(), h.DIVIDEND_THRESHOLD() / 2, "and the short buffer is untouched");
    }

    /// @dev Staleness is the ONLY escape from the threshold: a token that has gone
    ///      `STALE_DIVIDEND_WINDOW` without a distribution is dead, so the threshold stops applying and
    ///      the residual can finally reach holders instead of stranding.
    function test_thresholdBypassedOnceTheTokenGoesStale() public {
        _live();
        uint256 dust = h.DIVIDEND_THRESHOLD() / 2;
        _fund(dust);

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processDividends(0, _noHolders());

        skip(h.STALE_DIVIDEND_WINDOW() + 1);
        h.processDividends(0, _noHolders());

        assertEq(h.dividendsOwed(), dust, "the residual funded a stream once the token went stale");
        assertEq(h.pendingNative(), 0, "buffer drained");
    }

    /// @dev The bypass must stay shut for a token that is merely QUIET. `dividendPeriodFinish` moves
    ///      forward on every distribution, so a token still distributing never ages into it however
    ///      small its buffer.
    function test_staleBypassStaysShutWhileDistributionsKeepHappening() public {
        _live();
        for (uint256 i; i < 3; ++i) {
            skip(h.STALE_DIVIDEND_WINDOW() / 2);
            _distribute(1 ether);
        }

        _fund(h.DIVIDEND_THRESHOLD() / 2);
        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processDividends(0, _noHolders());
    }

    ///////////////////////// payout-path safety /////////////////////////

    /// @dev A holder the keeper omits loses NOTHING. Their accrual keeps sitting there across any number
    ///      of later distributions, which is what lets a keeper push only to holders above whatever
    ///      threshold it likes instead of having to reach everyone before the money moves on.
    function test_anOmittedHolderKeepsAccruingAcrossDistributions() public {
        _live();
        _distribute(1 ether);
        h.processDividends(0, _batch(alice)); // bob and carol omitted
        _distribute(1 ether);
        h.processDividends(0, _batch(alice));

        assertApproxEqRel(h.previewDividend(bob), 0.5 ether, 1e12, "two streams' worth, still owed");
        h.processDividends(0, _batch(bob));
        assertApproxEqRel(bob.balance, 0.5 ether, 1e12, "and paid in full whenever the keeper gets to it");
    }

    /// @dev One holder whose `receive()` reverts must not brick the batch: the others are paid, and the
    ///      failed amount stays ACCRUED so a later batch — or the holder itself — retries.
    function test_revertingHolderIsSkippedNotReverted() public {
        address rejecting = address(new RejectingHolder());
        h.seed(rejecting, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.activate();
        _distribute(1 ether);

        address[] memory batch = new address[](2);
        batch[0] = rejecting;
        batch[1] = bob;
        h.processDividends(0, batch);

        assertEq(rejecting.balance, 0, "the rejecting holder got nothing");
        assertApproxEqRel(bob.balance, 0.5 ether, 1e12, "the healthy holder was still paid in the same batch");
        assertApproxEqRel(h.previewDividend(rejecting), 0.5 ether, 1e12, "its accrual is intact for a retry");
        assertApproxEqRel(h.dividendsOwed(), 0.5 ether, 1e12, "and is still counted as owed");
    }

    /// @dev The same protection, without an explicit revert: a holder that simply burns more than
    ///      `NATIVE_PAYOUT_GAS` fails on the stipend. Without the cap it would consume the batch's gas.
    function test_gasGuzzlingHolderCannotGriefTheBatch() public {
        address guzzler = address(new GasGuzzlingHolder());
        h.seed(guzzler, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.activate();
        _distribute(1 ether);

        address[] memory batch = new address[](2);
        batch[0] = guzzler;
        batch[1] = bob;
        h.processDividends(0, batch);

        assertEq(guzzler.balance, 0, "the stipend was not enough for the guzzler, so its send failed");
        assertApproxEqRel(bob.balance, 0.5 ether, 1e12, "and the healthy holder was still paid");
    }

    /// @dev The other half of the stipend's contract. Capping the batch is only acceptable because the
    ///      holder it skips is not locked out: `claimDividends` forwards all remaining gas, because it
    ///      has no batch to protect and the caller is spending their own.
    function test_gasGuzzlingHolderCanStillClaimItself() public {
        address guzzler = address(new GasGuzzlingHolder());
        h.seed(guzzler, SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.activate();
        _distribute(1 ether);

        h.processDividends(0, _batch(guzzler));
        assertEq(guzzler.balance, 0, "skipped by the batch, as the stipend intends");

        vm.prank(guzzler);
        h.claimDividends();

        assertApproxEqRel(guzzler.balance, 0.5 ether, 1e12, "but paid in full when it claims for itself");
    }

    /// @dev A payee reentering `processDividends` from `receive()` must be stopped by the transient
    ///      guard. Without it the attacker would be paid, reenter before its accrual is zeroed, and be
    ///      paid the same amount a second time.
    function test_reentrantDistributeCannotDoublePay() public {
        ReenteringHolder attacker = new ReenteringHolder(h);
        h.seed(address(attacker), SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.activate();
        _distribute(1 ether);

        address[] memory batch = new address[](2);
        batch[0] = address(attacker);
        batch[1] = bob;
        h.processDividends(0, batch);

        assertEq(attacker.blockedReentries(), 1, "the reentrant call was refused by the guard");
        assertApproxEqRel(address(attacker).balance, 0.5 ether, 1e12, "the attacker got its honest half, once");
        assertApproxEqRel(bob.balance, 0.5 ether, 1e12, "and the other half went where it was owed");
        assertLe(address(h).balance, 1e6, "nothing beyond rounding dust stayed behind");
    }

    /// @dev Same via `claimDividends`, the self-serve backstop — it shares the guard for the same reason.
    function test_reentrantClaimCannotDoublePay() public {
        ReenteringHolder attacker = new ReenteringHolder(h);
        attacker.setUseClaim(true);
        h.seed(address(attacker), SUPPLY / 2);
        h.seed(bob, SUPPLY / 2);
        h.activate();
        _distribute(1 ether);

        h.processDividends(0, _batch(address(attacker)));

        assertEq(attacker.blockedReentries(), 1, "the reentrant claim was refused");
        assertApproxEqRel(address(attacker).balance, 0.5 ether, 1e12, "paid once, for its own share only");
    }

    /// @dev Duplicates in a batch are the interesting solvency case: zeroing the accrual on the first
    ///      hit is what makes every later hit pay 0, so the batch cannot over-draw.
    function test_duplicatesInABatchCannotOverDraw() public {
        _live();
        _distribute(1 ether);

        address[] memory batch = new address[](6);
        batch[0] = alice;
        batch[1] = alice;
        batch[2] = bob;
        batch[3] = bob;
        batch[4] = carol;
        batch[5] = alice;
        h.processDividends(0, batch);

        assertApproxEqRel(alice.balance + bob.balance + carol.balance, 1 ether, 1e12, "duplicates cannot over-draw");
        assertApproxEqRel(alice.balance, 0.5 ether, 1e12, "alice paid exactly once");
        assertApproxEqRel(bob.balance, 0.25 ether, 1e12, "bob paid exactly once");
    }

    /// @dev An unknown address in the batch pays 0 rather than reverting, so a keeper's list needs no
    ///      validation and a stale indexer entry costs nothing but gas.
    function test_unknownAddressInABatchPaysNothing() public {
        _live();
        _distribute(1 ether);

        address stranger = makeAddr("stranger");
        h.processDividends(0, _batch(stranger));
        assertEq(stranger.balance, 0, "an address that never held is owed nothing");
    }
}
