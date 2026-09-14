// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {RealmAnyPairsRouteLib} from "./RealmAnyPairsRouteLib.sol";

/// @dev The chain's real Uniswap V3 factory. `getPool` is a deterministic lookup that no token can redirect.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}

interface ISwapRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IExttload { function exttload(bytes32 slot) external view returns (bytes32); }

/**
 * @title RealmAnyPairsDividendTrackerBasket
 * @notice Reward tracker that accrues in the pool's quote token and pays claims as a weighted basket of assets.
 * @dev Accrual matches {RealmAnyPairsDividendTrackerQuote}. On claim the accrual is split by leg weight and each leg
 *      is swapped straight to the holder; a direct leg (asset == quote) is paid as quote.
 *      Only the holder's own claim ever swaps, and it refuses to run inside a V4 unlock. {process} and
 *      {processHolders} pay raw quote only, so no third party ever picks a holder's execution price. {process} may
 *      run mid-swap unless the quote is denied in {RealmAnyPairsInSwapRegistry}.
 *      Immutable, no owner, no drain; the basket is fixed at construction.
 */
contract RealmAnyPairsDividendTrackerBasket {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint16 internal constant BPS = 10000;
    // Each leg is a real swap inside one atomic claim; on an immutable basket an unbounded count is a permanent gas DoS.
    uint256 internal constant MAX_LEGS = 10;
    // Gas forwarded to one leg's swap self-call, so a griefed (fragmented) pool fails only its own leg instead of
    // pushing the whole claim past the block gas limit. Sized for a single-hop route only. Shared with
    // {RealmAnyPairsDividendTrackerMultiBasket}, whose larger leg bound is the binding one for any change.
    uint256 internal constant LEG_GAS_CAP = 450_000;

    // Gas forwarded to one raw-quote push inside {process}.
    uint256 internal constant PUSH_GAS = 170_000;

    // Gas forwarded to one holder's raw-quote payout inside {processHolders}. Capped so one gas-burning pair cannot
    // eat the keeper's whole transaction; larger than {PUSH_GAS} because it also runs {_syncBalance}.
    uint256 internal constant PROCESS_HOLDER_GAS = 330_000;

    address public immutable token;      // the RealmAnyPairsTokenDividend feeding balances
    address public immutable feeder;     // the tax hook, the only address that funds rewards
    address public immutable quote;      // the ERC-20 rewards accrue in (the pool's quote token)
    address public immutable swapRouter; // SwapRouter02, converts quote -> each basket leg at claim time
    /// @notice The real Uniswap V3 factory, used to discover each non-direct leg's route.
    address public immutable v3Factory;
    /// @dev Only read by {_v4LockHeld}. Zero disables the gate.
    address public immutable poolManager;
    /// @dev `PoolManager.isUnlocked`'s transient slot.
    bytes32 internal constant V4_IS_UNLOCKED_SLOT =
        0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    /// @notice Immutable overflow-safe floor (`totalSupply / 1e4` from the launcher). It gates reward booking, so
    /// `magnifiedRewardPerShare <= D*2^128/minEligibleFloor` regardless of {minEligible}.
    uint256 public immutable minEligibleFloor;
    /// @notice Creator-settable auto-push eligibility floor; see {setMinEligible}. Can move up or down within bounds.
    uint256 public minEligible;
    /// @dev Ceiling on {minEligible}: 100x the floor, i.e. 1% of supply.
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;
    uint256 public immutable legCount;

    // Basket legs, flattened into parallel mappings (Solidity has no immutable structs/arrays).
    mapping(uint256 => address) private _legAsset;
    mapping(uint256 => uint16) private _legBps;
    /// @dev Set only across this contract's own V4 unlock, so {unlockCallback} runs on nothing else.
    bool private transient _v4Swapping;

    uint256 public magnifiedRewardPerShare;
    uint256 public eligibleSupply;
    uint256 public totalDistributed;
    /// @dev Income buffered while eligible supply is below {minEligibleFloor}. PERMANENTLY UNRECOVERABLE if supply
    /// never returns above the floor: there is no owner, drain or rescue.
    uint256 public pending;

    mapping(address => uint256) public trackedBalance;
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnRewards;
    mapping(address => bool) public excluded;

    // Iterable holder ring for the raw-quote auto-push in {process}.
    address[] private _holders;
    mapping(address => uint256) private _holderIdx1;
    uint256 public lastProcessedIndex;

    uint256 private _entered = 1;

    event RewardsDistributed(uint256 amount, uint256 perShare);
    /// @notice The balance is below the baseline backing booked claims. New income repairs the shortfall before
    /// it accrues.
    event RewardShortfall(uint256 reserve, uint256 balance);

    /// @notice {_spend} found `reserve` smaller than `amount` and clamped it to zero. Should be unreachable; if it
    /// fires the ledger is broken and the next sync may double-book, so monitors should alert on it.
    event ReserveUnderrun(uint256 reserve, uint256 amount);
    event RewardClaimed(address indexed account, address indexed asset, uint256 amount);
    event LegSwapFailed(address indexed account, address indexed asset, uint256 quoteAmount);
    event LegPaymentFailed(address indexed account, address indexed asset, uint256 quoteAmount);

    /// @notice A holder's payout inside {processHolders} failed (gas cap, reverting transfer, or nothing accrued).
    /// Nothing is lost: the debit is unwound with the frame and the accrual stays claimable.
    event HolderPayoutFailed(address indexed holder);

    error OnlyToken();
    error OnlyFeeder();
    error Reentrancy();
    error NothingToClaim();
    error ZeroRecipient();
    error BadBasket();
    error NoRouteFound();
    error BadMinOuts();
    error BadRoutes();
    error OnlySelf();
    error InsufficientGasForLeg();
    /// @dev A leg swap failed while the caller set a non-zero `minOut`; the accrual is preserved for a retry.
    error LegMinOutUnmet();
    /// @dev The recipient's measured balance delta came in under `minOut` (e.g. a fee-on-transfer leg asset).
    error RealizedBelowMinOut();
    /// @dev A claim was attempted from inside a V4 unlock.
    error NotDuringSwap();
    error NotCreator();
    error MinEligibleBelowFloor();
    error MinEligibleTooHigh();
    event MinEligibleSet(uint256 oldValue, uint256 newValue);

    modifier onlyToken() { if (msg.sender != token) revert OnlyToken(); _; }
    modifier onlyFeeder() { if (msg.sender != feeder) revert OnlyFeeder(); _; }
    modifier nonReentrant() { if (_entered == 2) revert Reentrancy(); _entered = 2; _; _entered = 1; }

    struct Leg { address asset; uint16 bps; }

    struct Config {
        address token;
        address feeder;
        address quote;
        address swapRouter;
        /// @dev The real Uniswap V3 factory. Required whenever any leg's asset differs from the quote.
        address v3Factory;
        /// @dev Read-only; used only to detect a held V4 unlock. See {_v4LockHeld}.
        address poolManager;
        uint256 minEligible;
        address[] excluded;
        Leg[] basket;
    }

    constructor(Config memory c) {
        token = c.token;
        feeder = c.feeder;
        quote = c.quote;
        swapRouter = c.swapRouter;
        v3Factory = c.v3Factory;
        poolManager = c.poolManager;
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        for (uint256 i; i < c.excluded.length; ++i) excluded[c.excluded[i]] = true;
        // Tokens mis-sent to the coin contract must not accrue unclaimable rewards.
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true;
        // The router keeps quote dust mid-swap; it must not accrue rewards against it.
        if (c.swapRouter != address(0)) excluded[c.swapRouter] = true;

        uint256 n = c.basket.length;
        if (n == 0 || n > MAX_LEGS) revert BadBasket();
        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            Leg memory leg = c.basket[i];
            if (leg.asset == address(0) || leg.bps == 0) revert BadBasket();
            sumBps += leg.bps;
            _legAsset[i] = leg.asset;
            _legBps[i] = leg.bps;
        }
        if (sumBps != BPS) revert BadBasket();
        legCount = n;
    }
    function basketLeg(uint256 i) external view returns (address asset, uint16 bps, bytes memory path) {
        asset = _legAsset[i];
        bps = _legBps[i];
        // The route a conversion would take right now (empty for a direct leg or when none exists).
        if (asset != quote) {
            path = RealmAnyPairsRouteLib.encode(
                RealmAnyPairsRouteLib.best(swapRouter == address(0) ? address(0) : v3Factory, poolManager, quote, false, asset),
                asset
            );
        }
    }



    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    /// @notice Worst-case gas {setBalance} needs; read by {RealmAnyPairsTokenDividend.initTracker}. Constant here
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
        // Ring membership is gated on `minEligible` so dust accounts cannot fill the gas-bounded ring. Accrual above
        // is unaffected; sub-threshold holders just claim instead of being pushed.
        if (newBalance < minEligible) {
            if (idx1 != 0) _removeHolder(account, idx1);
        } else if (idx1 == 0) {
            _holders.push(account);
            _holderIdx1[account] = _holders.length;
        }
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

    /// @notice Creator-only: set the minimum balance for the auto-push ring, between {minEligibleFloor} and
    /// {MAX_MIN_ELIGIBLE_MULTIPLE}x it, and not above the current {eligibleSupply}.
    /// @dev Only ring membership depends on this; accrual continues for holders below it. Booking is gated on the
    /// immutable floor, so this setter cannot strand rewards in `pending` or weaken the overflow bound.
    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) revert NotCreator();
        if (newMinEligible < minEligibleFloor) revert MinEligibleBelowFloor();
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) revert MinEligibleTooHigh();
        if (newMinEligible > eligibleSupply) revert MinEligibleTooHigh();
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
    }

    /// @dev The coin's current creator. Low-level and fail-closed: a token or feeder that will not answer yields
    /// {NotCreator}, so nobody can move the floor.
    function _tokenCreator() internal view returns (address c) {
        // Prefer the hook's record so a creator hand-off or renounce is respected; fall back to the coin's `creator()`.
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



    /// @notice Permissionless repair of a `trackedBalance` that drifted from the token's real balance (e.g. a
    /// notify skipped under starved gas). Can only move state toward the truth.
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
        // Low-level so a revert or short return skips the repair instead of bricking {process} or a claim.
        // Uncapped on purpose: `token` is the immutable launcher-deployed coin with a plain `balanceOf`.
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(0x70a08231, account)); // balanceOf(address)
        if (!ok || ret.length < 32) return;
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) _applyBalance(account, real);
    }



    /// @notice Round-robin push of the raw accrued quote; never converts legs.
    /// @dev A basket conversion calls external router code, so it never runs here. A plain quote transfer can run
    /// mid-swap unless the quote is denied via {_inSwapAllowed}.
    function process(uint256 gasBudget) external nonReentrant returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) return 0;
        if (_v4LockHeld() && !_inSwapAllowed()) return 0;
        uint256 idx = lastProcessedIndex;
        uint256 gasStart = gasleft();
        uint256 iterations;
        while (iterations < n) {
            // PUSH_GAS covers the capped payout; +40_000 covers the SLOADs, try/catch frame and cursor SSTORE.
            if (gasleft() < PUSH_GAS + 40_000) break;
            uint256 len = _holders.length; // re-read: a payout can shrink the set via {_removeHolder}
            if (len == 0) break;
            idx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[idx];
            // No _syncBalance in the hot loop; claims and {syncBalance} repair drift.
            uint256 amt = claimableOf(h);
            if (amt != 0) {
                // The debit lives inside the capped {pushReward} frame, so a revert unwinds it and the loop reserve
                // only has to cover the cursor SSTORE. Do not raise the reserve: it would cut off in-swap pushes.
                try this.pushReward{gas: PUSH_GAS}(h, amt) { unchecked { ++pushed; } }
                catch {
                    // No rollback: the debit is inside the reverted frame and is already undone.
                    emit LegPaymentFailed(h, quote, amt);
                }
            }
            unchecked { ++iterations; }
            if (gasStart - gasleft() > gasBudget) break;
        }
        lastProcessedIndex = idx;
    }

    /// @dev Self-only, gas-capped payout for {process}. The ledger debit and `_spend` sit in this frame so a failed
    /// payout unwinds them.
    function pushReward(address account, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        withdrawnRewards[account] += amount; // CEI: debited before the transfer, in the same frame
        _spend(amount); // same frame as the transfer: a revert rolls it back
        // The debit stays nominal; only the event reports the measured inflow (saturating, clamped to `amount`).
        uint256 before = IERC20(quote).balanceOf(account);
        IERC20(quote).safeTransfer(account, amount);
        uint256 aft = IERC20(quote).balanceOf(account);
        uint256 delivered = aft > before ? aft - before : 0;
        if (delivered > amount) delivered = amount;
        emit RewardClaimed(account, quote, delivered);
    }

    /// @dev The hook's live answer (default true unless the quote is denied). Any failed or malformed call reads
    /// as not allowed.
    function _inSwapAllowed() internal view returns (bool) {
        (bool ok, bytes memory d) =
            feeder.staticcall{gas: 60_000}(abi.encodeWithSignature("inSwapAllowed(address)", quote));
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    /// @notice Permissionless, out-of-swap payout of a caller-supplied list of holders, in raw quote only.
    /// @dev No swap on a holder's behalf, so there is no execution price to manipulate. Each holder is isolated in
    /// a gas-capped self-call; a failure skips only that holder. `gasBudget` bounds total work.
    function processHolders(address[] calldata holders, uint256 gasBudget)
        external
        nonReentrant
        returns (uint256 processed)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        uint256 gasStart = gasleft();
        for (uint256 i; i < holders.length; ++i) {
            if (gasStart - gasleft() > gasBudget) break;
            try this._processHolder{gas: PROCESS_HOLDER_GAS}(holders[i]) {
                unchecked { ++processed; }
            } catch {
                emit HolderPayoutFailed(holders[i]);
            }
        }
    }

    /// @dev Self-only. Pays `holder` themselves; a third party can trigger a payout but never redirect it.
    function _processHolder(address holder) external {
        if (msg.sender != address(this)) revert OnlySelf();
        // Repair a starved-gas desync before paying, so a phantom balance cannot be paid.
        _syncBalance(holder);
        uint256 amt = claimableOf(holder);
        if (amt == 0) revert NothingToClaim();
        withdrawnRewards[holder] += amt; // CEI: bumped before the transfer, in this same frame
        _spend(amt);
        // Not routed through {_payDirect}: a reverting transfer unwinds this whole frame, so `processed` counts
        // only holders actually paid. The debit is nominal; the event reports the measured inflow.
        uint256 before = IERC20(quote).balanceOf(holder);
        IERC20(quote).safeTransfer(holder, amt);
        uint256 aft = IERC20(quote).balanceOf(holder);
        uint256 delivered = aft > before ? aft - before : 0;
        if (delivered > amt) delivered = amt;
        emit RewardClaimed(holder, quote, delivered);
    }

    function pokePending() external nonReentrant {
        // Gated on the immutable {minEligibleFloor}, not {minEligible}.
        if (pending != 0 && eligibleSupply >= minEligibleFloor) { uint256 p = pending; pending = 0; _book(p); }
    }

    // ─────────────────────────── feeding (hook-driven) ───────────────────────────

    /// @notice Quote already accounted for; any balance above it is unbooked income.
    uint256 public reserve;

    /// @notice Book any quote that arrived but has not been credited. Permissionless and idempotent.
    /// @dev Measuring the balance means the tracker never books value it does not physically hold.
    function sync() public nonReentrant {
        _sync();
    }

    function _sync() internal {
        uint256 bal = _assetBalance();
        if (bal <= reserve) {
            // Never write `reserve` down: a shortfall holds the baseline so later income repairs it first.
            // Emit only on a strict shrink; equality is the normal idle state.
            if (bal < reserve) emit RewardShortfall(reserve, bal);
            return;
        }
        uint256 delta = bal - reserve;
        reserve = bal;
        _receive(delta);
    }

    /// @dev Decrement in the same frame as the transfer, so a reverted payout rolls it back.
    function _spend(uint256 amount) internal {
        uint256 r = reserve;
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

    /// @notice Called by the hook after it transfers the rewards slice. The argument is ignored; {sync} books the
    /// measured increase.
    /// @dev onlyFeeder and nonReentrant are both load-bearing: without them a reentrant leg asset could book quote
    /// still in flight.
    function feedToken(uint256) external onlyFeeder nonReentrant {
        _sync();
    }

    function _receive(uint256 amount) internal {
        if (amount == 0) return;
        // Gated on the immutable floor, never the creator-settable {minEligible}, so the creator cannot divert
        // income into `pending`.
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

    /// @dev The `acc <= 0` clamp is unreachable (accrual is monotonic). It deliberately does not fail safe: a broken
    /// ledger makes {claimableOf} revert and halts payouts rather than draining quietly.
    function accumulativeOf(address account) public view returns (uint256) {
        int256 acc = (magnifiedRewardPerShare * trackedBalance[account]).toInt256() + magnifiedCorrections[account];
        return acc <= 0 ? 0 : uint256(acc) / MAGNITUDE;
    }

    function claimableOf(address account) public view returns (uint256) {
        return accumulativeOf(account) - withdrawnRewards[account];
    }

    // ─────────────────────────── claim (basket conversion) ───────────────────────────

    /// @notice Claim the caller's accrual as the basket with no price floor on any leg. A leg whose swap fails is
    /// paid in raw quote instead.
    /// @dev Named for what it waives: there is deliberately no `claim()`. Prefer {claimWithMinOuts}.
    function claimAtAnyPrice() external returns (uint256 totalAmount) {
        uint256[] memory zero = new uint256[](legCount);
        return claimToWithMinOuts(msg.sender, zero);
    }

    /// @notice {claimAtAnyPrice}, paid to `to` (useful when a leg asset freezes the holder's own address).
    function claimToAtAnyPrice(address to) external returns (uint256 totalAmount) {
        uint256[] memory zero = new uint256[](legCount);
        return claimToWithMinOuts(to, zero);
    }

    function claimWithMinOuts(uint256[] memory minOuts) external returns (uint256 totalAmount) {
        return claimToWithMinOuts(msg.sender, minOuts);
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Claim with a per-leg `amountOutMinimum` (basket leg order; 0 = no floor), paid to `to`.
    /// @dev A failed leg with a non-zero floor reverts {LegMinOutUnmet} and preserves the accrual. Only a zero floor
    /// gets the raw-quote fallback.
    function claimToWithMinOuts(address to, uint256[] memory minOuts) public nonReentrant returns (uint256 totalAmount) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        return _claim(msg.sender, to, minOuts, new bytes[](legCount));
    }
    /// @notice Claim with a caller-supplied route per leg. An empty route is discovered on-chain; otherwise it is a
    /// 43-byte V3 path or an ABI-encoded V4 `PoolKey` (the only way to reach a hooked V4 pool).
    /// @dev Every supplied route is validated before anything is paid and may not route through {feeder}.
    function claimWithRoutes(uint256[] memory minOuts, bytes[] memory routes) external returns (uint256 totalAmount) {
        return claimToWithRoutes(msg.sender, minOuts, routes);
    }

    /// @notice {claimWithRoutes}, paid to `to`.
    function claimToWithRoutes(address to, uint256[] memory minOuts, bytes[] memory routes)
        public
        nonReentrant
        returns (uint256 totalAmount)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        _requireRoutes(routes);
        return _claim(msg.sender, to, minOuts, routes);
    }

    /// @dev Validates every supplied route up front, so a bad one fails the claim loudly instead of being swallowed by
    /// {_payLeg}'s fallback.
    function _requireRoutes(bytes[] memory routes) internal view {
        if (routes.length != legCount) revert BadRoutes();
        for (uint256 i; i < routes.length; ++i) {
            if (routes[i].length == 0 || _legAsset[i] == quote) continue;
            RealmAnyPairsRouteLib.supplied(routes[i], swapRouter == address(0) ? address(0) : v3Factory, poolManager, quote, false, _legAsset[i], feeder);
        }
    }

    /// @dev Rejects recipients where a reward would be burned, stranded or re-booked (this tracker re-books on
    /// {sync}). Guards against UI mistakes; it does not cover every excluded address.
    function _checkRecipient(address to) internal view {
        if (
            to == address(0) || to == address(this) || to == token || to == quote || to == swapRouter
                || to == feeder || to == poolManager
        ) revert ZeroRecipient();
    }

    /// @dev Self-claim body: debit the whole accrual, then pay each leg by weight. `account` is always `msg.sender`.
    function _claim(address account, address to, uint256[] memory minOuts, bytes[] memory routes)
        internal
        returns (uint256 totalAmount)
    {
        if (minOuts.length != legCount) revert BadMinOuts();
        if (routes.length != legCount) revert BadRoutes();
        _syncBalance(account);
        totalAmount = claimableOf(account);
        if (totalAmount == 0) revert NothingToClaim();
        withdrawnRewards[account] += totalAmount; // CEI: bumped before any transfer/swap below
        uint256 n = legCount;
        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            address asset = _legAsset[i];
            uint256 legAmt = i + 1 == n
                ? totalAmount - distributed // last leg takes the remainder, avoids bps-rounding dust loss
                : (totalAmount * _legBps[i]) / BPS;
            distributed += legAmt;
            if (legAmt == 0) continue;
            _payLeg(account, to, asset, legAmt, minOuts[i], routes[i]);
        }
    }

    /// @dev Pays one leg. Direct legs and failed swaps go through {_payDirect}, which re-credits on a reverted
    /// transfer so one blocked leg cannot brick the others.
    /// @param account Ledger that was debited; always `msg.sender`, so `minOut` is always the holder's own choice.
    function _payLeg(address account, address to, address asset, uint256 quoteAmt, uint256 minOut, bytes memory route)
        internal
    {
        if (asset == quote) {
            // Direct leg: no swap, so no price floor applies.
            _payDirect(account, to, quoteAmt);
            return;
        }
        // Require enough gas for the full capped leg, so a caller's short gas limit reverts instead of silently
        // degrading to the raw-quote fallback.
        if (gasleft() < LEG_GAS_CAP * 64 / 63 + 30_000) revert InsufficientGasForLeg();

        try this._executeSwap{gas: LEG_GAS_CAP}(to, asset, quoteAmt, minOut, route) returns (uint256 out) {
            emit RewardClaimed(account, asset, out);
        } catch {
            // The raw-quote fallback is opt-in: a caller who set a floor gets the claim unwound and can retry
            // (with minOut = 0 if the pool is genuinely griefed).
            if (minOut != 0) revert LegMinOutUnmet();
            emit LegSwapFailed(account, asset, quoteAmt);
            _payDirect(account, to, quoteAmt); // fall back to raw quote -- itself failure-isolated, see _payDirect
        }
    }

    /// @dev Self-only, so {_payLeg} can try/catch the whole approve+swap+reset sequence. `out` is the recipient's
    /// measured balance delta, not the router's reported amount.
    function _executeSwap(address account, address asset, uint256 quoteAmt, uint256 minOut, bytes memory route)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        // Caller's route if supplied, otherwise discovered now; inside the capped frame either way.
        RealmAnyPairsRouteLib.Route memory r = route.length == 0
            ? RealmAnyPairsRouteLib.best(swapRouter == address(0) ? address(0) : v3Factory, poolManager, quote, false, asset)
            : RealmAnyPairsRouteLib.supplied(route, swapRouter == address(0) ? address(0) : v3Factory, poolManager, quote, false, asset, feeder);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_NONE) revert NoRouteFound();
        uint256 before = IERC20(asset).balanceOf(account);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            IERC20(quote).forceApprove(swapRouter, quoteAmt);
            ISwapRouter02(swapRouter).exactInput(
                ISwapRouter02.ExactInputParams({
                    path: RealmAnyPairsRouteLib.v3Path(r, asset), recipient: account, amountIn: quoteAmt, amountOutMinimum: minOut
                })
            );
            IERC20(quote).forceApprove(swapRouter, 0);
        } else {
            _v4Swapping = true;
            IPoolManager(poolManager).unlock(
                abi.encode(account, quote, asset, r.fee, r.tickSpacing, r.hooks, quoteAmt, minOut)
            );
            _v4Swapping = false;
        }
        uint256 aft = IERC20(asset).balanceOf(account);
        out = aft > before ? aft - before : 0;
        if (out < minOut) revert RealizedBelowMinOut();
        _spend(quoteAmt);
    }
    /// @notice PoolManager callback for a V4 leg swap started by {_executeSwap}; runs only inside this contract's own unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager || !_v4Swapping) revert OnlySelf();
        (
            address to,
            address tokenIn,
            address asset,
            uint24 fee,
            int24 spacing,
            address hooks,
            uint256 amountIn,
            uint256 minOut
        ) = abi.decode(data, (address, address, address, uint24, int24, address, uint256, uint256));
        IPoolManager pm = IPoolManager(poolManager);
        uint256 out = RealmAnyPairsRouteLib.swapExactIn(
            pm, RealmAnyPairsRouteLib.poolKey(tokenIn, asset, fee, spacing, hooks), tokenIn, amountIn
        );
        if (out < minOut) revert RealizedBelowMinOut();
        RealmAnyPairsRouteLib.settleAndTake(pm, tokenIn, amountIn, asset, to, out);
        return "";
    }

    /// @dev Pays raw quote: a direct leg, or the fallback for a failed swap. On success the nominal amount stays
    /// debited (no shortfall refund); if the transfer reverts, the amount is re-credited.
    function _payDirect(address account, address to, uint256 quoteAmt) internal {
        // Self-call with SafeERC20 so tokens that return no bool still succeed and only real reverts are caught.
        try this._transferDirect(to, quoteAmt) returns (uint256 delivered) {
            emit RewardClaimed(account, quote, delivered);
        } catch {
            withdrawnRewards[account] -= quoteAmt; // undo the CEI debit -- these funds were never actually paid
            emit LegPaymentFailed(account, quote, quoteAmt);
        }
    }

    /// @dev Self-only so {_payDirect} can try/catch a SafeERC20 transfer.
    /// @return delivered The recipient's measured inflow (saturating), clamped to `quoteAmt`. Used only for the event.
    function _transferDirect(address account, uint256 quoteAmt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) revert OnlySelf();
        _spend(quoteAmt);   // same frame as the transfer: a revert rolls this back
        uint256 before = IERC20(quote).balanceOf(account);
        IERC20(quote).safeTransfer(account, quoteAmt);
        uint256 aft = IERC20(quote).balanceOf(account);
        delivered = aft > before ? aft - before : 0;
        if (delivered > quoteAmt) delivered = quoteAmt;
    }
}
