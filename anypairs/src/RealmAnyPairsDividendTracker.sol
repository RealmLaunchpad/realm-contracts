// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal view into V4's transient-storage reader, used to detect whether a PoolManager operation
/// (swap/modifyLiquidity) currently holds the singleton lock.
interface IExttload {
    function exttload(bytes32 slot) external view returns (bytes32);
}

/**
 * @title RealmAnyPairsDividendTracker
 * @notice Per-coin, immutable dividend accountant for a {RealmAnyPairsTokenDividend} rewards launch. Holds the
 *         reward pool and pays holders their pro-rata share in native ETH.
 * @dev The tax hook (the sole `feeder`) forwards the rewards slice in ETH and it is booked immediately. Holders
 *      are paid by a permissionless round-robin push ({process}) and can always pull via {claim}. Accounting is
 *      magnified-dividend-per-share with per-account corrections; rounding dust stays in the contract. No owner,
 *      no drain: only a holder can be paid, and only their own accrued amount.
 */
contract RealmAnyPairsDividendTracker {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;

    // V4 Lock.IS_UNLOCKED_SLOT: transiently nonzero while a PoolManager operation holds the singleton lock.
    // Untrusted code must never run while it is set -- see {process}.
    bytes32 internal constant V4_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    // ── immutable config ──
    address public immutable token;  // the RealmAnyPairsTokenDividend feeding balances
    address public immutable feeder; // the tax hook, the only address that funds rewards
    address public immutable poolManager; // V4 singleton; gates the auto-push during a swap (0 = ungated, tests)
    // Dust floor: no reward is booked while eligible supply is below it (it is buffered to `pending`). This
    // blocks the per-share pump and 1-wei-latecomer capture, and bounds magnifiedRewardPerShare by
    // D*2^128/minEligibleFloor, which keeps the `toInt256` casts far from overflow for any launchable supply.
    // Audit round 8 (F3) closed the old edge where a holder who acquired exactly the floor and called
    // {pokePending} took most of `pending`: see {_releasePending}.
    /// @notice Overflow-safe floor for {minEligible}, derived by the launcher as `totalSupply / 1e4`. Immutable;
    /// it is also the reward-booking gate.
    uint256 public immutable minEligibleFloor;
    /// @notice Creator-settable minimum balance for the auto-push ring. Starts at {minEligibleFloor} and may be
    /// moved within [floor, floor * {MAX_MIN_ELIGIBLE_MULTIPLE}]; it never affects accrual.
    uint256 public minEligible;
    /// @dev Ceiling on {minEligible}: 100x the floor, i.e. 1% of total supply.
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

    // ── permissionless paid poke ({distributeFor}) ──
    uint256 internal constant BPS = 10_000;
    /// @notice What a {distributeFor} caller is paid, in bps of the rewards that call actually delivers, skimmed
    /// from the delivery itself. Fixed at 2%, matching {RealmAnyPairsPlatformFeeConverter.MAX_REIMBURSE_BPS}; a
    /// creator-settable rate would be a lever to grief searchers or holders, so there is no setter.
    uint256 public constant POKE_FEE_BPS = 200;
    /// @notice Smallest push a {distributeFor} call is paid on, in reward units. A push below it is still made,
    /// in full, for free. Creator-settable (the style of the baskets' `setMinConvert`); 0 = every push pays.
    /// @dev Anti-dust only: it can never withhold a holder's reward, only the caller's cut of it.
    uint256 public minPoke;
    /// @notice Most addresses one {distributeFor} call may repair before it distributes. Bounds the calldata a
    /// searcher can make the ring pay for; a longer list is simply split across calls.
    uint256 public constant MAX_POKE_SYNC = 64;
    /// @dev Per-address cap on a {distributeFor} pre-sync, equal to {balanceSyncGas} -- the same stipend the coin
    /// forwards for one `setBalance`. A repair that does not fit is skipped, never retried in a doomed call.
    uint256 internal constant POKE_SYNC_GAS = 230_000;
    /// @dev Set for the duration of one {distributeFor}; the ring's payouts skim only while it is set, so the
    /// hook's in-swap push, the coin's transfer poke and every manual claim stay free. Transient: it cannot
    /// survive the transaction, and a reverted push rolls its accrual back with the push.
    address private transient _poker;
    uint256 private transient _pokeAcc;

    // ── accounting ──
    uint256 public magnifiedRewardPerShare;
    uint256 public eligibleSupply;
    uint256 public totalDistributed;
    /// @dev Reward buffered while eligible supply is below {minEligibleFloor}. Released by {pokePending} or the
    /// next feed once supply is back over the floor; if it never returns, this balance is unrecoverable.
    uint256 public pending; // reward booked-in-waiting while eligibleSupply is dust/zero

    mapping(address => uint256) public trackedBalance;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;

    // iterable holder set (for the auto-push round-robin)
    address[] private _holders;
    mapping(address => uint256) private _holderIdx1; // 1-based index into _holders; 0 = not a holder
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
    error EthTransferFailed();
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
    event MinEligibleSet(uint256 oldValue, uint256 newValue);
    event MinPokeSet(uint256 amount);
    /// @notice A {distributeFor} call paid `caller` `amount` (ETH), skimmed from the rewards it delivered.
    event PokePaid(address indexed caller, uint256 amount);

    modifier onlyToken() { if (msg.sender != token) revert OnlyToken(); _; }
    modifier onlyFeeder() { if (msg.sender != feeder) revert OnlyFeeder(); _; }
    modifier nonReentrant() { if (_entered == 2) revert Reentrancy(); _entered = 2; _; _entered = 1; }

    struct Config {
        address token;
        address feeder;
        uint256 minEligible; // dust-booking floor; the launcher sets this to totalSupply/1e4 (>=1)
        address[] excluded;
        address poolManager; // V4 singleton; 0 in unit tests -> auto-push lock-gating disabled
    }

    constructor(Config memory c) {
        token = c.token;
        feeder = c.feeder;
        poolManager = c.poolManager;
        // Never 0, so _book can't divide by zero.
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        for (uint256 i; i < c.excluded.length; ++i) excluded[c.excluded[i]] = true;
        // Exclude the coin itself: tokens mis-sent there would otherwise accrue rewards nobody can claim and
        // occupy a permanently failing slot in the payout ring.
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true; // the hook never holds the token; a stray balance must not accrue
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

        // Maintain the iterable holder set (drives the auto-push). Excluded accounts are pinned to 0 above.
        uint256 idx1 = _holderIdx1[account];
        // Ring membership is gated on `minEligible` so dust accounts cannot fill the gas-bounded ring. This
        // withholds only the automatic push; sub-threshold holders still accrue and can {claim}.
        if (newBalance < minEligible) {
            if (idx1 != 0) _removeHolder(account, idx1);
        } else if (idx1 == 0) {
            _holders.push(account);
            _holderIdx1[account] = _holders.length;
        }
        // Do NOT flush `pending` here: setBalance runs under the token's gas-capped try/catch and an OOG
        // would be swallowed. `pending` is flushed by the next feed or by pokePending().
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
    /// with the rest of the reward knobs. Raising it only removes the caller's incentive -- holders are always paid in
    /// full, {claim} is untouched, and the hook's post-swap push keeps running.
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


    /// @dev True while a V4 PoolManager operation holds the singleton lock.
    /// address(0) poolManager (unit tests) => always false.

    /// @dev Whether NATIVE in-swap payouts are currently allowed, read from the feeder's live kill switch under the
    /// key `address(0)` (audit round 10). Unreadable answers as NOT allowed, matching the hook's fail-closed rule:
    /// a denied push is only deferred to {claim}, so failing closed costs a holder nothing.
    function _nativeInSwapAllowed() internal view returns (bool) {
        (bool ok, bytes memory d) =
            feeder.staticcall{gas: 60_000}(abi.encodeWithSignature("inSwapAllowed(address)", address(0)));
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Book reward buffered while supply was dust, once real supply exists. Permissionless and
    /// uncapped; also happens automatically on the next feed.
    /// @dev Gated on {minEligibleFloor}, not the creator-settable {minEligible}.

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
    error RescueFailed();
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
        if (asset == address(0) || asset == token) revert RescueForbiddenAsset(asset);
        // AUDIT ROUND 9 (informational): a full-gas `to.call{value: 0}("")` whose result was discarded used to sit
        // here. It handed an admin-chosen address the whole remaining gas, and its own `nonReentrant` guard was the
        // only thing stopping it re-entering; it bought nothing. Removed.
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
        (bool sent,) = payable(to).call{value: amount}("");
        if (!sent) revert RescueFailed();
        emit StrandedSwept(address(0), to, amount);
    }

    function pokePending() external nonReentrant {
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
    /// @dev Books the measured balance increase rather than a sender-reported amount, so the tracker can never
    /// book value it does not hold.
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

    /// @dev Decrement `reserve` in the same frame as the payout, so a reverted payout rolls it back too.
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

    /// @dev Native balance. `msg.value` has already landed by the time {feed} calls {_sync}.
    function _assetBalance() internal view returns (uint256) {
        return address(this).balance;
    }

    /// @notice The hook forwards the rewards slice in ETH. Books whatever actually arrived.
    /// @dev Deliberately NOT nonReentrant. {claim} forwards uncapped gas while `_entered == 2`; a recipient can
    /// call the hook's distribute, and if this reverted the hook would credit the rewards slice to the creator.
    /// Reentry is harmless here: native value is debited before the callee runs, so {_sync} only books value
    /// actually held.
    function feed() external payable onlyFeeder {
        _sync();
    }

    // ─────────────────────────── internal booking ───────────────────────────

    function _receive(uint256 amount) internal {
        if (amount == 0) return;
        // Never book over a dust supply (it would pump magnifiedRewardPerShare and let a tiny holder capture
        // the batch); buffer to `pending` instead. Gated on the immutable floor so the creator-settable
        // {minEligible} can never stall reward booking.
        if (eligibleSupply < minEligibleFloor) {
            // Round 14: additions are COUNTED, so the proportional target rises with the buffer. That is what
            // makes a top-up harmless -- there is no deadline left for it to be dumped against.
            pendingTotal += amount;
            pending += amount;
            return;
        }
        // Flush any buffered pending first. feed() is not gas-capped, so the extra _book can't be starved.
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

    // Recipient gas cap for the auto-push, so a gas-burning holder can't exhaust the ring's budget.
    // claim() stays uncapped so a contract-wallet holder can always pull.
    //
    // ─── AUDIT ROUND 18: THIS VALUE IS LOAD-BEARING FOR REENTRANCY SAFETY. DO NOT RAISE IT. ───
    // It is not only a budget knob. {feed} is deliberately NOT `nonReentrant`, and during a paid poke the poker's
    // accrued fee sits here as an excess of `address(this).balance` over `reserve` for the whole ring walk -- see
    // {_distributeFor}, which forwards the fee only after the walk. A `feed()` re-entered from inside a recipient
    // payout calls `_sync`, which books exactly that excess as fresh rewards; the same wei is then ALSO paid to the
    // poker, leaving `reserve > balance` so honest claims revert. `test/audit/R18PokeFeeDoubleBook.t.sol` proves
    // that accounting defect is real against this contract with a synthetic cheap feeder.
    //
    // The ONLY thing making it unreachable in production is arithmetic: the tax hook is the sole address {feed}
    // accepts, and its cheapest route into {feed} (`RealmAnyPairsTaxHookPairImmutable.pushOwed`) costs ~76,700 gas
    // against the ~57,200 that 60,000 leaves inside the callback after the EVM's 1/64 reserve. The re-entrant call
    // OOGs, the payout frame reverts, {_process} catches it, and nothing is booked.
    //
    // The sibling trackers use 170,000 (`…Quote.sol` and `…AutoBasket.sol`). Raising this one "for consistency"
    // would make the insolvency live WITHOUT TOUCHING A LINE OF THE AFFECTED LOGIC. Before changing this number --
    // in either direction, and likewise before making any hook feed route cheaper -- run:
    //     forge test --match-test test_R18_TRIPWIRE --threads 1 -vv
    // (`test/audit/R18PokeFeeRealHook.t.sol`). It measures both sides of the margin and fails if either closes it.
    uint256 internal constant PUSH_GAS = 60_000;

    /// @notice Pull `account`'s accrued rewards (funds always go to the account). Forwards uncapped gas so
    /// any contract wallet can withdraw.
    function claim(address account) external nonReentrant returns (uint256 amount) {
        // Repair any balance drift first so a phantom holder cannot claim against tokens it no longer holds.
        _syncBalance(account);
        amount = claimableOf(account);
        if (amount == 0) revert NothingToClaim();
        _pushReward(account, account, amount, 0);
    }

    /// @notice Pull your own rewards to another address. Only the account itself can redirect its accrual.
    /// @dev Lets a holder contract without `receive`/`fallback` recover rewards it cannot accept directly.
    function claimTo(address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        // Same phantom-holder repair as {claim}; see {syncBalance}.
        _syncBalance(msg.sender);
        amount = claimableOf(msg.sender);
        if (amount == 0) revert NothingToClaim();
        _pushReward(msg.sender, to, amount, 0);
    }

    /// @dev Rejects destinations where a reward would be burned, stranded or re-booked (address(0), this
    /// tracker, the coin, the feeder). Self-harm protection only; not the full excluded set.
    function _checkRecipient(address to) internal view {
        if (to == address(0) || to == address(this) || to == token || to == feeder) revert ZeroRecipient();
    }

    /// @notice Round-robin push: pay accrued ETH rewards to holders, bounded by `gasBudget`. Permissionless;
    /// the token pokes it on every transfer and a keeper/UI can too.
    /// @dev Skips zero-owed accounts. Each payout is CEI and isolated, so one reverting recipient can't
    /// double-pay or brick the ring.
    function process(uint256 gasBudget) public nonReentrant returns (uint256 pushed) {
        return _process(gasBudget);
    }

    /// @notice Permissionless PAID poke: book any income, push rewards to holders round-robin, and pay the
    /// caller {POKE_FEE_BPS} of what was delivered, in ETH, skimmed from the delivery. Delivery therefore never
    /// depends on a trade carrying spare gas, and Realm runs no keeper.
    /// @dev Refused inside a V4 unlock: it must not touch an in-flight swap (and `process` would pay only
    /// codeless holders there anyway). Reverts {NothingDelivered} when nothing was paid, so a searcher's losing
    /// attempt costs them gas and nothing else. `gasBudget` is advisory -- the ring is bounded by `gasleft()`
    /// and by one full pass over the holder set either way, so an absurd budget buys nothing.
    function distributeFor(uint256 gasBudget) external nonReentrant returns (uint256 pushed, uint256 fee) {
        return _distributeFor(gasBudget);
    }

    /// @notice {distributeFor}, with a list of addresses to repair FIRST. Since audit round 8 an ordinary
    /// transfer's optional credit usually does not run (AUDIT ROUND 9, informational: NOT because it reserves the
    /// heaviest coin's debit floor -- round 8 reverted that reserve -- but simply because `minNotify` sits above a
    /// typical wallet's gas estimate on a heavy coin), so a fresh
    /// buyer is not in the ring yet; `toSync` puts them in it and pays them in the SAME call.
    /// @dev Each repair is capped at {POKE_SYNC_GAS} and isolated, so one hostile or codeless entry cannot fail
    /// the poke; the gas they spend is charged against `gasBudget`. Repairing alone earns nothing -- the fee is
    /// still only a share of rewards actually delivered -- so a searcher syncs buyers precisely because it makes
    /// them deliverable here. All repairs finish BEFORE the ring starts walking, so the walk sees one stable
    /// holder set; the cursor is re-clamped against the new length inside {_process}.
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
            // Stop rather than start a repair that cannot get its full stipend (EIP-150's 63/64 plus the frame).
            if (gasleft() < POKE_SYNC_GAS + POKE_SYNC_GAS / 63 + 10_000) break;
            try this.syncBalanceSelf{gas: POKE_SYNC_GAS}(toSync[i]) {} catch {}
        }
        uint256 used = g0 - gasleft();
        return _distributeFor(gasBudget > used ? gasBudget - used : 0);
    }

    /// @dev Self-only, gas-capped wrapper so {distributeFor} can isolate one repair. {syncBalance} cannot be
    /// used: it is `nonReentrant` and the poke already holds the guard.
    function syncBalanceSelf(address account) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _syncBalance(account);
    }

    function _distributeFor(uint256 gasBudget) internal returns (uint256 pushed, uint256 fee) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _sync(); // book anything that has arrived but is not yet credited, so the poke delivers it too
        _pokeAcc = 0; // transient, so a second poke in the same transaction starts from zero
        _poker = msg.sender;
        pushed = _process(gasBudget);
        _poker = address(0);
        // A poke that delivers nothing simply pays nothing. It deliberately does NOT revert: anyone could
        // otherwise front-run a searcher with the free `process()` and burn their gas at will (audit round 8).
        // Paying zero is safe; paying on a zero delivery is not, and that is guarded per push instead.
        fee = _pokeAcc;
        if (fee != 0) {
            (bool ok,) = payable(msg.sender).call{value: fee}("");
            if (!ok) revert EthTransferFailed();
        }
        emit PokePaid(msg.sender, fee);
    }

    function _process(uint256 gasBudget) internal returns (uint256 pushed) {
        uint256 n = _holders.length; // at most one full ring per call
        if (n == 0) return 0;
        // Honeypot guard: while the V4 lock is held (the token pokes this mid-swap), pay only recipients with
        // no code. Paying a contract there could re-enter the PoolManager and make every later swap revert;
        // no gas cap prevents that. Holders with code are paid out of lock or via {claim}.
        bool inLock = _v4LockHeld();
        // One read per call, not per holder: the switch cannot change mid-loop.
        bool nativeOk = inLock ? _nativeInSwapAllowed() : true;
        uint256 idx = lastProcessedIndex;
        // The holder set may have changed since the cursor was saved -- a {distributeFor} pre-sync can have
        // appended or swap-and-popped entries. Resume in range; the walk below then steps to idx+1 or wraps to
        // 0, so a grown set is reached within this same pass and a shrunk one restarts rather than reading OOB.
        if (idx >= n) idx = n - 1;
        uint256 gasStart = gasleft();
        uint256 iterations;
        while (iterations < n) {
            // Only start an iteration if a worst-case payout plus the cursor SSTORE still fit, so saving the
            // cursor can never OOG and roll back the run.
            if (gasleft() < PUSH_GAS + 120_000) break;
            uint256 len = _holders.length; // re-read: a payout callback can shrink the set (swap-and-pop)
            if (len == 0) break;
            idx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[idx];
            // No _syncBalance here (too expensive per iteration); use {syncBalance} or {claim}.
            uint256 amt = claimableOf(h);
            // A reverting recipient is skipped; the self-call rolls back its own debit, so the holder stays
            // claimable. A codeless destination executes nothing, so it is safe to pay even in lock -- unless the
            // platform has denied the NATIVE quote in-swap (audit round 10), which is checked once per call below.
            if (amt != 0 && (!inLock || (h.code.length == 0 && nativeOk))) {
                try this.pushReward(h, amt) { unchecked { ++pushed; } }
                catch {
                    emit PushPaymentFailed(h, amt);
                }
            }
            unchecked { ++iterations; }
            if (gasStart - gasleft() > gasBudget) break; // cumulative budget spent -> save cursor, resume later
        }
        lastProcessedIndex = idx;
    }

    /// @dev External self-only wrapper so {process} can isolate one failed payout in try/catch. Always
    /// forwards the PUSH_GAS cap.
    function pushReward(address account, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _pushReward(account, account, amount, PUSH_GAS);
    }

    /// @dev Pay `amount` ETH to `to`, debiting `account`'s ledger. They differ only on the {claimTo} path.
    /// CEI: withdrawn and `reserve` are updated before the send, so a failed send rolls both back.
    /// @dev Inside a {distributeFor} the ring path skims {POKE_FEE_BPS} of `amount` for the poker. The LEDGER IS
    /// UNCHANGED BY THE SKIM: `withdrawnRewards` and `reserve` both move by the full `amount`, and the skim is
    /// held here until {distributeFor} forwards it, so `balance >= reserve` and the sum of claimable are exact.
    /// {RewardClaimed} reports the NET amount the holder received; gross is `RewardClaimed + PokePaid`.
    function _pushReward(address account, address to, uint256 amount, uint256 gasCap) internal {
        withdrawnRewards[account] += amount;
        _spend(amount);   // same frame as the send below: a failed send rolls this back too
        uint256 net = amount;
        // Only the gas-capped ring path (gasCap != 0), and only during a poke: claim/claimTo never pay a fee.
        if (gasCap != 0 && _poker != address(0) && amount >= minPoke) {
            uint256 f = (amount * POKE_FEE_BPS) / BPS;
            if (f != 0) {
                _pokeAcc += f;
                net = amount - f;
            }
        }
        bool ok;
        // gasCap == 0 => forward everything (manual claim); otherwise bound the recipient.
        if (gasCap == 0) {
            (ok,) = payable(to).call{value: net}("");
        } else {
            (ok,) = payable(to).call{value: net, gas: gasCap}("");
        }
        // WHY THE NATIVE TRACKERS NEED NO {ZeroDelivery} (audit round 16, the uniform delivery rule). The hazard the
        // guard exists for is an ERC20 that returns true and moves nothing -- a soft blocklist. Native ETH has no
        // such mode: `call{value:}` either moves the value or returns false, and every native path here already
        // reverts on false. There is nothing for a sender-side measurement to detect that `ok` does not already
        // catch, so measuring would add gas and no safety. Documented rather than left to be rediscovered as drift.
        if (!ok) revert EthTransferFailed();
        emit RewardClaimed(account, net);
    }
}
