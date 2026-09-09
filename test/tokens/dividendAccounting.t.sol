// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";

/// @notice A bare `DividendDistributionLogic` whose balances move through `_onDividendTransfer`, in the
///         order a real token's `_update` moves them: SETTLE FIRST, then mutate. That order is the whole
///         of the anti-sandwich argument, so the harness has to reproduce it exactly — a harness that
///         mutated first would quietly test a different (and broken) contract.
contract DividendHarness is DividendDistributionLogic {
    mapping(address account => uint256 balance) public balances;
    uint256 public eligibleSupply;

    /// @dev Every address that has ever held a balance. Only a test harness can afford this — it is
    ///      exactly the holder set the production contract deliberately refuses to store.
    address[] public tracked;
    mapping(address account => bool) internal seen;

    address[3] internal excluded;

    function configure(address asset) external {
        (address[] memory assets, uint16[] memory weights) = _soleAssetSet(asset);
        assetCount = _initializeDividends(assets, weights, new bytes[](0));
    }

    /// @notice Same, naming the pools explicitly. No routes at all means the permissionless V2 pair,
    ///         which is what every other helper here relies on.
    function configureRouted(address asset, bytes calldata route) external {
        (address[] memory assets, uint16[] memory weights) = _soleAssetSet(asset);
        bytes[] memory routes = new bytes[](1);
        routes[0] = route;
        assetCount = _initializeDividends(assets, weights, routes);
    }

    /// @dev How many payout assets the harness was configured with. The production token keeps this in
    ///      its `pair` slot; here it is plain storage.
    uint8 public assetCount;

    function _dividendAssetCount() internal view override returns (uint256) {
        return assetCount;
    }

    /// @notice Configure a multi-asset payout set, as `initializeEarningsAllocation`'s array overload does.
    function configureMulti(address[] calldata assets, uint16[] calldata weights) external {
        assetCount = _initializeDividends(assets, weights, new bytes[](0));
    }

    function activate() external {
        _activateDividends();
    }

    /// @dev The supply floor is `internal` in production (nothing outside needs it); the harness exposes
    ///      it so the floor test asserts against the real constant rather than a copy of it.
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
    DividendHarness public immutable H;

    constructor(DividendHarness h) {
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
    DividendHarness internal h;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public {
        // `processDividends` is keeper-gated and fails closed without a registry to ask.
        installKeepersRegistry(address(this), address(this));

        h = new DividendHarness();
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

    /// @dev One full distribution: fresh earnings, converted and credited to whoever holds right now.
    function _distribute(uint256 amount) internal {
        _fund(amount);
        h.processDividends(0, _noHolders());
    }

    receive() external payable {}

    ///////////////////////// the flash-loan property /////////////////////////

    /// @dev THE property the whole design exists for. A borrowed balance is settled in at zero and spans
    ///      no distribution, so it accrues nothing however the rest of the transaction is arranged:
    ///      however many times it pokes the accumulator, whichever order it borrows and repays in.
    function test_aFlashLoanedBalanceEarnsExactlyZero() public {
        _live();
        _distribute(1 ether);

        FlashBorrower borrower = new FlashBorrower(h);
        borrower.attack(alice, SUPPLY / 2, 3);

        assertEq(h.previewDividend(address(borrower)), 0, "a balance that spanned no distribution accrues nothing");

        h.processDividends(0, _batch(address(borrower)));
        assertEq(address(borrower).balance, 0, "and is paid nothing");
    }

    /// @dev The sandwich a borrower would want — borrow, land the distribution, take it, repay — is not
    ///      available to them: landing a distribution takes a keeper. That gate, not a drip, is what
    ///      keeps the funding instant out of any caller's own transaction.
    function test_aFlashLoanCannotLandItsOwnDistribution() public {
        _live();
        _fund(1 ether);

        address borrower = makeAddr("borrower");
        h.transfer(alice, borrower, SUPPLY / 2); // borrow
        vm.prank(borrower);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        h.processDividends(0, _batch(borrower)); // fund and take, in the same transaction: refused
        h.transfer(borrower, alice, SUPPLY / 2); // repay

        assertEq(h.previewDividend(borrower), 0, "nothing landed while the balance was borrowed");
        assertEq(h.pendingNative(), 1 ether, "and the buffer is still waiting for the keeper");
    }

    ///////////////////////// the accrual identity /////////////////////////

    /// @dev Accrual is proportional to the balance held when the distribution lands. Everything else is
    ///      downstream of this: a holder with half the eligible supply earns half.
    function test_accrualIsProportionalToBalanceAtTheDistribution() public {
        _live();
        _distribute(1 ether);

        uint256 a = h.previewDividend(alice);
        uint256 b = h.previewDividend(bob);
        uint256 c = h.previewDividend(carol);

        assertApproxEqRel(a, 0.5 ether, 1e12, "half the supply earns half the distribution");
        assertApproxEqRel(b, 0.25 ether, 1e12, "a quarter earns a quarter");
        assertEq(b, c, "equal balances earn equally");
        assertLe(a + b + c, h.dividendsOwed(), "and the parts never exceed the whole");
    }

    /// @dev THE ordering rule, observed from outside. A balance that arrives after a distribution earns
    ///      nothing from it — the settle books the newcomer at a zero balance before the tokens land —
    ///      and everything the previous holder had accrued stays theirs. The next distribution is split
    ///      by the balances held then.
    function test_anArrivalAfterADistributionEarnsOnlyWhatLandsLater() public {
        h.seed(alice, SUPPLY);
        h.activate();
        _distribute(1 ether);

        h.transfer(alice, bob, SUPPLY / 2); // bob arrives after the first distribution
        assertEq(h.previewDividend(bob), 0, "nothing from before he held");
        assertApproxEqRel(h.previewDividend(alice), 1 ether, 1e12, "alice keeps the whole first one");

        _distribute(1 ether);
        assertApproxEqRel(h.previewDividend(bob), 0.5 ether, 1e12, "half of the second");
        assertApproxEqRel(h.previewDividend(alice), 1.5 ether, 1e12, "the rest");
    }

    /// @dev Solvency, stated directly: what the module has promised holders never exceeds what it has
    ///      been given. The accumulator truncates at every step, so this is an inequality by
    ///      construction, and it has to survive an arbitrary sequence of transfers and distributions.
    function testFuzz_promisedNeverExceedsFunded(uint256[8] calldata seeds, uint96[8] calldata amounts) public {
        _live();
        _distribute(1 ether);

        address[4] memory actors = [alice, bob, carol, makeAddr("dave")];
        for (uint256 i; i < seeds.length; ++i) {
            if (seeds[i] % 3 == 0) _distribute(1 ether);
            address from = actors[seeds[i] % actors.length];
            address to = actors[(seeds[i] / 7 + 1) % actors.length];
            if (from == to) continue;
            uint256 balance = h.balances(from);
            if (balance == 0) continue;
            h.transfer(from, to, bound(uint256(amounts[i]), 1, balance));
            assertLe(h.sumOfPreviews(), h.dividendsOwed(), "promised never exceeds funded");
        }
    }

    /// @dev An excluded address neither accrues nor is payable, and the two halves of that statement
    ///      come from two separately-written functions in the token (`_dividendExcluded` and
    ///      `_dividendEligibleSupply`). They have to agree, or the excluded balance would dilute the
    ///      denominator while earning nothing — under-distributing every distribution.
    function test_excludedAddressNeitherCountsNorEarns() public {
        h.exclude(0, carol);
        _live();
        _distribute(1 ether);

        assertEq(h.previewDividend(carol), 0, "an excluded address accrues nothing");
        h.processDividends(0, _batch(carol));
        assertEq(carol.balance, 0, "and is never paid");

        // Alice and bob hold 2:1 of the ELIGIBLE supply, so the whole distribution goes to them in that ratio.
        assertApproxEqRel(h.previewDividend(alice), uint256(2 ether) / 3, 1e12, "carol's balance did not dilute");
    }

    ///////////////////////// repeated distributions /////////////////////////

    /// @dev Distribution after distribution, with nothing claimed in between, must not lose money: each
    ///      one adds to the same accumulator and `owed` grows by exactly what went in.
    function test_repeatedDistributionsAddUp() public {
        _live();
        for (uint256 i; i < 5; ++i) {
            _distribute(1 ether);
        }

        assertApproxEqRel(h.sumOfPreviews(), 5 ether, 1e12, "everything funded is promised");
        assertEq(h.dividendsOwed(), 5 ether, "and owed matches what went in");
    }

    /// @dev Below `MIN_DIVIDEND_SUPPLY` there is nobody to credit — the division guard and the
    ///      accumulator's ceiling in one — so funding refuses and the buffer waits for a holder, rather
    ///      than reserving the amount in `owed` for nobody, forever.
    function test_fundingBelowTheSupplyFloorRevertsAndKeepsTheBuffer() public {
        address sink = makeAddr("sink");
        h.exclude(0, sink);
        h.seed(alice, SUPPLY);
        h.activate();

        // Alice parks all but a dust balance out of reach, taking eligible supply under the floor.
        h.transfer(alice, sink, SUPPLY - 1);
        assertLt(h.eligibleSupply(), h.minDividendSupply(), "under the floor");

        _fund(1 ether);
        vm.expectRevert(DividendDistributionLogic.NoDividendSupply.selector);
        h.processDividends(0, _noHolders());
        assertEq(h.pendingNative(), 1 ether, "the buffer is untouched");
        assertEq(h.dividendsOwed(), 0, "and nothing is owed to nobody");

        // Supply comes back, and the same buffer goes to whoever holds now.
        h.transfer(sink, bob, SUPPLY - 1);
        h.processDividends(0, _noHolders());
        assertApproxEqRel(h.previewDividend(bob), 1 ether, 1e12, "credited to the holder who showed up");
    }

    ///////////////////////// the threshold and its bypass /////////////////////////

    /// @dev Below the threshold the buffer keeps accruing rather than paying for a distribution not
    ///      worth its gas.
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

        assertEq(h.dividendsOwed(), dust, "the residual was distributed once the token went stale");
        assertEq(h.pendingNative(), 0, "buffer drained");
    }

    /// @dev The bypass must stay shut for a token that is merely QUIET. `lastDistribution` resets on
    ///      every distribution, so a token still distributing never ages into it however small its
    ///      buffer.
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

        assertApproxEqRel(h.previewDividend(bob), 0.5 ether, 1e12, "two distributions' worth, still owed");
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
