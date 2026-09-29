// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev V4 transient-storage reader — used to detect whether a PoolManager op (swap) holds the singleton lock.
interface IExttload { function exttload(bytes32 slot) external view returns (bytes32); }

/**
 * @title RealmAnyPairsDividendTrackerQuote
 * @notice Quote-token variant of {RealmAnyPairsDividendTracker}: same immutable, no-owner, no-drain
 *         magnified-dividend accounting, but holders are paid in the pool's QUOTE token (ERC-20).
 * @dev The tax hook (`feeder`) transfers the rewards slice here and calls {feedToken}. Lock-gating in {process}
 *      is required: an ERC-20 transfer can hand control to the recipient during a swap. Payouts are CEI with
 *      per-payout try/catch isolation.
 */
contract RealmAnyPairsDividendTrackerQuote {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    // V4 Lock.IS_UNLOCKED_SLOT — transiently nonzero while a PoolManager op holds the lock (a swap is running).
    bytes32 internal constant V4_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    address public immutable token;  // the RealmAnyPairsTokenDividend feeding balances
    address public immutable feeder; // the tax hook, the only address that funds rewards
    address public immutable quote;  // the ERC-20 rewards are paid in (the pool's quote token)
    address public immutable poolManager; // V4 singleton; used to gate in-swap pushes (0 = ungated, tests)
    /// @notice Overflow-safe floor for {minEligible}, derived by the launcher as `totalSupply / 1e4`. Immutable;
    /// it is also the reward-booking gate, which bounds the magnified-share arithmetic.
    uint256 public immutable minEligibleFloor;
    /// @notice Creator-settable minimum balance for the auto-push ring. Starts at {minEligibleFloor} and may be
    /// moved within [floor, floor * {MAX_MIN_ELIGIBLE_MULTIPLE}]; it never affects accrual.
    uint256 public minEligible;
    /// @dev Ceiling on {minEligible}: 100x the floor, i.e. 1% of total supply.
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

    uint256 public magnifiedRewardPerShare;
    uint256 public eligibleSupply;
    uint256 public totalDistributed;
    /// @dev Reward buffered while eligible supply is below {minEligibleFloor}. Released by {pokePending} or the
    /// next feed once supply is back over the floor; if it never returns, this balance is unrecoverable.
    uint256 public pending;

    mapping(address => uint256) public trackedBalance;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;

    address[] private _holders;
    mapping(address => uint256) private _holderIdx1;
    uint256 public lastProcessedIndex;

    uint256 private _entered = 1;

    event RewardsDistributed(uint256 amount, uint256 perShare);
    /// @notice The balance fell below `reserve` (assets removed externally). Incoming income repairs the
    /// shortfall instead of accruing until it is closed.
    event RewardShortfall(uint256 reserve, uint256 balance);

    /// @notice {_spend} was asked for more than `reserve` and clamped it to zero. Should be unreachable; if it
    /// fires, the claims-vs-reserve invariant is broken and the next sync may double-book the balance.
    event ReserveUnderrun(uint256 reserve, uint256 amount);
    event RewardClaimed(address indexed account, uint256 amount);

    /// @notice The auto-push could not pay `account` and skipped it. Nothing is lost: the holder stays fully
    /// claimable via {claim}. `amount` is what the push tried to pay.
    event PushPaymentFailed(address indexed account, uint256 amount);

    error OnlyToken();
    error OnlySelf();
    error OnlyFeeder();
    error Reentrancy();
    error NothingToClaim();
    error ZeroRecipient();
    error NotCreator();
    error MinEligibleBelowFloor();
    error MinEligibleTooHigh();
    /// @dev {distributeFor} was called while a V4 PoolManager operation holds the singleton lock.
    error NotDuringSwap();
    /// @dev {distributeFor} paid nobody, so it pays the caller nothing and costs them only gas.
    error NothingDelivered();
    /// @dev More than {MAX_POKE_SYNC} addresses handed to {distributeFor}.
    error TooManyToSync();
    /// @notice The payout transfer reported success but moved nothing to the recipient, so it was rolled back.
    /// @dev AUDIT ROUND 8: `safeTransfer` accepts a token that returns true and moves nothing (a compliance
    /// soft-blocklist, a 100% fee-on-transfer token, a proxy upgraded to a no-op). Without this the holder was
    /// debited for a delivery that never happened, the value stayed here above `reserve`, the next sync re-booked
    /// it as fresh income, and a {distributeFor} caller was paid a fee on every round of that loop (measured:
    /// 702.4 of a 1000-token pool in one transaction).
    error ZeroDelivery();
    event MinEligibleSet(uint256 oldValue, uint256 newValue);
    event MinPokeSet(uint256 amount);
    /// @notice A {distributeFor} call paid `caller` `amount` of {quote}, skimmed from the rewards it delivered.
    event PokePaid(address indexed caller, uint256 amount);

    // ── permissionless paid poke ({distributeFor}) ──
    uint256 internal constant BPS = 10_000;
    /// @notice What a {distributeFor} caller is paid, in bps of the rewards that call actually delivers, skimmed
    /// from the delivery itself. Fixed at 2%, matching {RealmAnyPairsPlatformFeeConverter.MAX_REIMBURSE_BPS}.
    uint256 public constant POKE_FEE_BPS = 200;
    /// @notice Smallest push a {distributeFor} call is paid on, in {quote} units. A push below it is still made,
    /// in full, for free. Creator-settable; 0 = every push pays.
    uint256 public minPoke;
    /// @notice Most addresses one {distributeFor} call may repair before it distributes.
    uint256 public constant MAX_POKE_SYNC = 64;
    /// @dev Per-address cap on a {distributeFor} pre-sync, equal to {balanceSyncGas}.
    uint256 internal constant POKE_SYNC_GAS = 230_000;
    /// @dev Set for the duration of one {distributeFor}. See {RealmAnyPairsDividendTracker}.
    address private transient _poker;
    uint256 private transient _pokeAcc;

    modifier onlyToken() { if (msg.sender != token) revert OnlyToken(); _; }
    modifier onlyFeeder() { if (msg.sender != feeder) revert OnlyFeeder(); _; }
    modifier nonReentrant() { if (_entered == 2) revert Reentrancy(); _entered = 2; _; _entered = 1; }

    struct Config {
        address token;
        address feeder;
        address quote;
        address poolManager;
        uint256 minEligible;
        address[] excluded;
    }

    constructor(Config memory c) {
        token = c.token;
        feeder = c.feeder;
        quote = c.quote;
        poolManager = c.poolManager;
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        for (uint256 i; i < c.excluded.length; ++i) excluded[c.excluded[i]] = true;
        // Exclude the coin itself: tokens mis-sent there would otherwise accrue rewards nobody can claim.
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true;
        lastActivityAt = uint64(block.timestamp); // {sweepStranded}'s clock runs from deployment
    }

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    /// @notice Worst-case gas {setBalance} needs, read by {RealmAnyPairsTokenDividend.initTracker}. Constant
    /// because this tracker holds a single denomination.
    function balanceSyncGas() external pure returns (uint256) {
        return 230_000;
    }

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) {
            _noteExcluded(account, newBalance); // round 9 (F4): remember it before it is zeroed for accrual
            newBalance = 0;
        }
        _applyBalance(account, newBalance);
    }

    /// @dev The accounting half of {setBalance}, shared with {_syncBalance}. Caller must have already
    /// applied the `excluded` override.
    function _applyBalance(address account, uint256 newBalance) internal {
        uint256 old = trackedBalance[account];
        if (newBalance == old) return;
        if (newBalance > old) {
            uint256 add = newBalance - old;
            eligibleSupply += add;
            magnifiedCorrections[account] -= (magnifiedRewardPerShare * add).toInt256();
        } else {
            uint256 sub = old - newBalance;
            eligibleSupply -= sub;
            magnifiedCorrections[account] += (magnifiedRewardPerShare * sub).toInt256();
        }
        trackedBalance[account] = newBalance;

        uint256 idx1 = _holderIdx1[account];
        // Ring membership is gated on `minEligible` so dust accounts cannot fill the gas-bounded ring. This
        // withholds only the automatic push; sub-threshold holders still accrue and can {claim}.
        if (newBalance < minEligible) {
            if (idx1 != 0) _removeHolder(account, idx1);
        } else if (idx1 == 0) {
            _holders.push(account);
            _holderIdx1[account] = _holders.length;
        }
    }


    /// @notice Repair a `trackedBalance` that has drifted from the token's real balance. Permissionless: it
    /// can only move tracked state toward the truth.
    /// @dev Drift arises when the token skips its notify under starved caller gas. {claim} syncs the account
    /// it pays; {process} does not sync, so this is how any other account gets repaired.
    function syncBalance(address account) external nonReentrant {
        _syncBalance(account);
    }

    /// @notice Batch form of {syncBalance}.
    function syncBalances(address[] calldata accounts) external nonReentrant {
        for (uint256 i; i < accounts.length; ++i) _syncBalance(accounts[i]);
    }

    /// @dev Re-reads the token's real balance for `account` and re-applies it. No-op when already in sync.
    function _syncBalance(address account) internal {
        if (excluded[account]) {
            // Round 9 (F4): repair the excluded mirror as well, so anyone can refresh the release denominator.
            (bool xok, bytes memory xret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
            if (xok && xret.length >= 32) _noteExcluded(account, abi.decode(xret, (uint256)));
            if (trackedBalance[account] != 0) _applyBalance(account, 0);
            return;
        }
        // Low-level staticcall so a revert or short return degrades to "skip the repair" instead of bricking
        // {claim}/{process}. Deliberately uncapped: `token` is the immutable launcher-deployed coin, whose
        // balanceOf is a cheap mapping read, and a too-tight cap would silently disable repair.
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, account)); // balanceOf(address)
        if (!ok || ret.length < 32) return;
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) _applyBalance(account, real);
    }

    function _removeHolder(address account, uint256 idx1) private {
        uint256 last = _holders.length;
        if (idx1 != last) {
            address moved = _holders[last - 1];
            _holders[idx1 - 1] = moved;
            _holderIdx1[moved] = idx1;
        }
        _holders.pop();
        _holderIdx1[account] = 0;
    }

    function holderCount() external view returns (uint256) { return _holders.length; }

    // ─────────────────────────── creator-settable eligibility floor ───────────────────────────

    /// @notice Set the minimum balance a holder needs to sit in the auto-push ring. Creator-only.
    /// @dev Bounded to [{minEligibleFloor}, floor * {MAX_MIN_ELIGIBLE_MULTIPLE}] and to the current
    /// `eligibleSupply`. Only ring membership depends on it: accrual, the booking gate and the overflow bound
    /// all use the immutable floor, so a holder below the threshold keeps accruing and can still claim.
    /// Every launcher path seeds the floor at `totalSupply / 1e4`, so this ceiling is 1e2 x 1e-4 = 1% OF TOTAL
    /// SUPPLY (verified audit round 9). Creator-settable; it is the only reward knob the creator still holds.
    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) revert NotCreator();
        if (newMinEligible < minEligibleFloor) revert MinEligibleBelowFloor();
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) revert MinEligibleTooHigh();
        if (newMinEligible > eligibleSupply) revert MinEligibleTooHigh();
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
    }

    /// @notice Set the smallest push {distributeFor} is paid on. Unbounded; default 0 (every push pays), which stays
    /// the default -- the poke fee is what makes searchers push small books.
    /// @dev PLATFORM-ADMIN ONLY as of audit round 9 (the hook's live `admin()`, so it survives a creator renounce),
    /// with the rest of the reward knobs: raising it only removes the caller's incentive, never a holder's reward.
    function setMinPoke(uint256 amount) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        minPoke = amount;
        emit MinPokeSet(amount);
    }

    /// @dev The coin's current creator. Fail-closed: if it cannot be read, reverts {NotCreator}.
    function _tokenCreator() internal view returns (address c) {
        // Prefer the hook's record (follows creator hand-offs; address(0) after a renounce is refused). Fall
        // back to the token's `creator()` when the feeder does not answer (e.g. an EOA feeder in tests).
        (bool hok, bytes memory hret) =
            feeder.staticcall{gas: 50_000}(abi.encodeWithSignature("creatorOfCoin(address)", token));
        if (hok && hret.length >= 32) {
            c = abi.decode(hret, (address));
            if (c == address(0)) revert NotCreator();
            return c;
        }
        (bool ok, bytes memory ret) = token.staticcall{gas: 20_000}(abi.encodeWithSelector(0x02d05d3f)); // creator()
        if (!ok || ret.length < 32) revert NotCreator();
        c = abi.decode(ret, (address));
        if (c == address(0)) revert NotCreator();
    }


    /// @dev True while a V4 swap holds the PoolManager lock. address(0) poolManager (tests) => always false.
    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Book reward buffered while supply was dust, once real supply exists. Permissionless.

    // ─────────────────────────── admin rescue (audit round 8 scope addition) ───────────────────────────
    //
    // TWO paths, both platform-admin only (the hook's live `admin()`, the key {setRoute} uses, so it survives a
    // creator renounce), both refused while the V4 lock is held, and NEITHER able to touch a holder's rewards:
    //
    //   1. {rescueStray} -- always available, for an asset this tracker never pays out. A reward denomination,
    //      the coin, and the asset the tracker pays in are all refused, so `reserve` and every claimable balance
    //      are out of reach by construction.
    //   2. {sweepStranded} -- for income that stranded because eligible supply never crossed
    //      {minEligibleFloor}. Only the buffered part is sweepable, only while supply is STILL below the floor,
    //      and only after {RESCUE_DELAY} of no distribution and no successful payout. Both the buffer and its
    //      backing move together, so `balance >= reserve` and `sum(claimable) <= what is held` are preserved.
    //
    /// @notice Last time reward value moved: a distribution ({_book}) or a successful payout ({_spend}).
    /// Anchors {sweepStranded}'s timeout.
    uint64 public lastActivityAt;
    /// @notice How long a tracker must be dead -- no distribution, no payout, supply still under the floor --
    /// before its stranded buffer can be swept.
    uint256 public constant RESCUE_DELAY = 180 days;

    /// @notice An asset the tracker never pays out was withdrawn by the platform admin.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Buffered income that stranded under a dead book was swept by the platform admin.
    event StrandedSwept(address indexed token, address indexed to, uint256 amount);

    error NotPlatformAdmin();
    error RescueForbiddenAsset(address token);
    error ZeroAddress();
    error NotStranded();
    error AmountExceedsStranded();

    /// @dev The feeder's (the tax hook's) `admin()`. Unreadable or zero refuses -- fail-closed.
    function _platformAdmin() internal view returns (address a) {
        (bool ok, bytes memory ret) = feeder.staticcall{gas: 20_000}(abi.encodeWithSignature("admin()"));
        if (!ok || ret.length < 32) revert NotPlatformAdmin();
        a = abi.decode(ret, (address));
        if (a == address(0)) revert NotPlatformAdmin();
    }

    /// @dev Shared refusals for both rescue paths.
    function _rescueGate(address to) internal view {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (to == address(0) || to == address(this)) revert ZeroAddress();
        if (_v4LockHeld()) revert NotDuringSwap();
    }

    /// @dev True when the book is dead: still below the booking floor, and nothing has moved for
    /// {RESCUE_DELAY}. `lastActivityAt == 0` means nothing ever moved, so the clock runs from deployment --
    /// which is why it is stamped in the constructor.
    function _strandedUnlocked() internal view returns (bool) {
        return eligibleSupply < minEligibleFloor && block.timestamp >= uint256(lastActivityAt) + RESCUE_DELAY;
    }

    /// @notice Withdraw an asset this tracker never pays out. Platform admin only.
    /// @dev Refuses the payout asset and the coin, so it can never reach `reserve` or a holder's rewards.
    function rescueStray(address asset, address to, uint256 amount) external nonReentrant {
        _rescueGate(to);
        if (asset == quote || asset == token) revert RescueForbiddenAsset(asset);
        IERC20(asset).safeTransfer(to, amount);
        emit Rescued(asset, to, amount);
    }

    /// @notice Sweep income that stranded because eligible supply never crossed {minEligibleFloor}. Platform
    /// admin only, and only from a dead book: supply still under the floor and {RESCUE_DELAY} with no
    /// distribution and no successful payout.
    /// @dev Moves the buffer and its backing together (`pending` and `reserve` both fall by `amount`), so
    /// `sum(claimable) + pending <= reserve` and `reserve <= balance` both still hold afterwards. Nothing a
    /// holder can claim is reachable: only `pending` is, and `pending` is by definition unbooked.
    function sweepStranded(address to, uint256 amount) external nonReentrant {
        _rescueGate(to);
        if (!_strandedUnlocked()) revert NotStranded();
        uint256 p = pending;
        if (amount > p) revert AmountExceedsStranded();
        uint256 leftAfterSweep = p - amount;
        pending = leftAfterSweep;
        // AUDIT ROUND 15 (F-1) then ROUND 16 (F-2). A sweep must keep BOTH invariants, and the round-15 form kept
        // only one.
        //
        // Round 14 cleared the counters only when a sweep EMPTIED the buffer, so after a PARTIAL sweep
        // `pendingTotal` still counted money that was gone and a dust holder could draw almost all of the remainder
        // (measured 1000x fair). Round 15 fixed that by rebasing to `pendingTotal = leftAfterSweep;
        // pendingServed = 0`, which does restore `pending == pendingTotal - pendingServed` -- but it THREW AWAY
        // `pendingServed`, the monotone high-water mark that is the only thing stopping a cohort being paid twice
        // out of the same buffer. Its premise, "nobody was served out of it", is false whenever `pendingServed > 0`,
        // which is the normal state after any partial release.
        //
        // Measured on the round-15 code: float 1e23, attacker holds exactly 50%. Book dead, 100e18 buffers; attacker
        // syncs, pokes, claims its exactly-fair 49.999999999999999999e18 (`pendingServed = 50e18`); moves the stake
        // out with only the mandatory debit gas so `eligibleSupply` falls to 0 (the credit is skippable by design);
        // 180 days later an HONEST admin sweeps what looks like a dead book, `pendingServed` resets to 0; the
        // attacker moves the stake back and draws +24.5e18 it has already been paid for. Total 74.5e18 of a 99e18
        // pool against a fair 49.5e18 -- and the other half of the float is HALVED, 24.5e18 instead of 49.5e18. A
        // ONE-WEI sweep unlocks the whole second helping, and no malicious admin is involved.
        //
        // The rebase that satisfies both rounds is a subtraction with the mark LEFT ALONE. Algebraically
        // `pendingTotal - amount == pendingServed + leftAfterSweep`, so round 15's invariant holds exactly, and
        // because `want = pendingTotal * elig / supply` can only SHRINK when `pendingTotal` shrinks, a cohort that
        // has already been served still computes `want <= done` and draws nothing. Round 8's monotone guarantee and
        // round 15's invariant are both preserved, rather than one being traded for the other.
        //
        // Both are cleared only when the buffer is actually empty -- the same condition {_releasePending} uses.
        // THE INVARIANT, BOTH HALVES -- stating only one of them is how round 15 went wrong here:
        //   (1) `pending == pendingTotal - pendingServed` at every point. A sweep writes `pending` directly, so it
        //       must adjust `pendingTotal` by the same amount; `pendingTotal - amount` does exactly that.
        //   (2) `pendingServed` is MONOTONE, except on a full drain. It is the high-water mark of what this buffer
        //       has already paid out, and it is the only thing stopping a cohort being served twice out of the same
        //       buffer (the round-8 guarantee). A sweep must therefore NOT touch it.
        // Round 15 satisfied (1) by zeroing `pendingServed`, which broke (2): an attacker took its fair share, left
        // the register, waited for an honest admin to sweep, came back and drew the same share again -- halving what
        // the rest of the float received. A one-wei sweep was enough. Both halves now hold together.
        pendingTotal -= amount;
        if (leftAfterSweep == 0) {
            pendingTotal = 0;
            pendingServed = 0;
        }
        _spendNoStamp(amount);
        // AUDIT ROUND 18 (informational, consistency). MEASURE THE SENDER'S DECREASE and report THAT, the same rule
        // {_pushReward} applies three functions below. The ledger legs above intentionally move by the NOMINAL
        // `amount` and that is not changed here: against a fee-on-transfer or soft-blocklist quote the retained
        // remainder stays in this contract and is re-booked to holders on the next {sync}, so nothing is lost and no
        // invariant breaks. What was wrong was only the REPORT -- a quote that returns true while moving nothing (or
        // less) made {StrandedSwept} name an amount that never left, and an off-chain reconciler reading this event
        // would have believed it. The event now names what actually moved.
        //
        // DELIBERATELY NOT a {ZeroDelivery} revert like {_pushReward}'s. There the revert protects a HOLDER's ledger
        // from being debited for a delivery that did not happen; here the debit is of buffers no holder has a claim
        // on, the caller is the platform admin, and reverting would newly brick an admin's ability to clear a dead
        // book against a quote that has started refusing transfers. Accurate reporting, unchanged behaviour.
        uint256 beforeBal = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransfer(to, amount);
        uint256 afterBal = IERC20(quote).balanceOf(address(this));
        uint256 moved = beforeBal > afterBal ? beforeBal - afterBal : 0;
        if (moved > amount) moved = amount; // a minting quote cannot over-report
        emit StrandedSwept(quote, to, moved);
    }

    function pokePending() external nonReentrant {
        // Gated on {minEligibleFloor}, NOT on the creator-settable {minEligible}.
        _releasePending();
    }

    // ── proportional release of buffered income (audit round 8, F3) ──
    /// @notice Everything ever added to the CURRENT pending buffer. Reset with the buffer.
    ///
    /// @dev AUDIT ROUND 14 (F-1). This pair of ABSOLUTE counters replaces `pendingReleasedFrac`, a fraction whose
    /// exactness rested on `pending == pendingTotal * (ONE - served)` -- an invariant nothing maintained. Two things
    /// broke it, and together they brought back both round-13 failure modes:
    ///   * the proportional branch computes `r = mulDiv(p, target - served, ONE - served)` with `target < ONE`, so it
    ///     ALWAYS leaves a remainder. `left == 0` was therefore reachable only from the full-release branch, and the
    ///     round-13 reset could never fire after a proportional release. The residue is not dust: it is the
    ///     arithmetic floor of the common case.
    ///   * `pending` keeps GROWING while the book is under {minEligibleFloor}, and nothing rescaled `served` when it
    ///     did, so a stored fraction began treating brand-new money as already partly served. Measured by the
    ///     auditor: a fresh cohort at 17% of supply paid ZERO of a 107 ether buffer because a long-gone holder had
    ///     left `served` at 23%; and at the inherited clock's expiry a holder of exactly `minEligibleFloor` taking a
    ///     whole tranche, ~1000x fair share, repeatably.
    ///
    /// Absolute counters have no invariant to break. The target is `pendingTotal * elig / supply`, the ratchet is the
    /// amount already paid, and an ADDITION simply raises the target in the same proportion -- so releases stay
    /// path-independent under additions as well as under supply cycling, the monotone ratchet survives, and the
    /// round-8 first-registrant bound is unchanged (0.01% of the float still takes 0.01% of the buffer).
    uint256 public pendingTotal;

    /// @notice How much of {pendingTotal} has already been released. Monotone within a buffer; reset with it.
    uint256 public pendingServed;




    /// @dev Book the share of {pending} that newly registered supply is entitled to; keep the rest buffered.
    /// AUDIT ROUND 8 (F3, High): {pending} used to be released IN FULL to whoever happened to be registered at
    /// release time, so a holder with a sliver of the float could `syncBalance` + {pokePending} and take nearly
    /// all of it (measured: 0.01% of supply capturing 99.75% of the buffer). Release is now proportional to the
    /// coin's ATTRIBUTABLE supply (round 9, F4) and driven by a high-water mark, which makes the AGGREGATE released
    /// path-independent: once registrations reach `e`, exactly `pending0 * e / totalSupply` has been booked, however
    /// many times and in however many transactions this ran -- so repeated calls buy nothing. The AGGREGATE only: how
    /// that total is SPLIT between holders still depends on registration order. See the round-17 note below.
    /// Exactness: `reserve` is untouched (it always backed booked and buffered income alike), {pending} falls by
    /// exactly what {_book} adds to `totalDistributed`, and the final release (everything registered, or the
    /// settle window elapsed) takes the remainder including rounding dust, so nothing strands on division.
    /// An UNREADABLE supply does not release at all: `_attributableSupply` reports zero and `_releasePending`
    /// returns (audit round 17 -- this line used to say "releases in full", which was the pre-round-14 behaviour and
    /// stopped being true when the settle clock was removed).
    /// @dev AUDIT ROUND 14, REDESIGN. THE SETTLE CLOCK IS GONE, and with it the whole "release everything to whoever
    /// is registered right now" branch. Four separate defects were found in this one mechanism across rounds 11-14 --
    /// inheritance across buffers, the one-way mark, the partial-release residue, and a clock armed against a dust
    /// buffer firing against a pool a thousand times larger. Every one of them paid out through that branch, because
    /// it is the only path that can hand a whole pool to a single instant's register. Measured on the last one:
    /// 100.000999e18 taken against 0.0999e18 fair, 1001x, repeatable because the drain reset the state and re-armed
    /// the clock. Each previous fix was correct about its bug and wrong about the shape of the problem.
    ///
    /// What remains is one rule with no special cases: `want = pendingTotal * elig / supply` is what the currently
    /// registered book is owed out of this buffer, `pendingServed` is what it has already had, and the difference is
    /// paid. That is monotone, path-independent under BOTH supply cycling and top-ups (a top-up raises
    /// `pendingTotal`, so `want` grows with it -- the top-up attack disappears by construction rather than by a
    /// restamp rule), and it keeps the round-8 first-registrant bound exactly.
    ///
    /// WHAT "PATH-INDEPENDENT" DOES AND DOES NOT COVER (audit round 17 -- a clarification; no behaviour changed).
    /// It is a statement about this buffer's TOTALS, and for those it is exact: once the registered book reaches
    /// `elig`, `pendingServed` is `pendingTotal * elig / supply` and the same aggregate has been released, however
    /// many calls in whatever order got it there. It is NOT a statement about WHO ends up holding that aggregate.
    /// Each release is booked across the register AS IT STANDS AT THAT MOMENT, so registration ORDER decides the
    /// split: two holders of half the float each, registering one at a time with a release in between, end at 75/25
    /// of a buffer that a simultaneous registration would have split 50/50. In general a cohort holding a fraction
    /// `f` that registers after the other `1 - f` has already drawn receives `f * f` of the original buffer instead
    /// of `f`, and the difference is booked to whoever was already registered. Measured -- with no admin action
    /// anywhere, and on this tracker's buffer as well as the basket's -- in `test/audit/R18OrderingControl.t.sol`.
    /// The advantage that gives an early registrant is its own open question; it is recorded here so this comment is
    /// not read as denying that it exists.
    ///
    /// `elig >= supply` needs no branch of its own: it simply makes `want == pendingTotal`, so the whole buffer is
    /// owed and paid. `supply == 0` returns rather than paying out, because nothing is attributable and there is no
    /// honest denominator.
    ///
    /// THE TRADE, STATED PLAINLY. A residue now waits for genuine registration instead of being dumped on a
    /// deadline. In a book that stays permanently part-registered AND above {minEligibleFloor}, that residue is
    /// neither payable nor sweepable ({_strandedUnlocked} requires the book to be UNDER the floor). It is not lost --
    /// it stays reserved and is paid the instant anyone else registers -- but nothing forces it out. That is
    /// deliberate: paying the residue out early to whoever happens to be registered is precisely the theft the clock
    /// kept enabling.
    ///
    /// AUDIT ROUND 17, CORRECTING THE OLDER WORDING HERE, which said the residue "belongs to the holders who have not
    /// registered". IT IS NOT HELD ASIDE FOR THEM, and nothing in this file could hold it aside. When a cohort of the
    /// remaining float does register, the release is booked across the WHOLE register at that instant, so the cohort
    /// takes only its proportional slice of the residue and the rest is booked to the already-registered -- see the
    /// ordering note above. Waiting is what stops a sliver of the float taking the residue in full; it is not, and was
    /// never, a reservation in favour of the holders who have not come in yet.
    function _releasePending() internal {
        uint256 p = pending;
        if (p == 0 || eligibleSupply < minEligibleFloor) return;
        uint256 elig = eligibleSupply;
        uint256 supply = _attributableSupply();
        if (supply == 0) return; // nothing attributable: wait for registration, or for the sweep
        uint256 done = pendingServed;
        uint256 want = Math.mulDiv(pendingTotal, elig, supply);
        if (want <= done) return; // no new registration since the last release: no write at all
        uint256 r = want - done;
        if (r > p) r = p; // never pay out more than is actually held
        pendingServed = done + r;
        uint256 left = p - r;
        pending = left;
        // The counters describe ONE buffer and are cleared with it.
        if (left == 0) {
            pendingTotal = 0;
            pendingServed = 0;
        }
        _book(r);
    }


    function _coinSupply() internal view returns (uint256 s) {
        (bool ok, bytes memory ret) = token.staticcall{gas: 20_000}(abi.encodeWithSelector(0x18160ddd));
        if (ok && ret.length >= 32) s = abi.decode(ret, (uint256));
    }

    // ── attributable supply (audit round 9, F4) ──
    /// @notice Coin held by EXCLUDED addresses, mirrored from the coin's own {setBalance} calls.
    mapping(address => uint256) public excludedBalance;
    /// @notice Sum of {excludedBalance}: the LP locker, the hook, the pools, the vaults and this tracker.
    uint256 public excludedSupply;

    /// @dev Mirror `account`'s REAL balance while it is excluded, so {_attributableSupply} can discount it.
    /// Excluded accounts are tracked at zero for accrual, which is why their balance has to be remembered here.
    function _noteExcluded(address account, uint256 real) internal {
        uint256 old = excludedBalance[account];
        if (old == real) return;
        excludedBalance[account] = real;
        excludedSupply = excludedSupply + real - old;
    }

    /// @notice The supply a buffered release can actually be attributed to: the coin's total less the coin held
    /// by excluded addresses. Zero means "nothing is attributable", on which every release path RETURNS WITHOUT
    /// PAYING -- it does not release in full.
    /// @dev AUDIT ROUND 9 (F4, Medium). `eligibleSupply` only ever counts NON-excluded registered balances, but
    /// the release measured itself against the RAW total supply -- and the LP locker, the hook, the pools, the
    /// vaults and this tracker are all excluded. `elig >= supply` was therefore unreachable on a live coin and a
    /// permanent fraction of every buffer could only ever come out through the settle clock. `excludedSupply` is
    /// mirrored from the coin's own `setBalance` traffic and refreshed by the permissionless `syncBalance`.
    ///
    /// STALENESS, IN BOTH DIRECTIONS (audit round 17, correcting the older claim here that it "can only ever be
    /// STALE-LOW"). The mirror is only as fresh as the last `setBalance` it was told about, and a notification can
    /// be missed in either direction:
    ///   * STALE-LOW (an excluded address received coin and the credit leg did not run) makes this denominator too
    ///     LARGE, so releases run too SLOWLY. That is the safe direction, and it is the common one, because the
    ///     coin's credit leg is the optional one.
    ///   * STALE-HIGH (an excluded address's balance FELL and the notification did not land) makes the denominator
    ///     too SMALL. The consequence is bounded, not absent: `elig / supply` is the fraction released, and an
    ///     understated `supply` releases MORE of a buffer to the currently registered book than it is strictly
    ///     owed. It cannot release more than the buffer, because `want` is capped at `pendingTotal` and the credit
    ///     at what the buffer holds; and once `x >= s` the subtraction below floors at zero, on which every caller
    ///     returns without paying at all. Anyone can repair the mirror permissionlessly with `syncBalance`.
    /// DO NOT rely on the one-directional claim for any new invariant: use the clamps, which hold either way.
    function _attributableSupply() internal view returns (uint256) {
        uint256 s = _coinSupply();
        uint256 x = excludedSupply;
        return s > x ? s - x : 0;
    }


    // ─────────────────────────── feeding (hook-driven) ───────────────────────────

    /// @notice Asset already accounted for. The gap to the real balance is un-booked income, booked by {sync}.
    uint256 public reserve;

    /// @notice Book any asset that has arrived but not yet been credited. Permissionless and idempotent.
    /// @dev Books the measured balance increase rather than a sender-reported amount, so fee-on-transfer and
    /// lying quotes can never make the tracker book value it does not hold.
    function sync() public nonReentrant {
        _sync();
    }

    function _sync() internal {
        uint256 bal = _assetBalance();
        if (bal <= reserve) {
            // Book nothing. Deliberately keep `reserve` (do not write it down to `bal`): it backs claims already
            // booked, so later income repairs a shortfall instead of being booked as fresh rewards.
            // Emit only on a strict shortfall; `bal == reserve` is the normal resting state.
            if (bal < reserve) emit RewardShortfall(reserve, bal);
            return;
        }
        uint256 delta = bal - reserve;
        reserve = bal;
        _receive(delta);
    }

    /// @dev Decrement `reserve` in the same frame as the transfer, so a reverted payout rolls it back too.
    function _spend(uint256 amount) internal {
        lastActivityAt = uint64(block.timestamp); // a payout is activity: it pushes {sweepStranded} out
        _spendNoStamp(amount);
    }

    /// @dev {_spend} without the activity stamp, so a sweep of a dead book cannot postpone its own timeout.
    function _spendNoStamp(uint256 amount) internal {
        uint256 r = reserve;
        // Clamp rather than revert so a payout is never bricked; the clamp is announced. See {ReserveUnderrun}.
        if (r >= amount) {
            reserve = r - amount;
            return;
        }
        emit ReserveUnderrun(r, amount);
        reserve = 0;
    }

    function _assetBalance() internal view returns (uint256) {
        return IERC20(quote).balanceOf(address(this));
    }

    /// @notice Called by the hook after it transfers the rewards slice. The argument is ignored; the measured
    /// balance increase is booked instead.
    /// @dev nonReentrant and onlyFeeder are both required: a reentrant book could count quote still in flight.
    /// {sync} remains the permissionless entry point.
    function feedToken(uint256) external onlyFeeder nonReentrant {
        _sync();
    }

    function _receive(uint256 amount) internal {
        if (amount == 0) return;
        // Never book over a dust supply; buffer to `pending` instead. Gated on the immutable floor so the
        // creator-settable {minEligible} can never stall reward booking.
        if (eligibleSupply < minEligibleFloor) {
            // Round 14: additions are COUNTED, so the proportional target rises with the buffer. That is what
            // makes a top-up harmless -- there is no deadline left for it to be dumped against.
            pendingTotal += amount;
            pending += amount;
            return;
        }
        _releasePending();
        _book(amount);
    }

    function _book(uint256 amount) internal {
        lastActivityAt = uint64(block.timestamp);
        magnifiedRewardPerShare += (amount * MAGNITUDE) / eligibleSupply;
        totalDistributed += amount;
        emit RewardsDistributed(amount, magnifiedRewardPerShare);
    }

    // ─────────────────────────── views ───────────────────────────

    /// @dev `acc` is non-negative by construction (per-share only grows; corrections offset every balance
    /// change), so the `acc <= 0` clamp is an unreachable backstop. It is intentionally not made saturating in
    /// {claimableOf}: a broken ledger should halt payouts rather than drain quietly.
    function accumulativeOf(address account) public view returns (uint256) {
        int256 acc = (magnifiedRewardPerShare * trackedBalance[account]).toInt256() + magnifiedCorrections[account];
        return acc <= 0 ? 0 : uint256(acc) / MAGNITUDE;
    }

    function claimableOf(address account) public view returns (uint256) {
        return accumulativeOf(account) - withdrawnRewards[account];
    }

    // ─────────────────────────── claim + auto-push ───────────────────────────

    /// @notice Pull `account`'s accrued rewards (quote token).
    /// @return amount what actually arrived at the recipient (see {_pushReward}).
    function claim(address account) external nonReentrant returns (uint256 amount) {
        // See {syncBalance}: repair balance drift before paying, so a phantom cannot claim.
        _syncBalance(account);
        amount = claimableOf(account);
        if (amount == 0) revert NothingToClaim();
        amount = _pushReward(account, account, amount);
    }

    /// @notice Claim your own rewards to a different address. Only the account itself can redirect its accrual.
    /// @dev Lets a holder whose address the quote issuer has frozen still receive its rewards elsewhere.
    function claimTo(address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        _syncBalance(msg.sender);
        amount = claimableOf(msg.sender);
        if (amount == 0) revert NothingToClaim();
        amount = _pushReward(msg.sender, to, amount);
    }

    /// @dev Rejects destinations where a reward would be burned, stranded or re-booked (address(0), this
    /// tracker, the coin, the quote, the feeder). Self-harm protection only; not the full excluded set.
    function _checkRecipient(address to) internal view {
        if (to == address(0) || to == address(this) || to == token || to == quote || to == feeder) {
            revert ZeroRecipient();
        }
    }

    /// @dev Gas cap for each push self-call. Unlike the ETH tracker it covers the whole self-call (~25k inner
    /// overhead plus the quote transfer), sized to leave headroom for compliance-gated proxied tokens. A cap
    /// that is too tight would fail every push for that quote.
    uint256 internal constant PUSH_GAS = 170_000;

    /// @dev Fixed gas of one push of the tracker's OWN coin (a reflection tracker, `quote == token`) on top of the coin's
    /// mandatory-debit floor `minDebit` x 64/63: the ledger writes, both balance reads, the in-lock delta reads, the
    /// self-call frame, and the coin's own work before its floor check and after it (the recipient's credit sync).
    /// Measured worst case 51,532 (cold storage, inside an unlock, max wallet live); the rest is margin.
    uint256 internal constant COIN_PUSH_OVERHEAD = 70_000;

    /// @dev v4-core `NonzeroDeltaCount.NONZERO_DELTA_COUNT_SLOT` and `CurrencyReserves.CURRENCY_SLOT`.
    bytes32 internal constant V4_NONZERO_DELTA_COUNT_SLOT =
        0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    bytes32 internal constant V4_SYNCED_CURRENCY_SLOT =
        0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;

    /// @notice An in-swap push would have left a PoolManager delta or `sync` open (it would revert the trader's transaction).
    error OpenDelta();

    /// @dev Gas cap of each push self-call. {PUSH_GAS} for a foreign quote. A reflection tracker pays in the coin itself,
    /// whose transfer out of here reverts below the coin's `minDebit` floor, which {PUSH_GAS} never clears; so its
    /// stipend is `minDebit + minDebit/63 + COIN_PUSH_OVERHEAD`. Read live, once per {process}: fixed after
    /// `initTracker`, and zero on a `TokenPlain` until `attachTracker` (then no floor applies and {PUSH_GAS} is used).
    function _pushGas() internal view returns (uint256 g) {
        g = PUSH_GAS;
        address t = token;
        if (quote != t) return g;
        (bool ok, bytes memory ret) = t.staticcall{gas: 30_000}(abi.encodeWithSignature("syncGasParams()"));
        if (!ok || ret.length < 96) return g;
        (, uint256 minDebit,) = abi.decode(ret, (uint256, uint256, uint256));
        uint256 c = minDebit + minDebit / 63 + COIN_PUSH_OVERHEAD;
        if (c > g) g = c;
    }

    /// @dev Whether the hook allows paying holders of `quote` during a swap. Fail-closed: any failed or
    /// malformed staticcall reads as "not allowed", which only delays payouts.
    function _inSwapAllowed() internal view returns (bool) {
        (bool ok, bytes memory d) =
            // 60k: the feeder makes its own registry staticcall; too tight a budget would read as "not allowed".
            feeder.staticcall{gas: 60_000}(abi.encodeWithSignature("inSwapAllowed(address)", quote));
        // Decoded as uint256, not bool, so a non-0/1 word cannot revert this frame.
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    /// @notice Round-robin push: pay accrued quote-token rewards to holders, bounded by `gasBudget`.
    /// Permissionless; the tax hook calls it after swaps, the token pokes it on transfers, and a UI can too.
    /// @dev Each payout is CEI and isolated in try/catch.
    function process(uint256 gasBudget) public nonReentrant returns (uint256 pushed) {
        return _process(gasBudget);
    }

    /// @notice Permissionless PAID poke: book any income, push rewards to holders round-robin, and pay the
    /// caller {POKE_FEE_BPS} of what was delivered, in {quote}, skimmed from the delivery. Delivery therefore
    /// never depends on a trade carrying spare gas, and Realm runs no keeper.
    /// @dev Refused inside a V4 unlock (it must not touch an in-flight swap). Reverts {NothingDelivered} when
    /// nothing was paid, so a losing attempt costs the searcher gas only. `gasBudget` is advisory: the ring is
    /// bounded by `gasleft()` and by one full pass over the holder set either way.
    function distributeFor(uint256 gasBudget) external nonReentrant returns (uint256 pushed, uint256 fee) {
        return _distributeFor(gasBudget);
    }

    /// @notice {distributeFor}, with a list of addresses to repair FIRST, so a buyer whose optional credit was
    /// deferred joins the ring and is paid in the SAME call. See {RealmAnyPairsDividendTracker.distributeFor}.
    function distributeFor(uint256 gasBudget, address[] calldata toSync)
        external
        nonReentrant
        returns (uint256 pushed, uint256 fee)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        uint256 n = toSync.length;
        if (n > MAX_POKE_SYNC) revert TooManyToSync();
        uint256 g0 = gasleft();
        for (uint256 i; i < n; ++i) {
            if (gasleft() < POKE_SYNC_GAS + POKE_SYNC_GAS / 63 + 10_000) break;
            try this.syncBalanceSelf{gas: POKE_SYNC_GAS}(toSync[i]) {} catch {}
        }
        uint256 used = g0 - gasleft();
        return _distributeFor(gasBudget > used ? gasBudget - used : 0);
    }

    /// @dev Self-only, gas-capped wrapper so {distributeFor} can isolate one repair ({syncBalance} is
    /// `nonReentrant`, and the poke already holds the guard).
    function syncBalanceSelf(address account) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _syncBalance(account);
    }

    function _distributeFor(uint256 gasBudget) internal returns (uint256 pushed, uint256 fee) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _sync(); // book anything that arrived but is not yet credited, so the poke delivers it too
        _pokeAcc = 0; // transient, so a second poke in the same transaction starts from zero
        _poker = msg.sender;
        pushed = _process(gasBudget);
        _poker = address(0);
        // Delivering nothing pays nothing and does NOT revert: otherwise anyone could front-run a searcher
        // with the free `process()` and burn their gas at will (audit round 8). Paying on a zero delivery is
        // the thing that must not happen, and that is guarded per push by {ZeroDelivery}.
        fee = _pokeAcc;
        if (fee != 0) IERC20(quote).safeTransfer(msg.sender, fee);
        emit PokePaid(msg.sender, fee);
    }

    function _process(uint256 gasBudget) internal returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) return 0;
        // Honeypot guard: while the V4 lock is held, pay nobody unless the hook allows in-swap payouts for this
        // quote. A code-length check is not enough here (callback-bearing tokens can invoke handlers for
        // codeless recipients), so the decision is per quote. See {_inSwapAllowed}.
        if (_v4LockHeld() && !_inSwapAllowed()) return 0;
        uint256 pushGas = _pushGas();
        uint256 idx = lastProcessedIndex;
        // The set may have changed since the cursor was saved (a {distributeFor} pre-sync appends or
        // swap-and-pops): resume in range, so the walk below steps to idx+1 or wraps and never reads OOB.
        if (idx >= n) idx = n - 1;
        uint256 gasStart = gasleft();
        uint256 iterations;
        while (iterations < n) {
            // Reserve room for a capped payout plus the iteration overhead and the cursor SSTORE, so saving the
            // cursor can never OOG. A call that cannot fit one full payout pushes nothing rather than a doomed one.
            if (gasleft() < pushGas + 40_000) break;
            uint256 len = _holders.length;
            if (len == 0) break;
            idx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[idx];
            // No _syncBalance here (too expensive per iteration); use {syncBalance} or {claim}.
            uint256 amt = claimableOf(h);
            if (amt != 0) {
                try this.pushReward{gas: pushGas}(h, amt) { unchecked { ++pushed; } }
                catch {
                    // The capped self-call already unwound its own debit; just announce it.
                    emit PushPaymentFailed(h, amt);
                }
            }
            unchecked { ++iterations; }
            if (gasStart - gasleft() > gasBudget) break;
        }
        lastProcessedIndex = idx;
    }

    /// @dev External self-only wrapper so {process} can isolate one failed payout (a weird token) in try/catch.
    /// Inside someone else's unlock the transfer must not leave a PoolManager delta or a `sync` open (either would revert
    /// or mis-credit the trader's settlement); such a push reverts {OpenDelta} instead.
    function pushReward(address account, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        bool locked = _v4LockHeld();
        uint256 openBefore = locked ? uint256(IExttload(poolManager).exttload(V4_NONZERO_DELTA_COUNT_SLOT)) : 0;
        _pushReward(account, account, amount);
        if (
            locked
                && (
                    uint256(IExttload(poolManager).exttload(V4_NONZERO_DELTA_COUNT_SLOT)) != openBefore
                        || IExttload(poolManager).exttload(V4_SYNCED_CURRENCY_SLOT) != bytes32(0)
                )
        ) revert OpenDelta();
    }

    /// @dev Pays `to` and debits the full nominal `amount` from `account` up front (CEI), with no refund of any
    /// shortfall: a measured debit is attacker-influenceable. Any fee taken in transit is borne by the holder.
    /// @param account whose ledger is debited -- always the earner, never the payee.
    /// @param to where the tokens actually go. Equal to `account` on every path except {claimTo}.
    /// @return delivered what the recipient's balance actually rose by, clamped to `amount`. Reporting only;
    /// the ledger still moves by the nominal `amount`.
    /// @dev Inside a {distributeFor} the ring path skims {POKE_FEE_BPS} of `amount` for the poker. THE LEDGER IS
    /// UNCHANGED BY THE SKIM: `withdrawnRewards` and `reserve` both move by the full nominal `amount`, and the
    /// skim stays here until {distributeFor} forwards it, so `balance >= reserve` holds throughout. `delivered`
    /// (and so {RewardClaimed}) reports the NET amount the holder received; gross is that plus {PokePaid}.
    /// Only the ring can be running here during a poke -- `nonReentrant` keeps {claim}/{claimTo} out.
    function _pushReward(address account, address to, uint256 amount) internal returns (uint256 delivered) {
        // CEI: debit before the external transfer.
        withdrawnRewards[account] += amount;
        _spend(amount);   // same frame as the transfer below
        uint256 net = amount;
        uint256 f;
        if (_poker != address(0) && amount >= minPoke) {
            f = (amount * POKE_FEE_BPS) / BPS;
            net = amount - f;
        }
        // Measure arrival for the report only. Saturating (a recipient may forward tokens onward) and clamped
        // to `net` (a minting token cannot over-report).
        // (A) sender side -- see the note below. (B) recipient side, for the fee.
        uint256 before = IERC20(quote).balanceOf(address(this));
        uint256 toBefore = IERC20(quote).balanceOf(to);
        IERC20(quote).safeTransfer(to, net);
        // TWO INVARIANTS MEET AT THIS SITE, AND THEY ARE NOT THE SAME QUESTION. Round 16 converted this to a single
        // sender-side number and, in doing so, silently resolved a collision that had never been made visible.
        //
        //   (A) ROUND 15 -- "did the value actually move?" This protects the LEDGER: a token that returns true while
        //       moving nothing must not be recorded as having paid, and a recipient that shuffles its own balance
        //       during the transfer must not be able to forge the answer. Only the SENDER's decrease can answer it,
        //       so `moved` is measured on this contract. It is what {ZeroDelivery} tests.
        //
        //   (B) ROUND 8/9 (L2) -- "how much did the holder actually receive?" This is a PRICING question: the poke
        //       fee is what a third party earns for doing the work, and the work delivered is what LANDED. Only the
        //       RECIPIENT's increase can answer it, so `landed` is measured on `to`.
        //
        // On a well-behaved token the two are equal and nothing here matters. They diverge on a fee-on-transfer
        // token: everything left this contract (`moved == net`) while the holder received less (`landed < net`).
        // Paying the poker a full fee on value the holder never got is the same class of defect round 8 existed to
        // fix -- the poker profits from the token's fee, and in the round-9 case where the fee routes BACK to this
        // tracker it is re-booked on the next sync and charged again, compounding.
        //
        // The ledger is NOT at risk from using the recipient side for (B): `withdrawnRewards` and `_spend` are
        // debited with the NOMINAL amount before the transfer and roll back wholesale on a revert, and `earned` is
        // bounded above by `f`, which was already carved out of the holder's `amount`. A smaller `landed` can only
        // make the poker earn LESS; the unspent remainder stays in this contract and is re-booked to holders. So
        // this direction is strictly conservative, while the reverse (sender-side pricing) is not.
        uint256 aft = IERC20(quote).balanceOf(address(this));
        uint256 moved = before > aft ? before - aft : 0;
        if (moved > net) moved = net;
        uint256 toAft = IERC20(quote).balanceOf(to);
        delivered = toAft > toBefore ? toAft - toBefore : 0;
        if (delivered > net) delivered = net;
        // NOTHING ARRIVED: roll the whole payout back rather than debit a holder for a delivery that did not
        // happen. This unwinds `withdrawnRewards`, the `_spend` and any poke accrual together (transient storage
        // reverts with the frame), so a {distributeFor} caller earns nothing on it, and the ring's try/catch
        // records it as one skipped holder while the rest of the round is still paid.
        // (A): the SENDER-side number decides whether anything moved at all.
        if (moved == 0) revert ZeroDelivery();
        // AUDIT ROUND 9 (L2): the fee is accrued only AFTER delivery is measured, and is SCALED BY THE SHARE THAT
        // ACTUALLY LANDED. Charging the nominal amount let a token that routes part of its transfer fee BACK to this
        // tracker be charged twice: the returned share was re-booked as fresh income on the next sync and paid another
        // {POKE_FEE_BPS}, compounding (a 50% fee measured ~3.9% total instead of 2%). The invariant is unchanged for a
        // well-behaved token -- everything sent lands, so this is exactly {POKE_FEE_BPS} of the gross, skimmed from the
        // delivery -- and a shortfall now reduces the caller's cut in proportion instead of being charged for twice.
        // Native-ETH payouts need no equivalent: a send either moves the value or reverts.
        if (f != 0) {
            // (B): the fee follows what LANDED, per round 8/9 (L2).
            uint256 earned = delivered >= net ? f : Math.mulDiv(f, delivered, net);
            if (earned != 0) _pokeAcc += earned;
        }
        // Reflections (`quote == token`): the payout IS a coin transfer, so the recipient's tracked balance has
        // just gone stale. Do not rely on the coin's own optional credit to repair it -- since audit round 8 that
        // credit reserves the heaviest coin's debit floor and so never runs inside a gas-capped push frame.
        // Reading the real balance here is cheaper than the coin's call and keeps this tracker self-sufficient.
        if (quote == token) _syncBalance(to);
        // Indexed on the earner, not the payee, so accrual queries follow the holder's address.
        emit RewardClaimed(account, delivered);
    }
}
