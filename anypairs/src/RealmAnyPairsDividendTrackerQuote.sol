// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    event MinEligibleSet(uint256 oldValue, uint256 newValue);

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


    /// @dev True while a V4 swap holds the PoolManager lock. address(0) poolManager (tests) => always false.
    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Book reward buffered while supply was dust, once real supply exists. Permissionless.
    function pokePending() external nonReentrant {
        // Gated on {minEligibleFloor}, NOT on the creator-settable {minEligible}.
        if (pending != 0 && eligibleSupply >= minEligibleFloor) { uint256 p = pending; pending = 0; _book(p); }
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
        if (eligibleSupply < minEligibleFloor) { pending += amount; return; }
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
    /// Permissionless; the token pokes it on every transfer and a keeper/UI can too.
    /// @dev Each payout is CEI and isolated in try/catch.
    function process(uint256 gasBudget) public nonReentrant returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) return 0;
        // Honeypot guard: while the V4 lock is held, pay nobody unless the hook allows in-swap payouts for this
        // quote. A code-length check is not enough here (callback-bearing tokens can invoke handlers for
        // codeless recipients), so the decision is per quote. See {_inSwapAllowed}.
        if (_v4LockHeld() && !_inSwapAllowed()) return 0;
        uint256 idx = lastProcessedIndex;
        uint256 gasStart = gasleft();
        uint256 iterations;
        while (iterations < n) {
            // Reserve room for a capped payout plus the iteration overhead and the cursor SSTORE, so saving the
            // cursor can never OOG. Differs from the ETH tracker because PUSH_GAS covers more here.
            if (gasleft() < PUSH_GAS + 40_000) break; // leave room for a payout + the cursor SSTORE
            uint256 len = _holders.length;
            if (len == 0) break;
            idx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[idx];
            // No _syncBalance here (too expensive per iteration); use {syncBalance} or {claim}.
            uint256 amt = claimableOf(h);
            if (amt != 0) {
                try this.pushReward{gas: PUSH_GAS}(h, amt) { unchecked { ++pushed; } }
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
    function pushReward(address account, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _pushReward(account, account, amount);
    }

    /// @dev Pays `to` and debits the full nominal `amount` from `account` up front (CEI), with no refund of any
    /// shortfall: a measured debit is attacker-influenceable. Any fee taken in transit is borne by the holder.
    /// @param account whose ledger is debited -- always the earner, never the payee.
    /// @param to where the tokens actually go. Equal to `account` on every path except {claimTo}.
    /// @return delivered what the recipient's balance actually rose by, clamped to `amount`. Reporting only;
    /// the ledger still moves by the nominal `amount`.
    function _pushReward(address account, address to, uint256 amount) internal returns (uint256 delivered) {
        // CEI: debit before the external transfer.
        withdrawnRewards[account] += amount;
        _spend(amount);   // same frame as the transfer below
        // Measure arrival for the report only. Saturating (a recipient may forward tokens onward) and clamped
        // to `amount` (a minting token cannot over-report).
        uint256 before = IERC20(quote).balanceOf(to);
        IERC20(quote).safeTransfer(to, amount);
        uint256 aft = IERC20(quote).balanceOf(to);
        delivered = aft > before ? aft - before : 0;
        if (delivered > amount) delivered = amount;
        // Indexed on the earner, not the payee, so accrual queries follow the holder's address.
        emit RewardClaimed(account, delivered);
    }
}
