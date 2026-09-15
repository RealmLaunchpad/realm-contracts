// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {RealmAnyPairsRouteLib} from "./RealmAnyPairsRouteLib.sol";

interface ISwapRouter02 {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice The chain's real Uniswap V3 factory. `getPool` is a deterministic lookup that no token can redirect.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}

interface IExttload { function exttload(bytes32 slot) external view returns (bytes32); }

/**
 * @title RealmAnyPairsDividendTrackerMultiBasket
 * @notice Unified reward tracker for a coin launched with multiple pools, each possibly paying tax in a different
 *         quote token ("denomination"). One claim pays every denomination, each converted into its own basket
 *         with the same swap/floor/fallback logic as {RealmAnyPairsDividendTrackerBasket}.
 * @dev The creator names only each leg's asset and weight; routes are discovered by {RealmAnyPairsRouteLib.best}
 *      and nothing is curated. A creator-chosen asset with a thin or creator-owned pool is an accepted risk;
 *      holders can inspect {basketLeg}.
 *      The denomination set is fixed at construction because the hook's `feedToken` does not say which token
 *      arrived. Every balance change updates a correction per denomination, so {balanceSyncGas} grows with the
 *      count and {ABSOLUTE_MAX_DENOMINATIONS} bounds it.
 */
contract RealmAnyPairsDividendTrackerMultiBasket {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint16 internal constant BPS = 10000;
    uint256 internal constant MAX_LEGS = 10;
    // Gas forwarded to one leg's swap self-call, so a griefed (fragmented) pool fails only its own leg instead of
    // pushing the claim past the block gas limit. Sized for a single-hop route. Any change must keep
    // `MAX_TOTAL_LEGS x (LEG_GAS_CAP * 64 / 63 + 30,000)` inside a block, and must be mirrored in the Basket twin.
    uint256 internal constant LEG_GAS_CAP = 450_000;

    // Gas forwarded to one holder's raw payout inside {processHolders}: a base plus a per-denomination part,
    // capped so one gas-burning pair cannot eat the keeper's whole transaction.
    uint256 internal constant PROCESS_HOLDER_BASE_GAS = 140_000;
    /// @dev Per-denomination part of the {processHolders} cap. Sized for compliance-gated, upgradeable stock
    /// tokens with headroom; too low and every holder of a large basket is silently skipped.
    uint256 internal constant PROCESS_HOLDER_PER_DENOM_GAS = 200_000;

    /// @dev Hard safety ceiling on denominations. Bounds the per-transfer correction loop (see {balanceSyncGas})
    /// and, with {MAX_TOTAL_LEGS}, the whole-basket claim. The launcher enforces a lower product limit.
    uint256 internal constant ABSOLUTE_MAX_DENOMINATIONS = 25;

    /// @dev Total legs across every denomination, so even the whole-basket claim stays callable within a block.
    /// {claimDenominations} lets a holder claim a subset.
    uint256 internal constant MAX_TOTAL_LEGS = 60;

    /// @dev Gas forwarded to one raw-denomination push in {process}; never a leg conversion.
    uint256 internal constant PUSH_GAS = 170_000;

    /// @dev The two parts of {balanceSyncGas}: the fixed cost of a balance update plus one correction per
    /// denomination, both with margin.
    uint256 internal constant SYNC_BASE_GAS = 170_000;
    uint256 internal constant SYNC_PER_DENOM_GAS = 34_000;

    address public immutable token;
    address public immutable feeder;
    address public immutable swapRouter;
    address public immutable poolManager;
    /// @notice The real Uniswap V3 factory, used to discover each non-direct leg's route.
    address public immutable v3Factory;
    bytes32 internal constant V4_IS_UNLOCKED_SLOT =
        0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    /// @notice Immutable overflow-safe floor (`totalSupply / 1e4` from the launcher). It gates reward booking, so
    /// `magnifiedRewardPerShare <= D*2^128/minEligibleFloor` regardless of {minEligible}.
    uint256 public immutable minEligibleFloor;
    /// @notice Creator-settable auto-push eligibility floor; see {setMinEligible}. Can move up or down within bounds.
    uint256 public minEligible;
    /// @dev Ceiling on {minEligible}: 100x the floor, i.e. 1% of supply.
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

    /// @notice The fixed set of denominations this tracker was launched with. Grows ONLY at construction.
    address[] public denominations;
    mapping(address => bool) public isDenomination;

    /// @notice A leg names an output asset and a weight; its route is discovered, never supplied by the creator.
    struct Leg { address asset; uint16 bps; }
    // Each denomination has its own basket, flattened into parallel mappings.
    mapping(address => uint256) public legCountOf; // denomination -> that denomination's leg count
    mapping(address => mapping(uint256 => address)) private _legAsset;   // [denomination][legIndex]
    mapping(address => mapping(uint256 => uint16)) private _legBps;      // [denomination][legIndex]
    /// @dev Set only across this contract's own V4 unlock, so {unlockCallback} runs on nothing else.
    bool private transient _v4Swapping;

    mapping(address => uint256) public magnifiedRewardPerShare; // per denomination
    uint256 public eligibleSupply; // shared -- eligibility is about the COIN balance, not the reward currency
    mapping(address => uint256) public totalDistributed; // per denomination
    /// @notice Per-denomination income buffered while eligible supply is below {minEligibleFloor}. PERMANENTLY
    /// UNRECOVERABLE if supply never returns above the floor: there is no owner, drain or rescue.
    mapping(address => uint256) public pending; // per denomination
    mapping(address => uint256) public reserve; // per denomination

    mapping(address => uint256) public trackedBalance;
    mapping(address => mapping(address => int256)) internal magnifiedCorrections; // [account][denomination]
    mapping(address => mapping(address => uint256)) public withdrawnRewards; // [account][denomination]
    mapping(address => bool) public excluded;

    /// @notice Round-robin ring for {process}, shared across every denomination (eligibility is about the coin
    /// balance).
    address[] private _holders;
    mapping(address => uint256) private _holderIdx1;
    uint256 public lastProcessedIndex;
    /// @notice The holder {lastProcessedDenom} refers to; only meaningful while that cursor is non-zero.
    /// @dev Packed in one slot with {_lastProcessedDenom} (declaration order matters). The park branch writes both
    /// at the bottom of the loop reserve, so the second write must be a cheap warm SSTORE.
    address public lastProcessedHolder;
    /// @dev Storage for {lastProcessedDenom}, narrowed to share {lastProcessedHolder}'s slot. The getter keeps the
    /// uint256 ABI.
    uint96 private _lastProcessedDenom;

    /// @notice INTRA-HOLDER cursor: the index into {denominations} at which the next {process} call
    /// resumes for the holder {lastProcessedIndex} is currently parked on. See {_lastProcessedDenom}.
    function lastProcessedDenom() public view returns (uint256) { return _lastProcessedDenom; }

    uint256 private _entered = 1;

    event RewardsDistributed(address indexed denomination, uint256 amount, uint256 perShare);
    event RewardShortfall(address indexed denomination, uint256 reserve, uint256 balance);

    /// @notice {_spend} found `reserve` smaller than `amount` and clamped it to zero. Should be unreachable; if it
    /// fires the ledger is broken and the next sync may double-book, so monitors should alert on it.
    event ReserveUnderrun(address indexed denomination, uint256 reserve, uint256 amount);
    event RewardClaimed(address indexed account, address indexed denomination, address indexed asset, uint256 amount);
    event LegSwapFailed(address indexed account, address indexed denomination, address indexed asset, uint256 amount);
    event LegPaymentFailed(address indexed account, address indexed denomination, uint256 amount);
    /// @notice A holder's payout inside {processHolders} failed (gas cap exhausted or every denomination reverted).
    /// Nothing is lost: the accrual stays claimable.
    event HolderPayoutFailed(address indexed holder);

    error OnlyToken();
    error OnlyFeeder();
    error Reentrancy();
    error NothingToClaim();
    /// @notice The account was owed something but no denomination could be delivered (every transfer reverted and
    /// re-credited). Distinct from {NothingToClaim}, which means nothing was owed.
    error NothingDelivered();
    error ZeroRecipient();
    error BadBasket();
    error NoRouteFound();
    error BadDenominations();
    error BadMinOuts();
    error BadRoutes();
    error OnlySelf();
    error InsufficientGasForLeg();
    error LegMinOutUnmet();
    error RealizedBelowMinOut();
    error NotDuringSwap();
    error NotCreator();
    error MinEligibleBelowFloor();
    error MinEligibleTooHigh();
    event MinEligibleSet(uint256 oldValue, uint256 newValue);
    error AboveAbsoluteMax();
    error TooManyLegs();
    error NotADenomination();

    modifier onlyToken() { if (msg.sender != token) revert OnlyToken(); _; }
    modifier onlyFeeder() { if (msg.sender != feeder) revert OnlyFeeder(); _; }
    modifier nonReentrant() { if (_entered == 2) revert Reentrancy(); _entered = 2; _; _entered = 1; }

    struct DenomBasket { address denomination; Leg[] legs; }

    struct Config {
        address token;
        address feeder;
        address swapRouter;
        /// @dev The real Uniswap V3 factory. Required whenever any leg's asset differs from its denomination.
        address v3Factory;
        address poolManager;
        uint256 minEligible;
        address[] excluded;
        /// @dev One entry per denomination, each with its own basket. The denomination set is derived from this.
        DenomBasket[] denomBaskets;
    }

    constructor(Config memory c) {
        token = c.token;
        feeder = c.feeder;
        swapRouter = c.swapRouter;
        v3Factory = c.v3Factory;
        poolManager = c.poolManager;
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        for (uint256 i; i < c.excluded.length; ++i) excluded[c.excluded[i]] = true;
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true;
        // The router keeps denomination dust mid-swap; it must not accrue rewards against it.
        if (c.swapRouter != address(0)) excluded[c.swapRouter] = true;

        uint256 dn = c.denomBaskets.length;
        if (dn == 0) revert BadDenominations();
        if (dn > ABSOLUTE_MAX_DENOMINATIONS) revert AboveAbsoluteMax();
        uint256 totalLegs;
        for (uint256 di; di < dn; ++di) {
            DenomBasket memory db = c.denomBaskets[di];
            address d = db.denomination;
            if (d == address(0) || isDenomination[d]) revert BadDenominations();
            isDenomination[d] = true;
            denominations.push(d);

            // Same basket validation as the single-denomination tracker, run once per denomination.
            uint256 n = db.legs.length;
            if (n == 0 || n > MAX_LEGS) revert BadBasket();
            totalLegs += n;
            if (totalLegs > MAX_TOTAL_LEGS) revert TooManyLegs();
            uint256 sumBps;
            for (uint256 i; i < n; ++i) {
                Leg memory leg = db.legs[i];
                if (leg.asset == address(0) || leg.bps == 0) revert BadBasket();
                sumBps += leg.bps;
                _legAsset[d][i] = leg.asset;
                _legBps[d][i] = leg.bps;
            }
            if (sumBps != BPS) revert BadBasket();
            legCountOf[d] = n;
        }
    }
    function basketLeg(address denomination, uint256 i) external view returns (address asset, uint16 bps, bytes memory path) {
        asset = _legAsset[denomination][i];
        bps = _legBps[denomination][i];
        // The route a conversion would take right now (empty for a direct leg or when none exists).
        if (asset != denomination) {
            path = RealmAnyPairsRouteLib.encode(
                RealmAnyPairsRouteLib.best(
                    swapRouter == address(0) ? address(0) : v3Factory, poolManager, denomination, false, asset
                ),
                asset
            );
        }
    }

    function denominationCount() external view returns (uint256) { return denominations.length; }

    /// @notice Worst-case gas {setBalance} needs for this tracker's denomination count. {RealmAnyPairsTokenDividend}
    /// reads it once when linked and forwards it on every transfer.
    /// @dev Corrections cannot be made lazily and stay exact, so the O(denominations) cost is paid per balance
    /// change and bounded by {ABSOLUTE_MAX_DENOMINATIONS}.
    function balanceSyncGas() external view returns (uint256) {
        return SYNC_BASE_GAS + SYNC_PER_DENOM_GAS * denominations.length;
    }

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) newBalance = 0;
        _applyBalance(account, newBalance);
    }

    /// @dev The per-transfer cost center: one correction per denomination. See {balanceSyncGas}.
    function _applyBalance(address account, uint256 newBalance) internal {
        uint256 old = trackedBalance[account];
        if (newBalance == old) return;
        uint256 dCount = denominations.length;
        if (newBalance > old) {
            uint256 add = newBalance - old;
            eligibleSupply += add;
            for (uint256 i; i < dCount; ++i) {
                address d = denominations[i];
                magnifiedCorrections[account][d] -= (magnifiedRewardPerShare[d] * add).toInt256();
            }
        } else {
            uint256 sub = old - newBalance;
            eligibleSupply -= sub;
            for (uint256 i; i < dCount; ++i) {
                address d = denominations[i];
                magnifiedCorrections[account][d] += (magnifiedRewardPerShare[d] * sub).toInt256();
            }
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


    function syncBalance(address account) external nonReentrant { _syncBalance(account); }

    function syncBalances(address[] calldata accounts) external nonReentrant {
        for (uint256 i; i < accounts.length; ++i) _syncBalance(accounts[i]);
    }

    function _syncBalance(address account) internal {
        if (excluded[account]) {
            if (trackedBalance[account] != 0) _applyBalance(account, 0);
            return;
        }
        // Low-level so a revert or short return skips the repair instead of bricking {process} or a claim.
        // Uncapped on purpose: `token` is the immutable launcher-deployed coin with a plain `balanceOf`.
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || ret.length < 32) return;
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) _applyBalance(account, real);
    }

    /// @notice Round-robin push of every denomination's raw accrual, one holder per turn; never converts legs.
    /// @dev Each payout is a gas-capped self-call ({pushReward}). A holder whose sweep does not fit is parked and
    /// resumed at {lastProcessedDenom}. The in-swap gate is asked per denomination and memoised per call.
    function process(uint256 gasBudget) external nonReentrant returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) return 0;
        uint256 dCount = denominations.length;
        bool locked = _v4LockHeld();
        // In-swap gate answers, memoised lazily so only denominations the walk reaches pay the staticcall.
        // 0 = not yet asked, 1 = no, 2 = yes.
        uint8[] memory allowedCache = locked ? new uint8[](dCount) : new uint8[](0);
        // Headroom for one turn: the capped push, the cursor SSTOREs, and -- only while the V4 lock is held,
        // where a not-yet-memoised denomination may still cost one 60,000-gas gate staticcall -- that call.
        uint256 turnFloor = PUSH_GAS + 40_000 + (locked ? 65_000 : 0);
        uint256 gasStart = gasleft();
        uint256 idx = lastProcessedIndex;
        // Reads the slot {lastProcessedHolder} shares, warming it before either of the park branch's
        // writes -- see {lastProcessedHolder}. Unconditional, so the warming is guaranteed.
        uint256 resumeDenom = _lastProcessedDenom;
        uint256 newDenomCursor = resumeDenom;
        uint256 iterations;
        while (iterations < n) {
            if (gasleft() < turnFloor) break;
            uint256 len = _holders.length; // re-read: a payout can shrink the set via {_removeHolder}
            if (len == 0) break;
            uint256 nextIdx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[nextIdx];
            // Resume mid-sweep only for the holder we actually parked on: swap-and-pop can move a different
            // holder into this index between calls.
            uint256 di = (resumeDenom != 0 && resumeDenom < dCount && h == lastProcessedHolder) ? resumeDenom : 0;
            resumeDenom = 0; // only the holder we were parked on resumes mid-sweep
            uint256 startDi = di;
            bool finishedHolder = true;
            for (; di < dCount; ++di) {
                if (gasleft() < turnFloor) { finishedHolder = false; break; }
                // Check the budget before each denomination, not after the last, so a finished holder is not parked.
                // `di != startDi` guarantees at least one denomination of progress per visit.
                if (di != startDi && gasStart - gasleft() > gasBudget) { finishedHolder = false; break; }
                if (locked) {
                    uint8 a = allowedCache[di];
                    if (a == 0) { a = _inSwapAllowed(denominations[di]) ? 2 : 1; allowedCache[di] = a; }
                    if (a == 1) continue; // per-denomination: each denomination is denied independently
                }
                address d = denominations[di];
                uint256 amt = claimableOf(h, d);
                if (amt != 0) {
                    // The debit lives inside the capped {pushReward} frame, so a failed payout unwinds itself and
                    // `turnFloor` only has to cover the cursor writes.
                    try this.pushReward{gas: PUSH_GAS}(h, d, amt) { unchecked { ++pushed; } }
                    catch {
                        // No rollback: the debit is inside the reverted frame and is already undone.
                        emit LegPaymentFailed(h, d, amt);
                    }
                }
            }
            if (!finishedHolder) {
                // Park ON this holder (idx deliberately NOT advanced) and remember where in their sweep we
                // stopped, so the next call finishes them instead of starting them over.
                newDenomCursor = di < dCount ? di : 0;
                if (newDenomCursor != 0 && lastProcessedHolder != h) lastProcessedHolder = h;
                break;
            }
            idx = nextIdx;
            newDenomCursor = 0;
            unchecked { ++iterations; }
            if (gasStart - gasleft() > gasBudget) break;
        }
        lastProcessedIndex = idx;
        // Second write to the packed slot on the park branch, hence ~100 gas rather than a second
        // SSTORE_SET. uint96 cannot truncate: `newDenomCursor < dCount <= ABSOLUTE_MAX_DENOMINATIONS`.
        if (newDenomCursor != _lastProcessedDenom) _lastProcessedDenom = uint96(newDenomCursor);
    }

    /// @dev Self-only, gas-capped payout for {process}. The ledger debit and `_spend` sit in this frame so a failed
    /// payout unwinds them.
    function pushReward(address account, address denomination, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        withdrawnRewards[account][denomination] += amount; // CEI: debited before the transfer, same frame
        _spend(denomination, amount); // same frame as the transfer: a revert rolls it back
        // The debit stays nominal; only the event reports the measured inflow (saturating, clamped to `amount`).
        uint256 before = IERC20(denomination).balanceOf(account);
        IERC20(denomination).safeTransfer(account, amount);
        uint256 aft = IERC20(denomination).balanceOf(account);
        uint256 delivered = aft > before ? aft - before : 0;
        if (delivered > amount) delivered = amount;
        emit RewardClaimed(account, denomination, denomination, delivered);
    }

    /// @dev The hook's live answer for `denomination` (default true unless denied). Any failed or malformed call
    /// reads as not allowed.
    function _inSwapAllowed(address denomination) internal view returns (bool) {
        (bool ok, bytes memory d) =
            feeder.staticcall{gas: 60_000}(abi.encodeWithSignature("inSwapAllowed(address)", denomination));
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    /// @notice Permissionless, out-of-swap payout of a caller-supplied list of holders, in raw denomination tokens.
    /// @dev Never converts a leg on anyone's behalf, so there is no execution price to manipulate. Holders who want
    /// basket assets claim themselves.
    function processHolders(address[] calldata holders, uint256 gasBudget)
        external
        nonReentrant
        returns (uint256 processed)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        uint256 cap = PROCESS_HOLDER_BASE_GAS + PROCESS_HOLDER_PER_DENOM_GAS * denominations.length;
        uint256 gasStart = gasleft();
        for (uint256 i; i < holders.length; ++i) {
            if (gasStart - gasleft() > gasBudget) break;
            try this._processHolder{gas: cap}(holders[i]) {
                unchecked { ++processed; }
            } catch {
                emit HolderPayoutFailed(holders[i]);
            }
        }
    }

    /// @dev Self-only. Pays `holder` themselves in every owed denomination via {_payDirect}, so one blocked
    /// denomination re-credits itself and the others still pay. Reverts if nothing was paid.
    function _processHolder(address holder) external {
        if (msg.sender != address(this)) revert OnlySelf();
        // Repair a starved-gas desync before paying, so a phantom balance cannot be paid.
        _syncBalance(holder);
        uint256 dCount = denominations.length;
        uint256 paid;
        for (uint256 di; di < dCount; ++di) {
            address d = denominations[di];
            uint256 amt = claimableOf(holder, d);
            if (amt == 0) continue;
            uint256 wBefore = withdrawnRewards[holder][d];
            withdrawnRewards[holder][d] += amt; // CEI; rolled back by {_payDirect} if the transfer reverts
            _payDirect(holder, holder, d, amt);
            // {_payDirect} re-credits on a reverted transfer, so this is how a denomination that actually
            // paid is told apart from one that was merely attempted -- the paid counter must count the former.
            if (withdrawnRewards[holder][d] != wBefore) { unchecked { ++paid; } }
        }
        if (paid == 0) revert NothingToClaim();
    }

    function pokePending() external nonReentrant {
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            // Gated on {minEligibleFloor}, not the creator-settable {minEligible} -- see {_receive}.
            if (pending[d] != 0 && eligibleSupply >= minEligibleFloor) { uint256 p = pending[d]; pending[d] = 0; _book(d, p); }
        }
    }

    // ─────────────────────────── feeding (hook-driven) ───────────────────────────

    /// @notice Called by the hook after it transfers a rewards slice for some pool of this coin. The argument is
    /// ignored; the call does not say which denomination arrived, so every denomination's balance is synced.
    function feedToken(uint256) external onlyFeeder nonReentrant { _syncAll(); }

    function sync() external nonReentrant { _syncAll(); }

    function _syncAll() internal {
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) _syncOne(denominations[i]);
    }

    function _syncOne(address d) internal {
        uint256 bal = IERC20(d).balanceOf(address(this));
        uint256 r = reserve[d];
        if (bal <= r) {
            // Never write `reserve[d]` down: a shortfall holds the baseline so later income repairs it first.
            if (bal < r) emit RewardShortfall(d, r, bal);
            return;
        }
        uint256 delta = bal - r;
        reserve[d] = bal;
        _receive(d, delta);
    }

    function _spend(address d, uint256 amount) internal {
        uint256 r = reserve[d];
        if (r >= amount) {
            reserve[d] = r - amount;
            return;
        }
        emit ReserveUnderrun(d, r, amount);
        reserve[d] = 0;
    }

    function _receive(address d, uint256 amount) internal {
        if (amount == 0) return;
        // Gated on the immutable floor, never the creator-settable {minEligible}, so the creator cannot divert
        // income into `pending`.
        if (eligibleSupply < minEligibleFloor) { pending[d] += amount; return; }
        if (pending[d] != 0) { uint256 p = pending[d]; pending[d] = 0; _book(d, p); }
        _book(d, amount);
    }

    function _book(address d, uint256 amount) internal {
        magnifiedRewardPerShare[d] += (amount * MAGNITUDE) / eligibleSupply;
        totalDistributed[d] += amount;
        emit RewardsDistributed(d, amount, magnifiedRewardPerShare[d]);
    }

    // ─────────────────────────── views ───────────────────────────

    /// @dev The `acc <= 0` clamp is unreachable (accrual is monotonic). It deliberately does not fail safe: a broken
    /// ledger makes {claimableOf} revert and halts payouts rather than draining quietly.
    function accumulativeOf(address account, address denomination) public view returns (uint256) {
        int256 acc = (magnifiedRewardPerShare[denomination] * trackedBalance[account]).toInt256()
            + magnifiedCorrections[account][denomination];
        return acc <= 0 ? 0 : uint256(acc) / MAGNITUDE;
    }

    function claimableOf(address account, address denomination) public view returns (uint256) {
        return accumulativeOf(account, denomination) - withdrawnRewards[account][denomination];
    }

    function claimableAll(address account) external view returns (address[] memory denoms, uint256[] memory amounts) {
        uint256 dCount = denominations.length;
        denoms = new address[](dCount);
        amounts = new uint256[](dCount);
        for (uint256 i; i < dCount; ++i) {
            denoms[i] = denominations[i];
            amounts[i] = claimableOf(account, denominations[i]);
        }
    }

    // ─────────────────────────── claim (each denomination converted independently) ───────────────────────────

    /// @dev Named for what it waives: every leg of every denomination runs with no price floor. There is
    /// deliberately no `claim()`. Prefer {claimWithMinOuts} or {claimDenominations}.
    function claimAtAnyPrice() external returns (uint256 totalDenomsPaid) {
        return claimToWithMinOuts(msg.sender, _zeroMinOutsForAllDenoms());
    }

    /// @dev {claimAtAnyPrice}, paid to `to`.
    function claimToAtAnyPrice(address to) external returns (uint256 totalDenomsPaid) {
        return claimToWithMinOuts(to, _zeroMinOutsForAllDenoms());
    }

    function claimWithMinOuts(uint256[][] memory minOutsPerDenom) external returns (uint256 totalDenomsPaid) {
        return claimToWithMinOuts(msg.sender, minOutsPerDenom);
    }

    function _zeroMinOutsForAllDenoms() internal view returns (uint256[][] memory minOutsPerDenom) {
        uint256 dCount = denominations.length;
        minOutsPerDenom = new uint256[][](dCount);
        for (uint256 i; i < dCount; ++i) minOutsPerDenom[i] = new uint256[](legCountOf[denominations[i]]);
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }
    function claimToWithMinOuts(address to, uint256[][] memory minOutsPerDenom) public nonReentrant returns (uint256 totalDenomsPaid) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        return _claim(msg.sender, to, minOutsPerDenom, _emptyRoutes());
    }
    /// @notice Claim with a caller-supplied route per leg. An empty route is discovered on-chain; otherwise it is a
    /// 43-byte V3 path or an ABI-encoded V4 `PoolKey` (the only way to reach a hooked V4 pool).
    /// `routesPerDenom` is indexed like `minOutsPerDenom`: by denomination, then by leg.
    /// @dev Every supplied route is validated before anything is paid and may not route through {feeder}.
    function claimWithRoutes(uint256[][] memory minOutsPerDenom, bytes[][] memory routesPerDenom)
        external
        returns (uint256 totalDenomsPaid)
    {
        return claimToWithRoutes(msg.sender, minOutsPerDenom, routesPerDenom);
    }

    /// @notice {claimWithRoutes}, paid to `to`.
    function claimToWithRoutes(address to, uint256[][] memory minOutsPerDenom, bytes[][] memory routesPerDenom)
        public
        nonReentrant
        returns (uint256 totalDenomsPaid)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        _requireRoutes(routesPerDenom);
        return _claim(msg.sender, to, minOutsPerDenom, routesPerDenom);
    }

    /// @dev Validates every supplied route up front, so a bad one fails the claim loudly.
    function _requireRoutes(bytes[][] memory routesPerDenom) internal view {
        uint256 dCount = denominations.length;
        if (routesPerDenom.length != dCount) revert BadRoutes();
        for (uint256 di; di < dCount; ++di) {
            address d = denominations[di];
            bytes[] memory routes = routesPerDenom[di];
            if (routes.length != legCountOf[d]) revert BadRoutes();
            for (uint256 i; i < routes.length; ++i) {
                address asset = _legAsset[d][i];
                if (routes[i].length == 0 || asset == d) continue;
                RealmAnyPairsRouteLib.supplied(routes[i], swapRouter == address(0) ? address(0) : v3Factory, poolManager, d, false, asset, feeder);
            }
        }
    }

    /// @dev An all-empty route set -- every leg discovered -- shaped to the current denominations.
    function _emptyRoutes() internal view returns (bytes[][] memory routes) {
        uint256 dCount = denominations.length;
        routes = new bytes[][](dCount);
        for (uint256 di; di < dCount; ++di) routes[di] = new bytes[](legCountOf[denominations[di]]);
    }

    /// @notice Partial claim: pay out only the named denominations, for when a whole-basket claim is too large for
    /// one transaction.
    /// @param denoms denominations to claim, in any order; each must be one of this tracker's own.
    /// @param minOuts per-leg floors for each entry of `denoms`, in the same order.
    function claimDenominations(address to, address[] calldata denoms, uint256[][] calldata minOuts)
        external
        nonReentrant
        returns (uint256 totalDenomsPaid)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        if (denoms.length == 0 || denoms.length != minOuts.length) revert BadMinOuts();
        _syncBalance(msg.sender);
        uint256 owedCount;
        for (uint256 i; i < denoms.length; ++i) {
            address d = denoms[i];
            if (!isDenomination[d]) revert NotADenomination();
            (bool owed, bool delivered) = _payDenomination(msg.sender, to, d, minOuts[i], new bytes[](legCountOf[d]));
            if (owed) { unchecked { ++owedCount; } }
            if (delivered) { unchecked { ++totalDenomsPaid; } }
        }
        // Nothing owed and owed-but-undeliverable are different failures; see {NothingDelivered}.
        if (owedCount == 0) revert NothingToClaim();
        if (totalDenomsPaid == 0) revert NothingDelivered();
    }

    /// @dev Rejects recipients where a reward would be burned, stranded or re-booked (this tracker re-books on
    /// {sync}). Guards against UI mistakes; it does not cover every excluded address.
    function _checkRecipient(address to) internal view {
        if (
            to == address(0) || to == address(this) || to == token || isDenomination[to]
                || to == swapRouter || to == feeder || to == poolManager
        ) revert ZeroRecipient();
    }

    /// @dev Runs the basket claim body for every denomination with a non-zero accrual. Reverts {NothingToClaim} if
    /// nothing was owed and {NothingDelivered} if nothing could be paid.
    function _claim(address account, address to, uint256[][] memory minOutsPerDenom, bytes[][] memory routesPerDenom)
        internal
        returns (uint256 totalDenomsPaid)
    {
        uint256 dCount = denominations.length;
        if (minOutsPerDenom.length != dCount) revert BadMinOuts();
        if (routesPerDenom.length != dCount) revert BadRoutes();
        _syncBalance(account);
        uint256 owedCount;
        for (uint256 di; di < dCount; ++di) {
            (bool owed, bool delivered) =
                _payDenomination(account, to, denominations[di], minOutsPerDenom[di], routesPerDenom[di]);
            if (owed) { unchecked { ++owedCount; } }
            if (delivered) { unchecked { ++totalDenomsPaid; } }
        }
        if (owedCount == 0) revert NothingToClaim();
        if (totalDenomsPaid == 0) revert NothingDelivered();
    }

    /// @dev One denomination's whole basket. `owed` is whether the ledger had a balance; `delivered` is whether
    /// any of it actually left the contract.
    function _payDenomination(address account, address to, address d, uint256[] memory minOuts, bytes[] memory routes)
        internal
        returns (bool owed, bool delivered)
    {
        uint256 totalAmount = claimableOf(account, d);
        if (totalAmount == 0) return (false, false);
        owed = true;
        uint256 legCount = legCountOf[d];
        if (minOuts.length != legCount) revert BadMinOuts();
        if (routes.length != legCount) revert BadRoutes();
        uint256 wBefore = withdrawnRewards[account][d];
        withdrawnRewards[account][d] += totalAmount; // CEI, per denomination
        uint256 distributed;
        for (uint256 i; i < legCount; ++i) {
            address asset = _legAsset[d][i];
            uint256 legAmt = i + 1 == legCount ? totalAmount - distributed : (totalAmount * _legBps[d][i]) / BPS;
            distributed += legAmt;
            if (legAmt == 0) continue;
            _payLeg(account, to, d, asset, legAmt, minOuts[i], routes[i]);
        }
        delivered = withdrawnRewards[account][d] != wBefore;
    }

    /// @dev Basket {_payLeg} with `denomination` in place of `quote`. A non-zero floor on a failed leg reverts the
    /// whole claim; only a zero floor falls back to the raw denomination.
    function _payLeg(
        address account,
        address to,
        address denomination,
        address asset,
        uint256 quoteAmt,
        uint256 minOut,
        bytes memory route
    ) internal {
        if (asset == denomination) {
            _payDirect(account, to, denomination, quoteAmt);
            return;
        }
        if (gasleft() < LEG_GAS_CAP * 64 / 63 + 30_000) revert InsufficientGasForLeg();

        try this._executeSwap{gas: LEG_GAS_CAP}(to, denomination, asset, quoteAmt, minOut, route) returns (uint256 out) {
            emit RewardClaimed(account, denomination, asset, out);
        } catch {
            // The raw fallback is opt-in: a caller who set a floor gets the claim unwound and can retry.
            if (minOut != 0) revert LegMinOutUnmet();
            emit LegSwapFailed(account, denomination, asset, quoteAmt);
            _payDirect(account, to, denomination, quoteAmt);
        }
    }

    /// @dev Basket {_executeSwap} with `denomination` in place of `quote`.
    function _executeSwap(
        address account,
        address denomination,
        address asset,
        uint256 quoteAmt,
        uint256 minOut,
        bytes memory route
    ) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();
        // Caller's route if supplied, otherwise discovered now, inside the gas-capped frame.
        RealmAnyPairsRouteLib.Route memory r = route.length == 0
            ? RealmAnyPairsRouteLib.best(swapRouter == address(0) ? address(0) : v3Factory, poolManager, denomination, false, asset)
            : RealmAnyPairsRouteLib.supplied(route, swapRouter == address(0) ? address(0) : v3Factory, poolManager, denomination, false, asset, feeder);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_NONE) revert NoRouteFound();
        uint256 before = IERC20(asset).balanceOf(account);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            IERC20(denomination).forceApprove(swapRouter, quoteAmt);
            ISwapRouter02(swapRouter).exactInput(
                ISwapRouter02.ExactInputParams({
                    path: RealmAnyPairsRouteLib.v3Path(r, asset), recipient: account, amountIn: quoteAmt, amountOutMinimum: minOut
                })
            );
            IERC20(denomination).forceApprove(swapRouter, 0);
        } else {
            _v4Swapping = true;
            IPoolManager(poolManager).unlock(
                abi.encode(account, denomination, asset, r.fee, r.tickSpacing, r.hooks, quoteAmt, minOut)
            );
            _v4Swapping = false;
        }
        uint256 aft = IERC20(asset).balanceOf(account);
        out = aft > before ? aft - before : 0;
        if (out < minOut) revert RealizedBelowMinOut();
        _spend(denomination, quoteAmt);
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

    /// @dev Pays the raw denomination. The debit stays nominal on success; a reverted transfer is re-credited.
    function _payDirect(address account, address to, address denomination, uint256 amt) internal {
        try this._transferDirect(to, denomination, amt) returns (uint256 delivered) {
            emit RewardClaimed(account, denomination, denomination, delivered);
        } catch {
            withdrawnRewards[account][denomination] -= amt;
            emit LegPaymentFailed(account, denomination, amt);
        }
    }

    /// @dev Self-only so {_payDirect} can try/catch a SafeERC20 transfer.
    /// @return delivered The recipient's measured inflow (saturating), clamped to `amt`. Used only for the event.
    function _transferDirect(address to, address denomination, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) revert OnlySelf();
        _spend(denomination, amt);
        uint256 before = IERC20(denomination).balanceOf(to);
        IERC20(denomination).safeTransfer(to, amt);
        uint256 aft = IERC20(denomination).balanceOf(to);
        delivered = aft > before ? aft - before : 0;
        if (delivered > amt) delivered = amt;
    }
}
