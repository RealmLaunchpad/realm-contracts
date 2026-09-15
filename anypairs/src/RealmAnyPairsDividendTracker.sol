// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    // Known edge: a holder who acquires exactly the floor and calls {pokePending} can take most of `pending`.
    /// @notice Overflow-safe floor for {minEligible}, derived by the launcher as `totalSupply / 1e4`. Immutable;
    /// it is also the reward-booking gate.
    uint256 public immutable minEligibleFloor;
    /// @notice Creator-settable minimum balance for the auto-push ring. Starts at {minEligibleFloor} and may be
    /// moved within [floor, floor * {MAX_MIN_ELIGIBLE_MULTIPLE}]; it never affects accrual.
    uint256 public minEligible;
    /// @dev Ceiling on {minEligible}: 100x the floor, i.e. 1% of total supply.
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

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
    event MinEligibleSet(uint256 oldValue, uint256 newValue);

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
    }

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    /// @notice Worst-case gas {setBalance} needs, read by {RealmAnyPairsTokenDividend.initTracker}. Constant
    /// because this tracker holds a single denomination.
    function balanceSyncGas() external pure returns (uint256) {
        return 230_000;
    }

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) newBalance = 0;
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
    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) revert NotCreator();
        if (newMinEligible < minEligibleFloor) revert MinEligibleBelowFloor();
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) revert MinEligibleTooHigh();
        if (newMinEligible > eligibleSupply) revert MinEligibleTooHigh();
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
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
    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Book reward buffered while supply was dust, once real supply exists. Permissionless and
    /// uncapped; also happens automatically on the next feed.
    /// @dev Gated on {minEligibleFloor}, not the creator-settable {minEligible}.
    function pokePending() external nonReentrant {
        if (pending != 0 && eligibleSupply >= minEligibleFloor) { uint256 p = pending; pending = 0; _book(p); }
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
        if (eligibleSupply < minEligibleFloor) { pending += amount; return; }
        // Flush any buffered pending first. feed() is not gas-capped, so the extra _book can't be starved.
        if (pending != 0) { uint256 p = pending; pending = 0; _book(p); }
        _book(amount);
    }

    function _book(uint256 amount) internal {
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
        uint256 n = _holders.length; // at most one full ring per call
        if (n == 0) return 0;
        // Honeypot guard: while the V4 lock is held (the token pokes this mid-swap), pay only recipients with
        // no code. Paying a contract there could re-enter the PoolManager and make every later swap revert;
        // no gas cap prevents that. Holders with code are paid out of lock or via {claim}.
        bool inLock = _v4LockHeld();
        uint256 idx = lastProcessedIndex;
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
            // claimable. A codeless destination executes nothing, so it is safe to pay even in lock.
            if (amt != 0 && (!inLock || h.code.length == 0)) {
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
    function _pushReward(address account, address to, uint256 amount, uint256 gasCap) internal {
        withdrawnRewards[account] += amount;
        _spend(amount);   // same frame as the send below: a failed send rolls this back too
        bool ok;
        // gasCap == 0 => forward everything (manual claim); otherwise bound the recipient.
        if (gasCap == 0) {
            (ok,) = payable(to).call{value: amount}("");
        } else {
            (ok,) = payable(to).call{value: amount, gas: gasCap}("");
        }
        if (!ok) revert EthTransferFailed();
        emit RewardClaimed(account, amount);
    }
}
