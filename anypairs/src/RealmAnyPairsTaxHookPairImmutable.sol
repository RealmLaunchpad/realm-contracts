// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// v4-core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RealmAnyPairsLiquidityMath} from "./RealmAnyPairsLiquidityMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {RealmAnyPairsSplitLib} from "./RealmAnyPairsSplitLib.sol";
import {RealmAnyPairsFeeMath} from "./RealmAnyPairsFeeMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RealmAnyPairsTokenPlain} from "./RealmAnyPairsTokenPlain.sol";
import {RealmAnyPairsImmutableBase} from "./base/RealmAnyPairsImmutableBase.sol";

/// @notice Quote-token dividend tracker sink: the hook transfers the slice, then calls `feedToken` so the
/// tracker books the deposit for holders.
interface IDividendFeederToken {
    function feedToken(uint256 amount) external;
}

/// @notice Native-quote tracker funding entry point ({RealmAnyPairsDividendTracker.feed}). Value travels with
/// the call because ETH has no separate "transfer then notify" step.
interface IDividendFeeder {
    function feed() external payable;
}

/**
 * @title RealmAnyPairsTaxHookPairImmutable
 * @notice Non-upgradeable Uniswap V4 tax hook for {coin, quote} pools (ERC20 or native quote). Skims a
 *         per-side tax in the quote and splits it between the platform, holder rewards, buyback,
 *         auto-liquidity and the creator split, paying out in-swap where gas allows with a pull ledger fallback.
 * @dev No proxy and no upgrade path; `owner`/`admin`/`platform` are ordinary mutable configuration.
 *      Deployed via CREATE2 so its own address carries the V4 permission flags.
 */
contract RealmAnyPairsTaxHookPairImmutable is IUnlockCallback, RealmAnyPairsImmutableBase {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ─── caps (basis points; 1% = 100 bps) ───
    uint16 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 2 ** 96;
    /// @notice Most of a pool's quote-side depth a CREATOR may raise its auto-distribute threshold to: 1%.
    /// @dev AUDIT ROUND 9. See {setAutoThreshold}. Sized so a creator can still tune the threshold for gas across a wide
    /// range of pool sizes -- 1% of depth is far above any sane threshold on a real pool (the platform default is 0.01
    /// whole quote units) -- while making "park the rewards forever" unreachable: at 1% the pot is pushed by the time a
    /// single 1%-of-the-pool trade's fees have accrued.
    uint256 internal constant MAX_CREATOR_AUTO_THRESHOLD_BPS = 100;
    /// @notice Hard ceiling on any per-side tax rate (5%), for creator, admin and owner alike ({_requireRatesOk}).
    /// {setMaxSideBps} cannot exceed it. Not the partial-fill ceiling: see {FILL_TOLERANCE_BPS}.
    uint16 public constant MAX_SIDE_BPS_LIMIT = 500; // 5% per side, absolute
    /// @notice Partial-fill sanity ceiling for {afterSwap}'s {FillTooSmallForTax} check. Not a rate. Kept separate
    /// from {MAX_SIDE_BPS_LIMIT} because lowering it raises the minimum acceptable fill.
    uint16 public constant FILL_TOLERANCE_BPS = 2000;

    // ── optional launch guards ──────────────────────────────────────────────────────────────────────
    /// @dev Ceiling on the opening launch tax. Above {MAX_SIDE_BPS_LIMIT} on purpose; it decays to the normal rate.
    uint16 public constant MAX_LAUNCH_TAX_BPS = 3000;      // 30%
    /// @dev Maximum launch-tax window, in seconds. Seconds rather than blocks because `block.number` on this chain
    /// is the L1 block number and advances only every ~12 seconds.
    uint16 public constant MAX_LAUNCH_TAX_SECS = 3600;   // 1 hour
    /// @dev Floor on a max-buy cap. Without it, `maxBuyBps = 1` is a honeypot wearing a limit's clothes.
    uint16 public constant MIN_MAX_BUY_BPS = 10;           // 0.1% of supply
    /// @dev Ceiling on the anti-snipe delay, for the same reason.
    uint8 public constant MAX_TRADING_DELAY = 60;          // seconds
    /// @dev How long an advertised max buy cannot be loosened, measured from when trading opens (not from
    /// launch), so a trading delay cannot be used to wait out the lock.
    uint40 public constant MAX_BUY_LOCK_SECS = 300;   // 5 minutes of real trading under the advertised number

    /// @notice Owner-tunable per-side tax ceiling enforced when rates are set. Can only be tightened; never
    /// exceeds {MAX_SIDE_BPS_LIMIT}.
    uint16 public maxSideBps = 500;

    /// @notice Platform fee bounds. The platform fee is carved out of what the trader pays, not added on top:
    ///     total    = max(effectiveRate, floor)
    ///     platform = min(total, max(floor, min(cap, total * share / BPS)))
    ///     creator  = total - platform
    /// A 0% coin still pays the floor, all to the platform. Rates are snapshotted per pool at launch
    /// ({setPlatformRates}, {configurePool}); later changes never reprice live coins.
    uint16 public constant MIN_PLATFORM_SHARE_BPS = 1000; // 10% of what the trader pays
    uint16 public constant MAX_PLATFORM_SHARE_BPS = 3000; // 30% of what the trader pays
    uint16 public constant MAX_PLATFORM_FLOOR_BPS = 100;  // 1.00% of the trade
    uint16 public constant MAX_PLATFORM_CAP_BPS = 300;    // 3.00% of the trade
    /// @notice Headroom {_fillCeilBps} adds over a rate for the platform fee inside it.
    uint16 internal constant FILL_PLATFORM_HEADROOM_BPS = 100;
    /// @notice The rates NEW launches snapshot. See {setPlatformRates}.
    uint16 public platformShareBps = 2000;
    uint16 public platformFloorBps = 20;
    uint16 public platformCapBps = 100;

    /// @notice The platform's portion of {accruedQuote}, split off at skim time while the side is still
    /// known. `accruedQuote` remains the TOTAL.
    mapping(PoolId => uint256) public accruedPlatformQuote;
    /// @dev Aliased to the library constant, which is what actually bounds the split loop.
    uint256 public constant MAX_SPLIT_RECIPIENTS = RealmAnyPairsSplitLib.MAX_SPLIT_RECIPIENTS;
    /// @notice Every Realm pool is a ZERO-FEE Uniswap pool. The trader pays the coin's tax and no LP fee on top.
    /// @dev AUDIT ROUND 12, PRODUCT DECISION: 3000 (0.30%) -> 0. The 0.30% existed to feed the LP locker's
    /// `compound()`, which reinvested accrued trading fees into the locked position. That function was the round-12
    /// Critical -- a permissionless call that sized an add against live spot with a large pot, on a price anchor that
    /// could be founded at any tick by its first caller and then walked a full drift per block. Setting the fee to
    /// zero removes the fee stream, which removes the pot, which removes the reason for the function; the locker's
    /// compounding is deleted outright rather than patched a third time.
    ///
    /// ACCEPTED CONSEQUENCES, stated plainly and repeated in the integration checklist:
    ///   * locked liquidity no longer grows from trading fees -- only from the tax's LP slice (the hook's in-swap
    ///     auto-liquidity step, which is untouched);
    ///   * no third-party market maker has a fee incentive to add depth to a Realm pool, so depth is whatever the
    ///     launch seeded plus whatever the LP slice adds;
    ///   * moving the price of a Realm pool is CHEAPER, because there is no fee toll on the round trip. Every
    ///     sandwich and price-impact risk this document already accepts is correspondingly cheaper for an attacker.
    ///
    /// Enforced on every pool by {_shape}: `key.fee != POOL_FEE` reverts `BadPoolFee()`, exactly as before.
    uint24 public constant POOL_FEE = 0;
    uint24 internal constant FEE_DENOM = 1e6;

    // ── auto-send ───────────────────────────────────────────────────────────────────────────────
    /// @dev Fixed part of a distribution's gas reservation (settle, take, 6909 burn, re-measurement, split math).
    /// Per-payee booking is {AUTO_DISTRIBUTE_PER_SPLIT}; pushes are gated by the PAY_FLOOR_* floors. Under-reserving
    /// is benign: the attempt fails inside the try, the accrual is restored and a later swap retries.
    uint256 internal constant AUTO_DISTRIBUTE_BASE = 200_000;
    /// @dev Liveness bound on the gas one ERC20 push may use. Not a safety boundary (that is {inSwapRegistry});
    /// it keeps a pathological transfer from leaving the catch too little gas for its fallback SSTORE.
    uint256 internal constant SPLIT_PUSH_LIVENESS_CAP = 250_000;
    /// @dev Gas reserved per ring slot a distribution will book in {_bookSlot} (cold SSTORE plus mask bit).
    uint256 internal constant AUTO_DISTRIBUTE_PER_SPLIT = 28_000;

    // ── the payout ring ────────────────────────────────────────────────────────────────────────────
    /// @dev Ring slot layout: platform (0), creator split recipients (1..20; a split-less creator uses 1),
    /// rewards tracker (21).
    /// @dev AUDIT ROUND 12: the referrer's slot (22) is gone with the referral feature. It was the LAST slot, so
    /// every index below is unchanged and only {PAY_SLOTS} moves, 23 -> 22.
    uint256 internal constant PAY_SLOT_PLATFORM = 0;
    uint256 internal constant PAY_SLOT_SPLIT_BASE = 1;
    /// @dev Derived from {MAX_SPLIT_RECIPIENTS} so a split recipient and the rewards tracker can never share a slot.
    uint256 internal constant PAY_SLOT_REWARDS = PAY_SLOT_SPLIT_BASE + MAX_SPLIT_RECIPIENTS;
    /// @dev Must stay a literal (solc rejects a library-qualified constant as an array length). Keep in step:
    ///     PAY_SLOTS == PAY_SLOT_REWARDS + 1 == PAY_SLOT_SPLIT_BASE + MAX_SPLIT_RECIPIENTS + 1 == 22.
    uint256 internal constant PAY_SLOTS = 22;

    // ──────────────────── decoupled platform / creator claims ────────────────────

    /// @dev {unlockCallback} payload ops (first word; explicit rather than inferred from payload length) and
    /// distribution modes. FLUSH_PLATFORM / FLUSH_CREATOR settle the platform cut or the creator side alone.
    uint8 internal constant UNLOCK_DISTRIBUTE = 0;
    uint8 internal constant UNLOCK_BUYBACK = 1;
    uint8 internal constant UNLOCK_ADDLIQ = 2;
    uint8 internal constant UNLOCK_REFLECT = 3;

    uint8 internal constant FLUSH_ALL = 0;
    uint8 internal constant FLUSH_PLATFORM = 1;
    uint8 internal constant FLUSH_CREATOR = 2;

    /// @dev Ring slot masks for {_runQueueMasked} walks.
    uint32 internal constant RING_ALL = type(uint32).max;
    /// Platform side: {PAY_SLOT_PLATFORM} alone, since audit round 12 removed the referral slot.
    uint32 internal constant RING_PLATFORM = uint32(1) << uint32(PAY_SLOT_PLATFORM);
    uint32 internal constant RING_CREATOR = ~RING_PLATFORM;

    /// @notice Maximum pools per {claimPlatformMany} call, sized so `MAX_CLAIM_BATCH * CLAIM_ONE_GAS_CAP` fits a block.
    uint256 public constant MAX_CLAIM_BATCH = 64;

    /// @dev Gas forwarded to each pool in a {claimPlatformMany} batch, so one hostile quote cannot starve the rest.
    uint256 internal constant CLAIM_ONE_GAS_CAP = 1_200_000;
    /// @dev Left in this frame after the last forwarded call so the loop can finish its own bookkeeping.
    uint256 internal constant CLAIM_BATCH_TAIL = 60_000;

    /// @dev One ring entry, packed into one slot. `to` is snapshotted at booking and never re-derived at push
    /// time, so a later split or creator change cannot redirect money already earned.
    struct PaySlot { address to; uint96 amt; }
    mapping(PoolId => PaySlot[PAY_SLOTS]) internal _paySlots;

    /// @notice Bit `i` set when ring slot `i` of this pool is funded; lets a swap skip the walk with one SLOAD.
    mapping(PoolId => uint32) public pendingMask;
    /// @notice Where the next ring walk resumes. Rotates to avoid starvation; parks on the first unaffordable slot.
    mapping(PoolId => uint8) public payCursor;
    /// @dev Cold-worst-case cost of the before/after `balanceOf` pair that {pushRewards} and {pushSplit} use to
    /// measure delivery: cold account + cold slot on the first read (~4,400), warm on the second, plus slack.
    uint256 internal constant MEASURE_GAS_RESERVE = 10_000;
    // Gas forwarded to an ERC20 rewards push ({pushRewards}: self-call, BALANCE MEASUREMENT, transfer, `feedToken`).
    // Kept below {PAY_FLOOR_FEED_TOKEN} so the catch always has gas for its `owed` fallback; an over-run only delays
    // booking, never loses funds. Tracker `feedToken` cost grows with a multi-basket's denomination count, so
    // re-check this cap against a realistic quote before raising a tracker's denomination limit.
    /// @dev AUDIT ROUND 17 (F-2): raised 320,000 -> 330,000 when the delivery measurement moved INSIDE this forwarded
    /// frame (see {pushRewards}). The two `balanceOf` reads previously ran in the outer frame and cost the tracker
    /// nothing; {MEASURE_GAS_RESERVE} is exactly what they take back, so `feedToken`'s effective budget is unchanged
    /// by that move. Do not lower this without lowering the reserve with it.
    uint256 internal constant FEED_GAS_CAP_TOKEN = 320_000 + MEASURE_GAS_RESERVE;
    /// @dev The NATIVE cap, restored to the deleted ETH hook's figure.
    uint256 internal constant FEED_GAS_CAP_NATIVE = 200_000;
    // Per-visit floors of the payout ring. Each gates one ring visit and is checked just before its push; a
    // visit the budget cannot afford is deferred (the slice stays booked), not cancelled. Keyed on the quote
    // because native pushes are far cheaper than ERC20 ones. The FEED floors must be >= FEED_GAS_CAP_* * 64/63
    // so the full cap is always forwarded.
    /// @dev Round 17 (F-2): tracks {FEED_GAS_CAP_TOKEN} up by {MEASURE_GAS_RESERVE}, so the margin left to the
    /// catch's `owed` fallback after the full cap is forwarded is exactly what it was (380,000 - 320,000*64/63).
    uint256 internal constant PAY_FLOOR_FEED_TOKEN = 380_000 + MEASURE_GAS_RESERVE;
    uint256 internal constant PAY_FLOOR_FEED_NATIVE = 260_000;
    /// @dev Push floors. TOKEN = {SPLIT_PUSH_LIVENESS_CAP} plus margin for the registry staticcall and the catch's
    /// cold `owed` SSTORE.
    uint256 internal constant PAY_FLOOR_PUSH_TOKEN = SPLIT_PUSH_LIVENESS_CAP + 75_000;
    /// @dev Native push floor. Also covers the walk's close (mask and cursor stores, {PayoutsProcessed}), which runs
    /// after the last admitted push and is not covered by any per-visit floor.
    uint256 internal constant PAY_FLOOR_PUSH_NATIVE = 85_000;

    /// @dev Gas withheld from in-swap payout work so the swap itself can always finish (return through the
    /// PoolManager and let the router settle), even if the payout attempt runs out of gas. Applied as an explicit
    /// gas cap on the payout call, and also counted in the precheck.
    uint256 internal constant SWAP_TAIL_RESERVE = 300_000;
    /// @dev Added to a dividend coin's own `minDebit` when that exceeds {SWAP_TAIL_RESERVE}: the rest of the swap and the
    /// router's settlement around the coin transfer.
    uint256 internal constant SWAP_TAIL_MARGIN = 60_000;
    /// @dev Fixed gas of one LATER Realm hop in the same unlock whose in-swap work is skipped for lack of gas: the
    /// PoolManager swap, before/afterSwap, tax accrual (cold zero-to-nonzero writes), the coin-tail read and every skip
    /// event. Measured worst case 140,420 (heavy AutoBasket coin, guards, 3-way split, booked pots, pending ring,
    /// auto-convert, cold sell); a plain idle hop is ~125k. Excludes initialized-tick crossings of a large trade.
    /// AUDIT ROUND 9: raised 150,000 -> 210,000, and re-derived against COLD measurements. Two things were wrong
    /// with 150,000. (a) It was calibrated on a warm hop: an independent sweep measured a worst-case idle Realm hop at
    /// 185,501 COLD (159,645 warm), so the two covered hops needed 306,457 against 300,000 reserved -- 6,457 short, and
    /// that shortfall is the mechanism behind the accepted 4+ hooked-hop bands. (b) The round-9 max-wallet accumulator
    /// ({_requireUnderMaxWallet}) is MANDATORY -- skipping it for lack of gas would make it bypassable with a tight gas
    /// limit -- so an otherwise idle hop through a coin whose launch window is live now also pays a cold SSTORE
    /// (~22,100). 185,501 + 22,100 = 207,601, rounded up to 210,000. At 150,000 a 3-hop route through three
    /// simultaneously-launching coins opened a real band (measured: the coin transfer reverting
    /// InsufficientGasForBalanceSync from 1,835,000 up); at 210,000 the same sweeps are clean.
    /// COST: {SWAP_HOPS_COVERED} x 60,000 = 120,000 more RESERVE than round 8. Reserve only -- a trader never has to
    /// supply it; without it the in-swap work simply skips to a later trade.
    uint256 internal constant SWAP_HOP_GAS = 210_000;
    /// @dev Later Realm hops the in-swap reserve pays for ({_tail}) on top of the heaviest coin's transfer tail. With the
    /// margin and call-frame slack absorbing one more, gas sweeps show no band with up to 3 hooked hops between a working
    /// pool and the heaviest coin's pool (3 would reserve 450k). More hooked hops can still hit a band. Traders never
    /// need this reserve: without it in-swap work just skips.
    uint256 internal constant SWAP_HOPS_COVERED = 2;
    /// @dev The tail withheld by this swap's in-swap work, set at the top of each afterSwap's post-work ({_tail}). A coin
    /// whose rewards tracker needs a large balance-sync stipend needs more than {SWAP_TAIL_RESERVE} left for its own
    /// post-swap transfer, or spending more gas would make the trade revert.
    uint256 private transient _swapTail;
    /// @notice The largest post-swap transfer tail of any coin configured on this hook. Reserved on EVERY pool: in a
    /// multi-hop trade an earlier pool cannot see a later hop's coin, so each pool leaves room for the heaviest one.
    uint256 public maxCoinTail;
    event MaxCoinTailSet(uint256 tail);

    /// @dev Ceiling on the gas one swap may spend on payouts for other holders, keeping trader cost bounded and
    /// predictable. Unreached work stays booked for a later swap, {distribute} or `owed[]`.
    uint256 internal constant AUTO_DISTRIBUTE_MAX = 2_000_000;
    /// @dev Fraction of {AUTO_DISTRIBUTE_MAX} a failed attempt must have actually spent before the pool is latched
    /// as unable to redeem in-swap (see {_maybeAutoDistribute}).
    uint256 internal constant AUTO_REDEEM_SPEND_NUM = 3;
    uint256 internal constant AUTO_REDEEM_SPEND_DEN = 4;

    /// @dev Gas a rewards try-call may forward, keyed on whether the quote is native (one value call) or ERC20
    /// (self-call, transfer, notify).
    function _feedGasCap(bool native) internal pure returns (uint256) {
        return native ? FEED_GAS_CAP_NATIVE : FEED_GAS_CAP_TOKEN;
    }

    /// @notice Optional launch guards, grouped in one slot so {TaxConfig} stays constructible; `hasGuards` lets
    /// swaps skip loading it when no guard is set.
    struct Guards {
        uint16 maxBuyBps;       // informational: the cap as bps of supply (maxBuyAmount is what's enforced)
        uint16 launchTaxBps;    // opening tax for the launch window, decaying to buyBps/sellBps
        uint128 maxBuyAmount;   // absolute per-transaction ceiling in coin units, resolved from supply
        uint40 launchTime;     // unix ts the pool was configured at; anchors the decay window
        uint16 launchTaxSecs; // length of the decay window, in SECONDS
        uint40 tradingOpensAt;  // unix ts before which swaps revert (the launch tx itself excepted)
    }

    struct TaxConfig {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        bool configured;
        bool autoEnabled;
        bool autoSend;          // true = PUSH the creator share to its recipients in-swap (pull ledger is the fallback)
        bool quoteIsC0;         // true if the QUOTE token is currency0 (else currency1). Set at configure time.
        /// @dev True when any guard is on. Kept in slot 0 so the check costs no extra SLOAD.
        bool hasGuards;
        /// @dev Set when an in-swap redeem was given the full {AUTO_DISTRIBUTE_MAX}, spent most of it, and still failed.
        /// While set, swaps skip the redeem (the ring walk still runs); off-swap payouts are unaffected and
        /// {resetAutoRedeem} can clear it. Kept in slot 0 to avoid an extra SLOAD.
        bool autoRedeemLatched;
        /// @dev The tracker pays rewards in the coin, not the quote. Read once from the tracker at configure time.
        bool rewardsInCoin;
        /// @dev The tracker converts rewards itself, so {_maybeConvertRewards} runs after each swap. Read once from the tracker.
        bool rewardsAutoConvert;
        address quote;          // the pool's quote token (stock/USDG) — the currency tax is skimmed/paid in
        /// @dev Creator-pool slice routed to buyback-and-burn. Placed after `quote` to pack into its slot.
        uint16 buybackBps;
        /// @dev Creator-pool slice routed to auto-liquidity. Packs into `quote`'s slot.
        uint16 lpBps;
        /// @dev Platform rates snapshotted at launch by {configurePool} and never rewritten. Pack into `quote`'s slot.
        uint16 platformShareBps;
        uint16 platformFloorBps;
        uint16 platformCapBps;
        address rewardsTracker; // 0 = not a rewards pool; else the coin's quote-token DividendTracker
        uint16 rewardsBps;      // slice of the CREATOR pool routed to holders; 0 = none
        uint80 autoThreshold;   // accrued-quote (raw units) that triggers the in-swap auto-distribute
        Guards guards;
    }

    // The `Split` struct lives in {RealmAnyPairsSplitLib} so the storage array can be passed to library functions.

    IPoolManager public immutable poolManager;

    // ── max wallet, enforced where the BUY is visible (audit round 9, High) ──
    /// @notice The coin's max-wallet immutables, cached at {configurePool}: `until << 128 | cap`. Zeroed for good
    /// once the window lapses, so a buy after it reads one zero slot and does nothing else.
    mapping(address => uint256) private _maxWalletOf;
    /// @notice Coin bought by an EOA, per coin, while that coin's max-wallet window is live. Persistent ACROSS
    /// transactions -- that is the whole point; see {_requireUnderMaxWallet}.
    mapping(address => mapping(address => uint256)) public boughtWhileCapped;

    // ── global emergency brakes, by section (operator request, audit round 9) ──
    //
    // Every one of these is an OPTIONAL in-swap convenience with a safe deferral already built in, so switching one
    // off never destroys or strands value -- it moves the work off the swap:
    //   * AUTO_DISTRIBUTE -- the pot stays accrued and is redeemed by a later swap or by {runDistribute}.
    //   * AUTO_SEND       -- the creator share books to `owed[]`, the pull ledger, and stays claimable.
    //   * BUYBACK / AUTO_LIQUIDITY / REFLECT -- their pots stay booked, drained later by {runBuyback},
    //     {runAddLiquidity} and {runReflect}, which anyone may call.
    //   * REWARDS         -- holders are pushed by a later swap, by the coin's transfer poke, by the permissionless
    //     paid `distributeFor`, or they claim. Conversions resume when it is switched back on.
    //   * PLATFORM_SEND   -- the platform cut books to `owed[]` and is claimed, exactly like AUTO_SEND
    //     does for the creator side.
    // The rewards SLICE that funds a tracker is deliberately NOT pausable by SECTION: it is an internal accrual, and
    // pausing the accrual itself would starve the tracker. Round 14 (F-7): the in-swap PUSH of that slice IS gated by
    // {inSwapRegistry} like every other push, and a denied quote books to `owed[]`, which the tracker claims.
    // NOTHING HERE CAN STOP A HOLDER BEING PAID: claims, the pull ledger and every permissionless poke are outside
    // this switch. It only decides whether the work rides along with a trade.
    /// @notice Bitmask of in-swap sections switched off for EVERY pool. 0 (the default) is normal operation.
    uint256 public pausedSections;
    uint256 public constant SECTION_AUTO_DISTRIBUTE = 1 << 0;
    uint256 public constant SECTION_AUTO_SEND = 1 << 1;
    uint256 public constant SECTION_BUYBACK = 1 << 2;
    uint256 public constant SECTION_AUTO_LIQUIDITY = 1 << 3;
    uint256 public constant SECTION_REFLECT = 1 << 4;
    uint256 public constant SECTION_REWARDS = 1 << 5;
    /// @notice The PLATFORM cut: book it to the pull ledger instead of pushing it in-swap.
    uint256 public constant SECTION_PLATFORM_SEND = 1 << 6;
    /// @dev Every defined bit; anything outside it is refused so a typo cannot half-pause the hook.
    uint256 internal constant SECTIONS_ALL = (1 << 7) - 1;

    /// @notice Addresses allowed to add liquidity to a guarded pool while its max-wallet window is live -- the
    /// launch's LP locker. Registered automatically by {setLauncher}, which reads the launcher's own locker, so there
    /// is no extra deploy step to forget; {setLpProvider} is the manual escape hatch.
    mapping(address => bool) public isLpProvider;

    /// @notice A payee that has opted out of permissionless {pushOwed}. Self-set only: nobody can opt anyone else
    /// in or out. Claiming through {claim} / {claimTo} is unaffected. (Audit round 14, F-9.)
    mapping(address => bool) public noPush;

    mapping(address => bool) public isLauncher;
    uint256 public launcherCount; // number of addresses currently whitelisted in isLauncher
    address public platform;
    address public admin;

    mapping(PoolId => TaxConfig) internal _config;
    mapping(PoolId => RealmAnyPairsSplitLib.Split[]) internal creatorSplits;
    mapping(PoolId => uint256) public accruedQuote;           // per-pool tax accrued, in the pool's quote token

    // ── buyback-and-burn ─────────────────────────────────────────────────────────────────────────
    /// @notice Where bought-back coin is sent. Not `address(0)`, which many ERC20s reject.
    /// @dev Does not reduce `totalSupply()`.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @dev Gas the in-swap buyback must have beyond {SWAP_TAIL_RESERVE}. Sized for a dividend coin, whose transfer
    /// to {BURN_SINK} needs its balance-sync gas floor (~285k) on top of the swap.
    uint256 internal constant BUYBACK_CONVERT_GAS = 450_000;

    /// @notice Quote accrued for this pool's buyback, awaiting a swap that can afford to spend it.
    /// @dev Credited by {_distribute}, spent by {_maybeBuyback} or {runBuyback}. Backed by real quote the hook holds.
    mapping(PoolId => uint256) public buybackPot;

    // ── auto-liquidity ───────────────────────────────────────────────────────────────────────────
    /// @dev Gas the in-swap LP add must have beyond {SWAP_TAIL_RESERVE}: swap, modifyLiquidity, and a leftover-coin
    /// transfer to {BURN_SINK} sized for a dividend coin.
    uint256 internal constant LP_CONVERT_GAS = 700_000;

    /// @notice Quote accrued for this pool's auto-liquidity, awaiting a swap that can afford it.
    mapping(PoolId => uint256) public lpPot;

    // ── reflections ──────────────────────────────────────────────────────────────────────────────
    /// @dev Gas the in-swap reflection must have beyond {SWAP_TAIL_RESERVE}: swap, delivering the coin to the
    /// tracker (dividend-coin balance-sync floor), and `feedToken`.
    uint256 internal constant REFLECT_CONVERT_GAS = 650_000;

    /// @dev Gas for the post-swap rewards step ({_maybeRewardsStep}) beyond {_tail}: an auto-converting tracker's
    /// `convertStep`, or any other tracker's `process` (holders' auto-push). Skipped unless the whole amount is available.
    /// Covers at least one push of the heaviest kind: a reflection tracker's coin push (`minDebit` 250k x 64/63 +
    /// overhead) plus the loop's prologue and floor.
    uint256 internal constant REWARD_CONVERT_GAS = 650_000;

    /// @notice Quote accrued for this pool's coin-denominated holder rewards, awaiting conversion.
    mapping(PoolId => uint256) public reflectPot;
    mapping(address => mapping(address => uint256)) public owed; // recipient => quoteToken => amount (pull ledger)

    /// @notice Owner-set initial auto-distribute threshold per quote token, in that quote's units. 0 = use the
    /// decimals-derived default from {_initialAutoThreshold}.
    mapping(address => uint80) public defaultAutoThreshold;


    /// @notice {RealmAnyPairsInSwapRegistry}: denylist of quotes that may not be paid to arbitrary recipients during
    /// a swap. Owner-settable so a quote can be revoked quickly.
    address public inSwapRegistry;

    address public weth;
    address public swapRouter;
    mapping(address => bytes) public quoteToWethPath;   // quote token -> V3 path quote→…→WETH

    event PoolConfigured(PoolId indexed poolId, address indexed creator, uint16 buyBps, uint16 sellBps);
    event TaxAccrued(PoolId indexed poolId, bool isBuy, uint256 quoteAmount);
    /// @dev `quote` was added to this pool's buyback pot by a distribution.
    event BuybackAccrued(PoolId indexed id, uint256 quote);
    /// @dev The creator changed the buyback slice. Emitted for 0 too.
    event BuybackBpsSet(PoolId indexed id, uint16 buybackBps);
    /// @dev `quoteSpent` bought `coinBurned`, sent to {BURN_SINK}. Reports measured amounts, not requested ones.
    event BuybackExecuted(PoolId indexed id, uint256 quoteSpent, uint256 coinBurned);
    /// @dev An in-swap buyback was deferred. `reason` 0 = not enough gas, 1 = the swap reverted. {buybackPot} is kept.
    event BuybackSkipped(PoolId indexed id, uint256 pot, uint8 reason);
    /// @dev `quote` was added to this pool's auto-liquidity pot by a distribution.
    event AutoLiquidityAccrued(PoolId indexed id, uint256 quote);
    /// @dev `quoteSpent` became `liquidity` of permanently locked position in this pool.
    event AutoLiquidityAdded(PoolId indexed id, uint256 quoteSpent, uint128 liquidity);
    /// @notice Quote returned by the hook's own LP position (leftovers and earned fees) was put back
    /// into the pool's auto-liquidity pot instead of stranding on the hook.
    /// @notice Quote left over from an auto-liquidity add, recycled into the LP pot.
    /// @dev AUDIT ROUND 14: this and the comments around it used to describe HARVESTING the position's trading fees.
    /// Realm pools are ZERO-FEE since round 12, so no trading fees exist to harvest; what is recycled here is the
    /// unspent remainder of the tax's own LP slice.
    event AutoLiquidityFeesRecycled(PoolId indexed poolId, uint256 amount);
    /// @dev An in-swap add was deferred. `reason` 0 = not enough gas, 1 = it reverted. {lpPot} is kept.
    event AutoLiquiditySkipped(PoolId indexed id, uint256 pot, uint8 reason);
    /// @dev The creator changed the auto-liquidity slice. Emitted for 0 too.
    event LpBpsSet(PoolId indexed id, uint16 lpBps);
    /// @dev `quote` was accrued for coin-denominated holder rewards.
    event ReflectionAccrued(PoolId indexed id, uint256 quote);
    /// @dev `quoteSpent` bought `coin`, which was delivered to the tracker and booked.
    event ReflectionPaid(PoolId indexed id, uint256 quoteSpent, uint256 coin);
    /// @dev A reflection was deferred. `reason` 0 = not enough gas, 1 = it reverted. {reflectPot} is kept.
    event ReflectionSkipped(PoolId indexed id, uint256 pot, uint8 reason);

    /// @notice Emitted once per swap for volume attribution. Observational only; nothing reads it.
    /// @param sender  caller of `PoolManager.swap` (usually a router, not the trader).
    /// @param origin  `tx.origin`. Analytics hint only; never use it for authorisation.
    /// @param amount0 the pool's currency0 delta from the swapper's perspective (negative = paid in).
    /// @param amount1 the same for currency1.
    /// @param taxAmount tax skimmed, in the quote. On the taxed side a trader who paid in really paid
    ///                `|delta| + taxAmount`; one who received really received `|delta| - taxAmount`.
    /// @param exactInput true when the swap specified its input amount.
    /// @param isBuy   true when the trader bought the coin.
    event SwapObserved(
        PoolId indexed poolId,
        address indexed sender,
        address indexed origin,
        int128 amount0,
        int128 amount1,
        uint256 taxAmount,
        bool exactInput,
        bool isBuy
    );

    event TaxDistributed(PoolId indexed poolId, uint256 toCreatorPool, uint256 toPlatform);
    /// @notice An in-swap redeem of the pot was due but did not happen: the swap could not afford it, or the attempt
    /// reverted and the accrual was restored. Booked payees are unaffected; {distribute} settles the pool.
    event AutoDistributeSkipped(PoolId indexed poolId, uint256 accrued);
    /// @notice A full-budget in-swap redeem failed, so the pool is latched and swaps stop attempting it. Emitted once
    /// per arming, alongside the matching {AutoDistributeSkipped}.
    event AutoRedeemLatched(PoolId indexed poolId, uint256 accrued);
    /// @notice {resetAutoRedeem} moved the latch. `by` is the platform or admin address that moved it.
    event AutoRedeemReset(PoolId indexed poolId, address indexed by);
    /// @notice Ring walk result: `pushed` payees paid, `stillPending` mask left (0 = all paid), `cursor` where the
    /// next walk resumes.
    event PayoutsProcessed(PoolId indexed poolId, uint256 pushed, uint32 stillPending, uint8 cursor);
    /// @notice {setTokenCreator} could not settle the outstanding pot at the old terms and proceeded anyway. The
    /// accrual is kept but will be distributed under the new creator/split. See {_flushAtOldTermsSoft}.
    event FlushDeferred(PoolId indexed poolId, uint256 accrued);
    event Claimed(address indexed recipient, address indexed token, uint256 amount);
    event LauncherSet(address indexed launcher, bool allowed);
    event PlatformSet(address indexed platform);
    event AdminSet(address indexed admin);
    /// @notice A payee opted in or out of permissionless {pushOwed}. (Audit round 14, F-9.)
    event NoPushSet(address indexed payee, bool optedOut);
    /// @notice An address was allowed (or disallowed) to add liquidity while a max-wallet window is live.
    event LpProviderSet(address indexed provider, bool allowed);
    /// @notice The global in-swap section brakes changed. `mask` is the FULL new mask, not a delta.
    event PausedSectionsSet(uint256 mask);
    event RatesSet(PoolId indexed poolId, uint16 buyBps, uint16 sellBps);
    event CreatorSplitSet(PoolId indexed poolId, address indexed by, uint256 recipients);
    event TokenCreatorSet(PoolId indexed poolId, address indexed from, address indexed to);
    /// @notice A {claimPlatform}/{claimPlatformMany} settlement of the platform's cut alone.
    event PlatformClaimed(PoolId indexed poolId, address indexed quote, uint256 amount);
    /// @notice One pool of a {claimPlatformMany} batch paid nothing -- it had no cut accrued, or its own
    /// settlement reverted. The batch continues; this is how the caller finds out which pools did not pay.
    event PlatformClaimSkipped(PoolId indexed poolId);
    /// @notice A {setTokenCreator} handover on a pool with NO split partners let the outstanding pot follow
    /// the incoming creator instead of flushing it to the outgoing one. See {setTokenCreator}.
    event HandoverPotFollowed(PoolId indexed poolId, address indexed to, uint256 amount);
    event RewardsBpsSet(PoolId indexed poolId, uint16 rewardsBps);
    /// @dev A rewards tracker was attached after launch ({adminSetRewardsTracker}). Not emitted by {configurePool}.
    event RewardsTrackerSet(PoolId indexed poolId, address indexed tracker);
    event AutoSendSet(PoolId indexed poolId, bool enabled);
    event MaxBuySet(PoolId indexed poolId, uint16 maxBuyBps, uint128 maxBuyAmount);
    event LaunchGuardsSet(PoolId indexed poolId, uint16 maxBuyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint40 tradingOpensAt);
    /// @notice The wallets that skip this pool's max buy (and the token's max wallet). Emitted once, at launch.
    event SniperWhitelistSet(PoolId indexed poolId, address[] wallets);
    /// @notice `from` (the coin's creator) proposed handing every pool of `coin` to `to`.
    event CreatorProposed(address indexed coin, address indexed from, address indexed to);
    /// @notice A pending creator hand-off for `coin` was withdrawn by its proposer.
    event CreatorProposalCancelled(address indexed coin, address indexed by);
    /// @notice `creator` renounced every pool of `coin`. Payouts continue to the fee split; the admin can still CTO.
    event CreatorRenounced(address indexed coin, address indexed creator);
    /// @notice `amount` of `token` (address(0) = native ETH) that no one was owed was sent to `to`.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event InSwapRegistrySet(address indexed from, address indexed to);
    event CreatorSharePushed(address indexed to, address indexed quote, uint256 amount);
    event AutoThresholdSet(PoolId indexed poolId, uint80 threshold);
    event RewardsRouted(PoolId indexed poolId, address indexed tracker, uint256 amount);
    event SwapConfigSet(address indexed weth, address indexed router);
    event DefaultAutoThresholdSet(address indexed quote, uint80 threshold);
    event QuoteToWethPathSet(address indexed quote, bytes path);
    /// @notice A platform-side ring slot (`slot`) was paid. `pushed` true: `amount` arrived at `to`. `pushed` false:
    /// the push was not possible and `amount` was credited to `owed[to][quote]` instead.
    event FeeCutPaid(PoolId indexed poolId, address indexed to, address quote, uint256 amount, uint8 slot, bool pushed);
    event MaxSideBpsSet(uint16 bps);
    /// @notice New platform rates, applied to coins launched from now on.
    event PlatformRatesSet(uint16 shareBps, uint16 floorBps, uint16 capBps);
    /// @notice The platform rates `poolId` was launched under. Never changes.
    event PoolPlatformRates(PoolId indexed poolId, uint16 shareBps, uint16 floorBps, uint16 capBps);

    error NothingAccrued();
    error NotAContract();
    /// @notice {pushOwed} refused: this payee has opted out of third-party pushes. (Audit round 14, F-9.)
    error PushOptedOut();
    error SplitLibraryMissing();
    /// @dev Renounce attempted while {setSwapConfig} has never been called. See {_requireRenounceReady}.
    error SwapConfigUnset();
    /// @dev Thrown by {RealmAnyPairsSplitLib.requireQuotePath} for {setQuoteToWethPath}; redeclared so this ABI decodes it.
    error BadQuotePath();
    error QuoteIsWeth();
    /// @dev Thrown by {RealmAnyPairsSplitLib.claimTo} when the destination is `address(0)`, this hook or the
    /// PoolManager. Redeclared so this ABI decodes it.
    error BadClaimDestination();
    /// @dev Thrown by {RealmAnyPairsSplitLib.swapToWeth} when the conversion router does not consume the whole quote
    /// it was approved for. Redeclared so this ABI decodes it; {claim} catches it and pays the raw quote instead.
    error PartialFill();
    error NotLauncher();
    error AlreadyConfigured();
    error NotConfigured();
    /// @dev A creator tried to change payout TERMS while a pot accrued under the old terms is outstanding.
    /// Flush it first with the permissionless `distribute(id)`.
    error PendingDistribution();
    error SideCapExceeded();
    error RateNotLowered();
    error BadPlatformRates();
    error BadSplit();
    error BadSplitLength();
    error BadBatchLength();
    error ZeroAddress();
    error NotPairPool();
    error BadPoolFee();
    error WrongHook();
    error PoolNotInitialized();
    error NotCreator();
    error NotAdmin();
    /// @dev The caller is neither the owner nor the admin ({onlyOwnerOrAdmin}).
    error NotOwnerOrAdmin();
    /// @dev {adminSetRewardsTracker} on a pool that already has one. Repointing would strand holders' accrual.
    error TrackerAlreadySet();
    /// @dev {adminSetRewardsTracker} with a codeless tracker: calls to it would succeed and silently lose the slice.
    error TrackerCodeless();
    /// @dev The {resetAutoRedeem} caller is neither the platform nor the admin.
    error NotPlatformOrAdmin();
    error SameCreator();
    error NotPoolManager();
    error BadRewardsBps();
    /// @dev {buybackAndBurnSelf} called by anyone but this contract.
    error NotSelf();
    /// @dev {runBuyback} called on a pool with nothing accrued.
    error NothingToBuyBack();
    /// @dev {runAddLiquidity} on an empty pot, or an add too small to mint any liquidity.
    error NothingToAddLiquidity();
    /// @dev {runReflect} on an empty pot, or a pool with no tracker.
    error NothingToReflect();
    error BadSliceSum();
    error BadAutoThreshold();
    /// @notice {setPausedSections} was given a bit outside {SECTIONS_ALL}.
    error BadSectionMask();
    /// @notice Third-party liquidity was added to a guarded pool while its coin's max-wallet window was live.
    /// See {beforeAddLiquidity} (audit round 11, H-1).
    error LiquidityLockedDuringMaxWallet();
    /// @notice This buy would take `tx.origin`'s total coin bought during the max-wallet window over the coin's
    /// max wallet. See {_requireUnderMaxWallet} (audit round 9, High).
    error MaxWalletAccumulated();
    /// @notice A creator tried to raise {setAutoThreshold} above {MAX_CREATOR_AUTO_THRESHOLD_BPS} of the pool's
    /// quote-side depth (audit round 9).
    error AutoThresholdAboveCap();
    /// @notice The pool's quote-side depth reads zero, so no creator raise of the auto-distribute threshold can be
    /// bounded; the raise is refused (audit round 9).
    error NoQuoteLiquidity();
    error OnlySelf();
    error NoLauncherWhitelisted();
    error AdminZero();
    /// @dev Renounce attempted while {setInSwapRegistry} has never been called. See {_requireRenounceReady}.
    error InSwapRegistryNotSet();
    /// @dev An address that must never be this hook (or, as a creator, the PoolManager): funds sent there are unreachable.
    error SelfAddress();
    error FillTooSmallForTax();
    error MaxBuyExceeded();
    error TradingNotOpen();
    error BadLaunchGuard();
    /// @notice More than {MAX_SNIPER_WHITELIST} wallets in a launch's anti-sniper whitelist.
    error WhitelistTooLarge();
    /// @notice The pool's creator renounced; creator-only setters and hand-offs are closed to them.
    error CreatorIsRenounced();
    /// @notice No creator hand-off is pending for this coin.
    error NoCreatorProposal();
    /// @notice Only the proposed address may accept a creator hand-off.
    error NotProposedCreator();
    /// @notice The proposer is no longer creator of every pool (e.g. an admin CTO happened), or a pool was renounced.
    error StaleCreatorProposal();
    /// @notice Renouncing requires a fee split on every pool -- payouts keep going to it afterwards.
    error RenounceNeedsSplit();
    /// @notice This asset is (or was) a pool quote, a pool coin or WETH -- money may be owed in it.
    error RescueForbiddenAsset(address token);
    /// @notice The native transfer of a rescue failed.
    error RescueFailed();
    error CannotTighten();
    /// @dev A native payout in {pushOwed} failed. Other native sends fall back to the pull ledger instead.
    error EthTransferFailed();
    /// @dev {setQuoteToWethPath} on the native quote, which already pays out in ETH. Distinct from {QuoteIsWeth}.
    error NativeQuote();
    /// @dev Distinct from {CannotTighten}: this one clears on its own within a second or two, and a UI needs
    /// to tell "retry shortly" apart from "permanently rejected".
    error TooSoonAfterLaunch();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Owner or admin. The admin survives {renounceOwnership}, so configuration remains possible afterwards;
    /// a compromised admin is unrecoverable once ownership is renounced (accepted risk).
    /// {transferOwnership} and {renounceOwnership} stay owner-only; do not widen them to this modifier.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) revert NotOwnerOrAdmin();
        _;
    }

    constructor(IPoolManager pm, address owner_, address platform_) RealmAnyPairsImmutableBase(owner_) {
        // Fail at construction if the linked library is not deployed (proves code exists, not that it is the right code).
        if (address(RealmAnyPairsSplitLib).code.length == 0) revert SplitLibraryMissing();
        if (platform_ == address(0)) revert ZeroAddress();
        // poolManager is immutable and has no setter — a zero would brick every hook callback permanently.
        if (address(pm) == address(0)) revert ZeroAddress();
        poolManager = pm;
        admin = owner_;
        platform = platform_;
    }

    // ─────────────────────────── admin ───────────────────────────

    function setLauncher(address launcher, bool allowed) external onlyOwnerOrAdmin {
        // Reject zero so a bogus launcher entry cannot satisfy {_requireRenounceReady}.
        if (launcher == address(0)) revert ZeroAddress();
        if (allowed != isLauncher[launcher]) {
            if (allowed) launcherCount += 1;
            else launcherCount -= 1;
        }
        isLauncher[launcher] = allowed;
        // Round 11 (H-1): whitelist the launcher's LP locker in the same call. It is the only party that must be able
        // to seed and compound while the max-wallet window is live, and deriving it here means a deploy cannot forget.
        if (allowed) {
            // AUDIT ROUND 14: probe BOTH accessor names. The unified launcher exposes `pairLpLocker()`; the pair
            // launcher exposes `lpLocker()`. Probing only the first meant the pair launcher's locker was never
            // auto-whitelisted, so a max-wallet launch through it would revert at the seed against the round-11
            // {beforeAddLiquidity} lock -- silently, because a failed probe is not an error here.
            (bool ok, bytes memory ret) = launcher.staticcall{gas: 20_000}(abi.encodeWithSignature("pairLpLocker()"));
            if (!ok || ret.length < 32) {
                (ok, ret) = launcher.staticcall{gas: 20_000}(abi.encodeWithSignature("lpLocker()"));
            }
            if (ok && ret.length >= 32) {
                address lk = abi.decode(ret, (address));
                if (lk != address(0) && !isLpProvider[lk]) {
                    isLpProvider[lk] = true;
                    emit LpProviderSet(lk, true);
                }
            }
        }
        emit LauncherSet(launcher, allowed);
    }

    /// @dev Blocks {renounceOwnership} until the hook is fully wired: a launcher, a non-zero admin, the swap config
    /// and the in-swap registry. Each would be unrepairable after renounce.
    function _requireRenounceReady() internal view override {
        if (launcherCount == 0) revert NoLauncherWhitelisted();
        // A zero admin could never be restored after renounce, bricking CTO reassignment.
        if (admin == address(0)) revert AdminZero();
        // Unset weth/swapRouter is legal while owned, but only the admin could repair it after renounce.
        if (weth == address(0) || swapRouter == address(0)) revert SwapConfigUnset();
        // An unset registry means no kill switch: every quote would be pushed in-swap with no way to deny one.
        if (inSwapRegistry == address(0)) revert InSwapRegistryNotSet();
    }

    /// @notice Set the initial auto-distribute threshold for NEW pools of `quote`, in that quote's units.
    /// Existing pools are unaffected. 0 falls back to the decimals-derived default.
    /// @dev `address(0)` is allowed: it is the native quote.
    function setDefaultAutoThreshold(address quote, uint80 threshold) external onlyOwnerOrAdmin {
        defaultAutoThreshold[quote] = threshold;
        emit DefaultAutoThresholdSet(quote, threshold);
    }

    /// @dev The threshold a new pool starts with. Never 0 (0 would mean auto-distribute off). Defaults to 0.01
    /// whole units of the quote, derived from its decimals.
    function _initialAutoThreshold(address quote) internal view returns (uint80) {
        uint80 configured = defaultAutoThreshold[quote];
        if (configured != 0) return configured;
        // Native: fixed 0.02 ETH, not derived from decimals() (a staticcall to address(0) returns empty data).
        if (quote == address(0)) return uint80(0.02 ether);
        // Raw staticcall rather than a typed call in try/catch: a typed call to a codeless address, or a return value
        // that does not decode as uint8, reverts this frame and would brick every launch against that quote.
        uint256 dec = 18;
        (bool ok, bytes memory ret) = quote.staticcall{gas: 20_000}(abi.encodeWithSelector(0x313ce567)); // decimals()
        if (ok && ret.length >= 32) dec = abi.decode(ret, (uint256));
        if (dec > 30) dec = 18;                       // nonsense/hostile decimals -> treat as standard
        uint256 t = (10 ** dec) / 100;                // 0.01 quote units
        if (t == 0) t = 1;                            // 0- and 1-decimal tokens
        if (t > type(uint80).max) t = type(uint80).max;
        return uint80(t);
    }

    /// @dev What the trader pays on a side, in bps: the effective creator rate, never below the pool's platform floor.
    function _totalBps(TaxConfig storage c, uint256 effBps) internal view returns (uint256) {
        return RealmAnyPairsFeeMath.totalBps(effBps, c.platformFloorBps);
    }

    /// @dev The platform's slice of `totalBps`, at the pool's snapshotted rates. Always `<= totalBps`; applied with
    /// flooring so every rounding remainder stays on the creator side.
    function _platformBps(TaxConfig storage c, uint256 totalBps) internal view returns (uint256) {
        return RealmAnyPairsFeeMath.platformBps(totalBps, c.platformShareBps, c.platformFloorBps, c.platformCapBps);
    }

    /// @notice The platform's slice of what a trader pays on this side right now, in bps of the trade.
    function platformFeeBpsOf(PoolId id, bool isBuy) external view returns (uint256) {
        TaxConfig storage c = _config[id];
        return _platformBps(c, _totalBps(c, _effectiveBps(c, isBuy)));
    }

    /// @notice What a trader pays on this side right now, in bps of the trade (effective creator rate, or the
    /// platform floor if higher). The platform fee is inside this number.
    function totalFeeBpsOf(PoolId id, bool isBuy) external view returns (uint256) {
        TaxConfig storage c = _config[id];
        return _totalBps(c, _effectiveBps(c, isBuy));
    }

    /// @notice The platform's share of what the trader paid, in bps; complement of {creatorPoolBpsOf}. Uses the
    /// effective rate. Zero on a side that charges nothing.
    function platformBpsOf(PoolId id, bool isBuy) external view returns (uint256) {
        TaxConfig storage c = _config[id];
        uint256 total = _totalBps(c, _effectiveBps(c, isBuy));
        if (total == 0) return 0;
        return _platformBps(c, total) * BPS / total;
    }

    /// @notice The CREATOR pool's share of what the trader paid on this side, in bps -- the complement of
    /// {platformBpsOf}, on the same EFFECTIVE rate. Zero on a side that charges nothing at all.
    function creatorPoolBpsOf(PoolId id, bool isBuy) external view returns (uint256) {
        TaxConfig storage c = _config[id];
        uint256 total = _totalBps(c, _effectiveBps(c, isBuy));
        if (total == 0) return 0;
        return BPS - (_platformBps(c, total) * BPS / total);
    }

    /// @notice Tighten the per-side tax ceiling. Cannot exceed {MAX_SIDE_BPS_LIMIT}.
    /// @dev Does not affect configured pools' partial-fill ceiling, which reads constants only.
    function setMaxSideBps(uint16 bps) external onlyOwnerOrAdmin {
        if (bps > MAX_SIDE_BPS_LIMIT) revert SideCapExceeded();
        maxSideBps = bps;
        emit MaxSideBpsSet(bps);
    }

    /// @notice Set the platform rates NEW launches snapshot: `shareBps` of what a trader pays, clamped between
    /// `floorBps` and `capBps` of the trade. Bounds: share 10%-30%, floor <= 1%, floor <= cap <= 3%. Live coins keep their rates.
    function setPlatformRates(uint16 shareBps, uint16 floorBps, uint16 capBps) external onlyOwnerOrAdmin {
        if (shareBps < MIN_PLATFORM_SHARE_BPS || shareBps > MAX_PLATFORM_SHARE_BPS) revert BadPlatformRates();
        if (floorBps > MAX_PLATFORM_FLOOR_BPS || capBps > MAX_PLATFORM_CAP_BPS || capBps < floorBps) {
            revert BadPlatformRates();
        }
        platformShareBps = shareBps;
        platformFloorBps = floorBps;
        platformCapBps = capBps;
        emit PlatformRatesSet(shareBps, floorBps, capBps);
    }

    /// @dev The one place a per-side rate is validated ({configurePool}, {setRates}, {adminSetRates}). Checks both the
    /// mutable cap and the hard {MAX_SIDE_BPS_LIMIT}.
    function _requireRatesOk(uint16 buyBps, uint16 sellBps) internal view {
        uint16 cap = maxSideBps;
        if (cap > MAX_SIDE_BPS_LIMIT) cap = MAX_SIDE_BPS_LIMIT;
        if (buyBps > cap || sellBps > cap) revert SideCapExceeded();
    }

    /// @dev Admin ratchet for {adminSetRates}: the admin may only lower a pool's rate, per side. Only the creator can raise it.
    function _requireRatchetDown(TaxConfig storage c, uint16 buyBps, uint16 sellBps) internal view {
        if (buyBps > c.buyBps || sellBps > c.sellBps) revert RateNotLowered();
    }

    // ── admin overrides of the creator-owned knobs ──

    /// @dev Downward-only ({_requireRatchetDown}): the admin can lower a pool's rate, never raise one. Only the creator
    /// can raise their own rate ({setRates}).
    function adminSetRates(PoolId id, uint16 buyBps, uint16 sellBps) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireRatesOk(buyBps, sellBps);
        _requireRatchetDown(c, buyBps, sellBps);
        c.buyBps = buyBps;
        c.sellBps = sellBps;
        emit RatesSet(id, buyBps, sellBps);
    }

    /// @dev Validates, then flushes the outstanding pot at the old terms before writing, since the rewards share is
    /// read at distribution time.
    function adminSetRewardsBps(PoolId id, uint16 rewardsBps) external onlyOwnerOrAdmin nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        if (c.rewardsTracker == address(0)) revert BadRewardsBps();
        _requireSliceSum(rewardsBps, c.buybackBps, c.lpBps);
        _flushAtOldTerms(id);
        c.rewardsBps = rewardsBps;
        emit RewardsBpsSet(id, rewardsBps);
    }

    /// @notice Attach a rewards tracker to a pool that launched without one. One-shot: a live tracker is never
    /// repointed, since holders' accrual lives in it. The creator then sets the share with {setRewardsBps}.
    /// @dev Admin-gated so it survives renounce. No flush needed: `rewardsBps` is necessarily 0 until a tracker
    /// exists. Rejects zero, this hook ({SelfAddress}) and codeless trackers ({TrackerCodeless}).
    function adminSetRewardsTracker(PoolId id, address tracker) external {
        if (msg.sender != admin || admin == address(0)) revert NotAdmin();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        if (c.rewardsTracker != address(0)) revert TrackerAlreadySet();
        if (tracker == address(0)) revert ZeroAddress();
        if (tracker == address(this)) revert SelfAddress();
        if (tracker.code.length == 0) revert TrackerCodeless();
        c.rewardsTracker = tracker;
        c.rewardsAutoConvert = _rewardsAutoConvert(tracker);
        c.rewardsInCoin = _trackerPaysInItsPoolCoin(id, tracker);
        {
            // A tracker attached later can make its coin heavier: reserve that everywhere too.
            (bool tok, bytes memory tdata) = tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("token()"));
            if (tok && tdata.length == 32) {
                address coin = abi.decode(tdata, (address));
                PoolId[] storage ids = _coinPools[coin];
                for (uint256 i; i < ids.length; ++i) {
                    if (PoolId.unwrap(ids[i]) == PoolId.unwrap(id)) {
                        _noteTail(_coinTail(coin));
                        break;
                    }
                }
            }
        }
        emit RewardsTrackerSet(id, tracker);
    }

    function adminSetAutoThreshold(PoolId id, uint80 threshold) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        if (!c.autoEnabled || threshold == 0) revert BadAutoThreshold();
        c.autoThreshold = threshold;
        emit AutoThresholdSet(id, threshold);
    }

    /// @dev Flushes at the old terms first, like {setCreatorSplit}: the split is read at distribution time.
    function adminSetCreatorSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps)
        external onlyOwnerOrAdmin nonReentrant
    {
        if (!_config[id].configured) revert NotConfigured();
        _flushAtOldTerms(id);
        _storeSplit(id, recipients, bps, address(0));
        emit CreatorSplitSet(id, msg.sender, recipients.length);
    }

    /// @notice Allow or disallow an address to add liquidity to a guarded pool while its max-wallet window is live.
    /// The launcher's own locker is registered automatically by {setLauncher}; this is for anything else.
    function setLpProvider(address provider, bool allowed) external onlyOwnerOrAdmin {
        if (provider == address(0)) revert ZeroAddress();
        isLpProvider[provider] = allowed;
        emit LpProviderSet(provider, allowed);
    }

    /// @notice Switch in-swap sections off (or back on) for EVERY pool at once. Platform owner or admin.
    /// @param mask Bits from {SECTION_AUTO_DISTRIBUTE} .. {SECTION_REWARDS}; 0 restores normal operation.
    /// @dev The emergency brake, and deliberately a single write: in an incident the operator should not have to walk
    /// every pool. It is the global counterpart to the per-pool {adminSetAutoSend} and to {inSwapRegistry}, which
    /// denies in-swap payouts per QUOTE token. Pausing a section only takes that work OFF THE SWAP -- each has a safe
    /// deferral (see {pausedSections}) -- so it can never strand a holder's rewards or a creator's fees. Claims, the
    /// pull ledger and the permissionless pokes are unaffected. It survives a creator renounce, and the admin can be
    /// set to `address(0)` to give it up permanently.
    function setPausedSections(uint256 mask) external onlyOwnerOrAdmin {
        if (mask & ~SECTIONS_ALL != 0) revert BadSectionMask();
        pausedSections = mask;
        emit PausedSectionsSet(mask);
    }

    /// @notice Whether one section is currently switched off globally.
    function sectionPaused(uint256 section) public view returns (bool) {
        return pausedSections & section != 0;
    }

    /// @notice Set the in-swap registry. `address(0)` removes the kill switch: every quote is then pushed in-swap.
    /// {renounceOwnership} refuses to run while it is unset.
    function setInSwapRegistry(address r) external onlyOwnerOrAdmin {
        emit InSwapRegistrySet(inSwapRegistry, r);
        inSwapRegistry = r;
    }

    // Transient marker for the launch transaction, letting the launcher's atomic dev buy pass the trading-delay and
    // max-buy gates. EIP-1153 clears it when the transaction ends.
    function _launchTxSlot(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("realm.launchTx", id));
    }

    /// @dev Records which address (the launcher's LP locker) may use the launch-transaction exemption, so no other
    /// contract in the launch tx can bypass the guards. Fail-closed: if the locker cannot be read, nothing is exempt.
    function _markLaunchTx(PoolId id, address launcher_) internal {
        address seeder;
        (bool ok, bytes memory d) =
            launcher_.staticcall{gas: 20_000}(abi.encodeWithSelector(ILauncherSeeder.lpLocker.selector));
        if (ok && d.length == 32) seeder = address(uint160(abi.decode(d, (uint256))));
        if (seeder == address(0)) return;
        bytes32 s = _launchTxSlot(id);
        uint256 v = uint256(uint160(seeder));
        assembly ("memory-safe") { tstore(s, v) }
    }

    /// @dev Consume the launch-transaction exemption. See {_requireUnderMaxBuy}.
    function _clearLaunchTx(PoolId id) internal {
        bytes32 s = _launchTxSlot(id);
        assembly ("memory-safe") { tstore(s, 0) }
    }

    /// @dev True only inside the launch transaction for the recorded sender: the transient marker is set and the
    /// timestamp equals the launch time.
    function _inLaunchTx(PoolId id, TaxConfig storage c, address sender) internal view returns (bool) {
        if (sender == address(0)) return false;
        if (block.timestamp != uint256(c.guards.launchTime)) return false;
        bytes32 s = _launchTxSlot(id);
        uint256 v;
        assembly ("memory-safe") { v := tload(s) }
        return v == uint256(uint160(sender));
    }

    /// @notice Opt this caller in or out of permissionless {pushOwed}. Self-service: `msg.sender` only.
    function setNoPush(bool on) external {
        noPush[msg.sender] = on;
        emit NoPushSet(msg.sender, on);
    }

    function setPlatform(address platform_) external onlyOwnerOrAdmin {
        if (platform_ == address(0)) revert ZeroAddress();
        // `owed[address(this)][quote]` could never be drained.
        if (platform_ == address(this)) revert SelfAddress();
        platform = platform_;
        emit PlatformSet(platform_);
    }

    /// @dev `address(this)` is rejected: {setTokenCreator} is admin-gated, so it would kill the CTO path.
    /// `address(0)` is allowed and disables admin powers (permanently, once ownership is renounced).
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) revert SelfAddress();
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @notice Configure the WETH token and SwapRouter02 used to convert quote fees to ETH at claim time.
    /// Both must be non-zero.
    function setSwapConfig(address weth_, address router_) external onlyOwnerOrAdmin {
        if (weth_ == address(0) || router_ == address(0)) revert ZeroAddress();
        weth = weth_;
        isPoolAsset[weth_] = true; // every WETH ever configured stays unrescuable
        swapRouter = router_;
        emit SwapConfigSet(weth_, router_);
    }

    /// @notice Set the V3 path (quote→…→WETH) used to convert a quote's fees to ETH at claim. Must start at `quote`
    /// and end at `weth`. Without a path, fees pay out in the quote. A path cannot be cleared once set, but a stale
    /// path degrades to a raw-quote payout rather than stranding funds.
    /// @dev Rejects the native quote, which already pays out in ETH.
    function setQuoteToWethPath(address quote, bytes calldata path) external onlyOwnerOrAdmin {
        if (quote == address(0)) revert NativeQuote();
        RealmAnyPairsSplitLib.requireQuotePath(quote, weth, path);
        quoteToWethPath[quote] = path;
        emit QuoteToWethPathSet(quote, path);
    }

    /// @dev Identify the coin (the RealmAnyPairsTokenPlain minted by `launcher`) and the quote in a {coin,quote} pool,
    /// and validate the pool shape. Returns (coin, quote, quoteIsCurrency0).
    function _shape(PoolKey calldata key, address launcher)
        internal
        view
        returns (address coin, address quote, bool quoteIsC0)
    {
        if (key.fee != POOL_FEE) revert BadPoolFee();
        if (address(key.hooks) != address(this)) revert WrongHook();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        // `address(0)` (native ETH) is a legal quote. Native can only be currency0, so a zero currency1 is a malformed key.
        if (c1 == address(0)) revert NotPairPool();
        // Probe currency1 first: {_isCoin} is a typed call, and probing address(0) would revert instead of returning false.
        if (_isCoin(c1, launcher)) { coin = c1; quote = c0; quoteIsC0 = true; }
        else if (c0 != address(0) && _isCoin(c0, launcher)) { coin = c0; quote = c1; quoteIsC0 = false; }
        else revert NotLauncher();
    }

    function _isCoin(address t, address launcher) internal view returns (bool) {
        try RealmAnyPairsTokenPlain(t).launcher() returns (address l) { return l == launcher; }
        catch { return false; }
    }

    // AUDIT ROUND 12, PRODUCT DECISION: REFERRALS ARE REMOVED.
    //
    // `markReferred` used to record a one-shot referrer per pool, and {_distribute} paid that address 10% of the
    // PLATFORM cut for the life of the coin. It was removed rather than screened. The screen it carried could only
    // refuse addresses that provably cannot claim (the coin, the creator, the quote, this hook, the PoolManager, the
    // rewards tracker, any launcher, the burn sink); it could not tell a genuine referral from a creator naming a
    // second EOA they control, because nothing on chain distinguishes the two. No on-chain check can.
    //
    // THE PLATFORM CUT IS UNCHANGED BY THIS. The referral slice was always carved OUT of `toPlatform`, never added
    // to the trader's cost, so the rate maths and the {configurePool} snapshot never referenced it. With referrals
    // gone the platform simply keeps the whole of `toPlatform` -- the trader pays exactly what they paid before, and
    // nothing is left unassigned.


    // ─────────────────────── pool configuration ───────────────────────

    struct ConfigParams {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        address rewardsTracker;
        uint16 rewardsBps;
        bool autoSend;          // true = pay the creator share out in-swap instead of accruing it to owed[]
        /// @dev Auto-distribute threshold in the quote's units. 0 = use the default. Retunable via {setAutoThreshold}.
        uint80 autoThreshold;
        // ── optional launch guards; leave every one at 0 to opt out (existing callers unaffected) ──
        uint16 maxBuyBps;        // max single buy as bps of total supply
        uint16 launchTaxBps;     // opening tax for the launch window
        uint16 launchTaxSecs;  // decay window length, in SECONDS (block.number here is the L1 block)
        uint8 tradingDelaySecs;  // jitter window: trading opens 1..N seconds after launch
        /// @dev Creator-pool slice routed to buyback-and-burn. 0 = off.
        uint16 buybackBps;
        /// @dev Creator-pool slice routed to auto-liquidity. 0 = off.
        uint16 lpBps;
        /// @dev Anti-sniper whitelist: wallets (matched on tx.origin) that skip the max buy only; they still wait for
        /// trading to open and pay the launch tax. At most {MAX_SNIPER_WHITELIST}; set once, no setter.
        address[] whitelist;
    }

    /// @dev Whether `tracker` pays rewards in `coin` rather than the quote. Read once at configure time; a tracker
    /// without `quote()` is treated as paying in the quote.
    function _rewardsArePaidInCoin(address tracker, address coin) internal view returns (bool) {
        if (tracker == address(0) || coin == address(0)) return false;
        (bool ok, bytes memory data) =
            tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("quote()"));
        if (!ok || data.length != 32) return false;
        return abi.decode(data, (address)) == coin;
    }

    /// @dev The gas to withhold after in-swap work for this pool: at least {SWAP_TAIL_RESERVE}, and at least the coin's own
    /// balance-sync `minDebit` plus {SWAP_TAIL_MARGIN}. A coin that does not answer `syncGasParams()` gets the constant.
    /// Always asks the coin: a tracker can be attached coin-side without the hook's `rewardsTracker`.
    function _tailFor(PoolKey calldata key, TaxConfig storage c) internal view returns (uint256) {
        return _coinTail(Currency.unwrap(c.quoteIsC0 ? key.currency1 : key.currency0));
    }

    /// @dev `coin`'s post-swap transfer tail: its `syncGasParams().minDebit` + {SWAP_TAIL_MARGIN}, at least
    /// {SWAP_TAIL_RESERVE}. A coin that does not answer gets the constant.
    function _coinTail(address coin) internal view returns (uint256) {
        (bool ok, bytes memory ret) = coin.staticcall{gas: 30_000}(abi.encodeWithSignature("syncGasParams()"));
        if (!ok || ret.length < 96) return SWAP_TAIL_RESERVE;
        (, uint256 minDebit,) = abi.decode(ret, (uint256, uint256, uint256));
        uint256 t = minDebit + SWAP_TAIL_MARGIN;
        return t > SWAP_TAIL_RESERVE ? t : SWAP_TAIL_RESERVE;
    }

    /// @notice Permissionless: re-read `coin`'s transfer tail and raise {maxCoinTail} to it. Only coins with a configured
    /// pool count. Called by `RealmAnyPairsTokenPlain.attachTracker`, so a tracker attached after the hook side is wired
    /// is still reserved.
    function refreshCoinTail(address coin) external {
        if (_coinPools[coin].length != 0) _noteTail(_coinTail(coin));
    }

    /// @dev Raise {maxCoinTail} to `t` if larger.
    function _noteTail(uint256 t) internal {
        if (t > maxCoinTail) {
            maxCoinTail = t;
            emit MaxCoinTailSet(t);
        }
    }

    /// @dev Extra gas an in-swap step that MOVES THE COIN (buyback, auto-liquidity, reflection) must forward for a coin whose
    /// balance-sync floor exceeds the one those steps' constants were sized for: the part of this pool's tail above
    /// {SWAP_TAIL_RESERVE}. Zero for plain coins and light trackers.
    function _coinExtraGas(PoolKey calldata key, TaxConfig storage c) internal view returns (uint256) {
        return _tailFor(key, c) - SWAP_TAIL_RESERVE;
    }

    /// @dev Gas left after any in-swap step: the largest of this swap's tail ({_tailFor}), {maxCoinTail} and
    /// {SWAP_TAIL_RESERVE}, plus {SWAP_HOPS_COVERED} later Realm hops of {SWAP_HOP_GAS} each.
    function _tail() internal view returns (uint256 t) {
        t = _swapTail;
        uint256 m = maxCoinTail;
        if (t < m) t = m;
        if (t < SWAP_TAIL_RESERVE) t = SWAP_TAIL_RESERVE;
        t += SWAP_HOP_GAS * SWAP_HOPS_COVERED;
    }

    /// @dev Whether a tracker attached after launch pays in the coin of pool `id`: its `token()` must be a coin this pool
    /// belongs to, and its `quote()` that same coin.
    function _trackerPaysInItsPoolCoin(PoolId id, address tracker) internal view returns (bool) {
        (bool ok, bytes memory data) = tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("token()"));
        if (!ok || data.length != 32) return false;
        address coin = abi.decode(data, (address));
        PoolId[] storage ids = _coinPools[coin];
        for (uint256 i; i < ids.length; ++i) {
            if (PoolId.unwrap(ids[i]) == PoolId.unwrap(id)) return _rewardsArePaidInCoin(tracker, coin);
        }
        return false;
    }

    /// @dev True when `tracker` answers `autoConvertsRewards() == true`. Fail-closed: no readable answer means false.
    function _rewardsAutoConvert(address tracker) internal view returns (bool) {
        if (tracker == address(0)) return false;
        (bool ok, bytes memory data) = tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("autoConvertsRewards()"));
        return ok && data.length == 32 && abi.decode(data, (uint256)) == 1;
    }

    /// @dev Rewards, buyback and LP slices are shares of the same creator pool, so their sum must fit {BPS} after
    /// every change. Shared by every caller that can change a term; add any new slice here.
    function _requireSliceSum(uint256 rewardsBps, uint256 buybackBps, uint256 lpBps) internal pure {
        if (rewardsBps > BPS || buybackBps > BPS || lpBps > BPS) revert BadSliceSum();
        if (rewardsBps + buybackBps + lpBps > BPS) revert BadSliceSum();
    }

    function configurePool(PoolKey calldata key, ConfigParams calldata p) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        (address coin, address quote, bool quoteIsC0) = _shape(key, msg.sender);

        PoolId id = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        if (sqrtP == 0) revert PoolNotInitialized();
        if (_config[id].configured) revert AlreadyConfigured();
        if (p.creator == address(0)) revert ZeroAddress();
        // Never this hook: `owed[address(this)][quote]` is unreachable and a self-push is backed by no accrual.
        if (p.creator == address(this)) revert SelfAddress();
        _requireRatesOk(p.buyBps, p.sellBps);
        // Same self-address rule for the tracker.
        if (p.rewardsTracker == address(this)) revert SelfAddress();
        _requireSliceSum(p.rewardsBps, p.buybackBps, p.lpBps);

        // Hoisted out of the struct literal below to avoid stack-too-deep.
        uint128 maxBuyAmount_ = _guardsFor(
            p.maxBuyBps, p.launchTaxBps, p.launchTaxSecs, p.tradingDelaySecs,
            Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0)
        );
        uint40 opensAt_ = _jitteredOpen(p.tradingDelaySecs);
        // Round 9 (High): cache the coin's max-wallet immutables and treat an armed cap as a guard, so the
        // per-buy path below runs for a coin whose ONLY launch guard is max wallet.
        // {_cacheMaxWallet} is FIRST so short-circuiting can never skip the write it performs.
        bool hasGuards_ =
            _cacheMaxWallet(coin) || p.maxBuyBps != 0 || p.launchTaxBps != 0 || p.tradingDelaySecs != 0;
        _config[id] = TaxConfig({
            creator: p.creator, buyBps: p.buyBps, sellBps: p.sellBps, configured: true,
            // Every pool needs the in-swap path: the platform cut is pushed in-swap. A pull-mode
            // creator's own share is still booked to `owed[]`.
            autoEnabled: true, autoSend: p.autoSend,
            quoteIsC0: quoteIsC0, quote: quote,
            rewardsTracker: p.rewardsTracker, rewardsBps: p.rewardsTracker != address(0) ? p.rewardsBps : 0,
            rewardsInCoin: _rewardsArePaidInCoin(p.rewardsTracker, coin),
            rewardsAutoConvert: _rewardsAutoConvert(p.rewardsTracker),
            // Creator-chosen when supplied, else the default. Never 0.
            autoThreshold: p.autoThreshold != 0 ? p.autoThreshold : _initialAutoThreshold(quote),
            buybackBps: p.buybackBps,
            lpBps: p.lpBps,
            platformShareBps: platformShareBps,
            platformFloorBps: platformFloorBps,
            platformCapBps: platformCapBps,
            hasGuards: hasGuards_,
            // A new pool is never latched; {resetAutoRedeem} can arm it pre-emptively.
            autoRedeemLatched: false,
            guards: Guards({
                maxBuyBps: p.maxBuyBps,
                launchTaxBps: p.launchTaxBps,
                maxBuyAmount: maxBuyAmount_,
                launchTime: uint40(block.timestamp),
                launchTaxSecs: p.launchTaxSecs,
                tradingOpensAt: opensAt_
            })
        });
        _recordSeeder(msg.sender); // the launcher's LP locker, refused as a split recipient below
        _storeSplit(id, p.recipients, p.splitBps, coin);
        _storeSniperWhitelist(id, p.whitelist);
        _requireCoinNotRenounced(coin); // no creator-controlled pool on a renounced coin
        _coinPools[coin].push(id);
        isPoolAsset[coin] = true;  // never rescuable
        isPoolAsset[quote] = true; // address(0) here marks that a native pool exists
        emit PoolConfigured(id, p.creator, p.buyBps, p.sellBps);
        emit PoolPlatformRates(id, platformShareBps, platformFloorBps, platformCapBps);
        TaxConfig storage nc = _config[id];
        _noteTail(_tailFor(key, nc)); // the coin's tracker is linked before its pools are configured
        // Announce the state set here with the same events its setters emit, so indexers see the initial values.
        if (nc.rewardsBps != 0) emit RewardsBpsSet(id, nc.rewardsBps);
        if (nc.autoSend) emit AutoSendSet(id, true);
        if (nc.autoThreshold != 0) emit AutoThresholdSet(id, nc.autoThreshold);
        if (nc.guards.maxBuyAmount != 0) emit MaxBuySet(id, nc.guards.maxBuyBps, nc.guards.maxBuyAmount);
        if (nc.guards.maxBuyBps != 0 || nc.guards.launchTaxBps != 0 || nc.guards.tradingOpensAt != 0) {
            emit LaunchGuardsSet(id, nc.guards.maxBuyBps, nc.guards.launchTaxBps, nc.guards.launchTaxSecs, nc.guards.tradingOpensAt);
        }
        // AUDIT ROUND 12 (M, launch-breaking). The launch-transaction exemption is armed on `hasGuards`, NOT on the
        // three guard fields above. Round 9 made an armed MAX WALLET a guard in its own right (see `hasGuards_`), but
        // this arming site still enumerated only maxBuy / launchTax / tradingOpensAt -- so a launch whose ONLY guard
        // is max wallet ran the full per-buy path with the exemption never armed, and metered its own dev buy against
        // the launching EOA. A dev buy larger than the cap then REVERTED THE LAUNCH ITSELF, which is the whole
        // finding: not a bypass, a brick. The two conditions must be the same condition, so this reads the flag the
        // config actually stores rather than re-deriving it from a subset of the fields.
        if (nc.hasGuards) _markLaunchTx(id, msg.sender);
    }

    // ─────────────────── mutable fee routing (creator + CTO) ───────────────────

    /// @notice Set this pool's tax, up or down, within the 5% hard cap. Creator only. A raise applies to the very
    /// next swap, so front ends should read the live rate ({totalFeeBpsOf}) at quote time.
    /// @dev No flush needed: accrued fees were already collected at the old rate. The launch-tax ramp is unaffected.
    function setRates(PoolId id, uint16 buyBps, uint16 sellBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        _requireRatesOk(buyBps, sellBps);
        c.buyBps = buyBps;
        c.sellBps = sellBps;
        emit RatesSet(id, buyBps, sellBps);
    }

    /// @dev Flushes the outstanding pot at the old terms first: the share is read at distribution time, so changing
    /// it over an outstanding pot would reprice fees holders already earned.
    function setRewardsBps(PoolId id, uint16 rewardsBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        // Validate before flushing.
        if (c.rewardsTracker == address(0)) revert BadRewardsBps();
        _requireSliceSum(rewardsBps, c.buybackBps, c.lpBps);
        _flushAtOldTerms(id);
        c.rewardsBps = rewardsBps;
        emit RewardsBpsSet(id, rewardsBps);
    }

    /// @notice Retune the slice of this pool's creator share that is bought back and burned. Creator only.
    /// @dev Flushes at the old terms first. Not ratchet-limited; bounded by the slice sum check.
    function setBuybackBps(PoolId id, uint16 buybackBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        _requireSliceSum(c.rewardsBps, buybackBps, c.lpBps);
        _flushAtOldTerms(id);
        c.buybackBps = buybackBps;
        // Turning the buyback on opts the pool into the in-swap path and seeds a threshold if unset (announced).
        if (buybackBps != 0) {
            c.autoEnabled = true;
            if (c.autoThreshold == 0) {
                c.autoThreshold = _initialAutoThreshold(c.quote);
                emit AutoThresholdSet(id, c.autoThreshold);
            }
        } else if (!_autoStillNeeded(c)) {
            // Turning it off disables the auto path only if nothing else needs it. See {_autoStillNeeded}.
            c.autoEnabled = false;
        }
        emit BuybackBpsSet(id, buybackBps);
    }

    /// @notice Retune the slice of this pool's creator share added as permanently locked liquidity. Creator only.
    /// @dev Shaped like {setBuybackBps}.
    function setLpBps(PoolId id, uint16 lpBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        _requireSliceSum(c.rewardsBps, c.buybackBps, lpBps);
        _flushAtOldTerms(id);
        c.lpBps = lpBps;
        if (lpBps != 0) {
            c.autoEnabled = true;
            if (c.autoThreshold == 0) {
                c.autoThreshold = _initialAutoThreshold(c.quote);
                emit AutoThresholdSet(id, c.autoThreshold);
            }
        } else if (!_autoStillNeeded(c)) {
            // Only if nothing else needs the auto path. See {_autoStillNeeded}.
            c.autoEnabled = false;
        }
        emit LpBpsSet(id, lpBps);
    }

    /// @notice Retune the accrued-quote level that triggers this pool's in-swap auto-distribute. Creator only.
    /// @dev AUDIT ROUND 9: a creator RAISE is capped at {MAX_CREATOR_AUTO_THRESHOLD_BPS} (1%) of the pool's quote-side
    /// depth, read at call time. The threshold is how long holders' rewards sit in the hook before they are pushed, so an
    /// unbounded one is a creator lever to park the reward stream indefinitely; at 1% of quote depth it can hold at most
    /// what a 1%-of-the-pool trade produces. Depth is the QUOTE-side virtual reserve of the pool's own in-range liquidity
    /// ({_quoteDepth}) -- the same pool the accrual comes from, no oracle, no external pool. A LOWER (or equal) threshold
    /// is never gated: it can only shorten the wait. If depth reads zero (uninitialized, or no in-range liquidity) a raise
    /// is REFUSED rather than defaulted, so an empty pool cannot be used to set any threshold at all.
    /// The platform default ({setDefaultAutoThreshold}) and {adminSetAutoThreshold} stay uncapped.
    function setAutoThreshold(PoolId id, uint80 threshold) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        if (!c.autoEnabled || threshold == 0) revert BadAutoThreshold();
        if (threshold > c.autoThreshold) {
            uint256 depth = _quoteDepth(id, c.quoteIsC0);
            if (depth == 0) revert NoQuoteLiquidity();
            if (uint256(threshold) > (depth * MAX_CREATOR_AUTO_THRESHOLD_BPS) / BPS) revert AutoThresholdAboveCap();
        }
        c.autoThreshold = threshold;
        emit AutoThresholdSet(id, threshold);
    }

    /// @dev The pool's QUOTE-side depth right now: the virtual reserve its in-range liquidity represents on the quote
    /// side (`x = L * 2^96 / sqrtP` for currency0, `y = L * sqrtP / 2^96` for currency1). Zero when the pool is
    /// uninitialized or has no liquidity in range.
    function _quoteDepth(PoolId id, bool quoteIsC0) internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        if (sqrtP == 0) return 0;
        uint256 liq = poolManager.getLiquidity(id);
        if (liq == 0) return 0;
        return quoteIsC0 ? FullMath.mulDiv(liq, Q96, sqrtP) : FullMath.mulDiv(liq, sqrtP, Q96);
    }

    function setCreatorSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        // Flush at the old split first: rewriting it over an outstanding pot would reprice money already earned.
        _flushAtOldTerms(id);
        _storeSplit(id, recipients, bps, address(0));
        emit CreatorSplitSet(id, msg.sender, recipients.length);
    }

    /// @dev Settle any outstanding pot at the current terms before the caller changes them; no-op when nothing is
    /// pending. Calls `poolManager.unlock` directly, so the hard-flushing setters revert with `AlreadyUnlocked` when
    /// called from inside an existing V4 lock.
    function _flushAtOldTerms(PoolId id) internal {
        uint256 amount = accruedQuote[id];
        if (amount == 0) return;
        uint256 plat = accruedPlatformQuote[id];
        accruedQuote[id] = 0;
        accruedPlatformQuote[id] = 0;
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, amount, plat, FLUSH_ALL));
    }

    /// @dev Fail-soft flush, used only by {setTokenCreator} so a frozen quote or a short PoolManager balance cannot
    /// block the only CTO path. On failure the accrual is restored (not booked to `owed[]`, which would be unbacked)
    /// and later paid under the new terms. Not `nonReentrant`: the caller already holds the guard.
    function _flushAtOldTermsSoft(PoolId id) internal {
        uint256 amount = accruedQuote[id];
        if (amount == 0) return;
        // Calling from inside a V4 lock is the caller's own state, so fail hard instead of silently repricing the pot.
        // Checked before the try because a hostile quote could fake `AlreadyUnlocked` revert data.
        if (_managerAlreadyUnlocked()) revert PendingDistribution();
        uint256 plat = accruedPlatformQuote[id];
        accruedQuote[id] = 0;
        accruedPlatformQuote[id] = 0;
        try this.flushUnlock(id, amount, plat) {}
        catch {
            // `+=`, not `=`: an absolute write would discard anything accrued inside the failed attempt.
            accruedQuote[id] += amount;
            accruedPlatformQuote[id] += plat;
            emit FlushDeferred(id, amount);
        }
    }

    /// @dev Transient slot of V4's `Lock` unlocked flag: `bytes32(uint256(keccak256("Unlocked")) - 1)`.
    bytes32 internal constant V4_IS_UNLOCKED_SLOT =
        0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    /// @dev True when the PoolManager is already unlocked (so a nested `unlock` would revert). Uses a raw staticcall
    /// to `exttload`; if that fails it reads false (a soft flush) rather than bricking the CTO path.
    function _managerAlreadyUnlocked() internal view returns (bool) {
        (bool ok, bytes memory d) =
            address(poolManager).staticcall(abi.encodeWithSignature("exttload(bytes32)", V4_IS_UNLOCKED_SLOT));
        // Raw word, not `abi.decode(d, (bool))`, which would revert on a value other than 0 or 1.
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    /// @dev Self-only trampoline so {_flushAtOldTermsSoft} can try/catch an unlock. No privilege of its own.
    function flushUnlock(PoolId id, uint256 amount, uint256 plat) external {
        if (msg.sender != address(this)) revert OnlySelf();
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, amount, plat, FLUSH_ALL));
    }

    /// @dev Flushes first and is `nonReentrant`: it replaces the creator and deletes the split in one call.
    function setTokenCreator(PoolId id, address newCreator) external nonReentrant {
        if (msg.sender != admin || admin == address(0)) revert NotAdmin();
        _changeCreator(id, newCreator, true);
    }

    /// @dev The single place a pool's creator changes, used by the admin CTO ({setTokenCreator}) and the voluntary
    /// hand-off ({acceptCreator}). They differ in how an outstanding pot is settled and whether a renounce is cleared.
    function _changeCreator(PoolId id, address newCreator, bool byAdmin) internal {
        if (newCreator == address(0)) revert ZeroAddress();
        // Reject this hook (unreachable `owed` key) and the PoolManager (a pushed share would be taken by the next settler).
        if (newCreator == address(this) || newCreator == address(poolManager)) revert SelfAddress();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        address old = c.creator;
        if (newCreator == old) revert SameCreator();
        // Admin CTO. With split partners: fail-soft flush at the old terms (still reverts inside a V4 lock).
        // With no partners: the unsettled pot follows the new creator. Already-booked ring slots and `owed[]`
        // still pay the old creator either way.
        if (byAdmin) {
            if (creatorSplits[id].length != 0) {
                _flushAtOldTermsSoft(id);
            } else {
                uint256 pot = accruedQuote[id];
                if (pot != 0) emit HandoverPotFollowed(id, newCreator, pot);
            }
            // A CTO hands the pool to a new, active creator, so the renounce does not carry over.
            creatorRenounced[id] = false;
        } else {
            // Voluntary hand-off: hard flush so everything earned under the old terms is paid first; on failure it reverts.
            _flushAtOldTerms(id);
        }
        c.creator = newCreator;
        delete creatorSplits[id];
        _creatorChangedAt[id] = ++_creatorChangeNonce; // voids every proposal made before this change
        emit TokenCreatorSet(id, old, newCreator);
    }

    // ─────────────────────── creator hand-off and renounce ───────────────────────

    /// @dev The single creator-only gate, so a renounce closes every creator setter at once.
    function _requireActiveCreator(TaxConfig storage c, PoolId id) internal view {
        if (msg.sender != c.creator) revert NotCreator();
        if (creatorRenounced[id]) revert CreatorIsRenounced();
    }

    /// @dev A renounce is per coin: refuse configuring a new creator-controlled pool on a renounced coin.
    function _requireCoinNotRenounced(address coin) internal view {
        PoolId[] storage ids = _coinPools[coin];
        if (ids.length != 0 && creatorRenounced[ids[0]]) revert CreatorIsRenounced();
    }

    function _requireActiveCreatorOfCoin(address coin) internal view returns (PoolId[] storage ids) {
        ids = _coinPools[coin];
        uint256 n = ids.length;
        if (n == 0) revert NotConfigured();
        for (uint256 i; i < n; ++i) {
            TaxConfig storage c = _config[ids[i]];
            _requireActiveCreator(c, ids[i]);
        }
    }

    /// @notice Propose handing EVERY pool of `coin` to `newCreator`. CREATOR ONLY, and only while not renounced.
    /// Nothing changes until `newCreator` calls {acceptCreator}; a new proposal replaces the old one.
    function proposeCreator(address coin, address newCreator) external nonReentrant {
        _requireActiveCreatorOfCoin(coin);
        if (newCreator == address(0)) revert ZeroAddress();
        // Nor the PoolManager: a creator share pushed there would be taken by the next settler.
        if (newCreator == address(this) || newCreator == address(poolManager)) revert SelfAddress();
        if (newCreator == msg.sender) revert SameCreator();
        creatorProposalOf[coin] = CreatorProposal({from: msg.sender, to: newCreator});
        _proposedAtNonce[coin] = _creatorChangeNonce; // any creator change after this voids it
        emit CreatorProposed(coin, msg.sender, newCreator);
    }

    /// @notice Withdraw a pending hand-off. Only the address that proposed it.
    function cancelCreatorProposal(address coin) external nonReentrant {
        CreatorProposal storage pr = creatorProposalOf[coin];
        if (pr.to == address(0)) revert NoCreatorProposal();
        if (msg.sender != pr.from) revert NotCreator();
        delete creatorProposalOf[coin];
        emit CreatorProposalCancelled(coin, msg.sender);
    }

    /// @notice Accept a pending hand-off: every pool of `coin` moves to the caller, after settling at the old terms.
    /// Reverts {StaleCreatorProposal} if any creator change or renounce happened since the proposal. A pool whose
    /// PoolManager cannot cover its accrual (e.g. a rebasing-down quote) blocks this until the shortfall is covered.
    function acceptCreator(address coin) external nonReentrant {
        CreatorProposal memory pr = creatorProposalOf[coin];
        if (pr.to == address(0)) revert NoCreatorProposal();
        if (msg.sender != pr.to) revert NotProposedCreator();
        PoolId[] storage ids = _coinPools[coin];
        uint256 n = ids.length;
        uint256 proposedAt = _proposedAtNonce[coin];
        for (uint256 i; i < n; ++i) {
            // `_creatorChangedAt` also catches an admin CTO away and back.
            if (
                _config[ids[i]].creator != pr.from || creatorRenounced[ids[i]] || _creatorChangedAt[ids[i]] > proposedAt
            ) revert StaleCreatorProposal();
        }
        delete creatorProposalOf[coin];
        for (uint256 i; i < n; ++i) _changeCreator(ids[i], pr.to, false);
    }

    /// @notice Give up creator control of every pool of `coin`, permanently for the creator. Requires a fee split on
    /// every pool; payouts, buyback, liquidity adds and reflections continue. The admin can still reassign each pool
    /// ({setTokenCreator}), which clears the renounce on that pool.
    function renounceCreator(address coin) external nonReentrant {
        PoolId[] storage ids = _requireActiveCreatorOfCoin(coin);
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (creatorSplits[ids[i]].length == 0) revert RenounceNeedsSplit();
        }
        for (uint256 i; i < n; ++i) creatorRenounced[ids[i]] = true;
        delete creatorProposalOf[coin];
        emit CreatorRenounced(coin, msg.sender);
    }

    /// @notice Every pool configured for `coin`, in launch order.
    function coinPools(address coin) external view returns (PoolId[] memory) {
        return _coinPools[coin];
    }

    /// @notice The creator of `coin`'s first pool, or address(0) if renounced or unknown. Used by the coin's rewards
    /// tracker. Per-pool admin CTOs on later pools are not reflected.
    function creatorOfCoin(address coin) external view returns (address) {
        PoolId[] storage ids = _coinPools[coin];
        if (ids.length == 0 || creatorRenounced[ids[0]]) return address(0);
        return _config[ids[0]].creator;
    }

    // ─────────────────────── rescue ───────────────────────

    /// @notice Send `amount` of a token (or native ETH, `address(0)`) that no pool can ever owe to `to`. Admin only.
    /// @dev Refused for any {isPoolAsset}: every pool quote and coin, every configured WETH, and native ETH once a
    /// native pool exists (or while WETH is unset). Refused while the PoolManager is unlocked.
    function rescue(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != admin || admin == address(0)) revert NotAdmin();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert SelfAddress();
        if (isPoolAsset[token] || token == weth) revert RescueForbiddenAsset(token);
        if (_managerAlreadyUnlocked()) revert PendingDistribution();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RescueFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    /// @dev Set once from {configurePool}; no other writer.
    function _storeSniperWhitelist(PoolId id, address[] calldata wallets) internal {
        uint256 n = wallets.length;
        if (n == 0) return;
        if (n > MAX_SNIPER_WHITELIST) revert WhitelistTooLarge();
        for (uint256 i; i < n; ++i) sniperWhitelisted[id][wallets[i]] = true;
        emit SniperWhitelistSet(id, wallets);
    }

    /// @dev Records the calling launcher's LP locker so {_storeSplit} can refuse it as a split recipient (a locker
    /// cannot claim or forward quote).
    function _recordSeeder(address launcher_) internal {
        (bool ok, bytes memory d) =
            launcher_.staticcall{gas: 20_000}(abi.encodeWithSelector(ILauncherSeeder.lpLocker.selector));
        if (!ok || d.length != 32) return;
        address seeder = address(uint160(abi.decode(d, (uint256))));
        if (seeder != address(0) && !isSeeder[seeder]) isSeeder[seeder] = true;
    }

    /// @dev True for a rewards tracker funded by this hook whose payout asset is not this pool's quote: quote pushed
    /// to it could never be booked. A multi-basket tracker is allowed only if the quote is one of its denominations
    /// (never for native); a tracker without `quote()` is treated as the native tracker.
    function _isForeignTracker(PoolId id, address r) internal view returns (bool) {
        if (r.code.length == 0) return false;
        // Probes copy at most one word of returndata, so a returndata bomb costs nothing extra.
        (bool ok, uint256 w) = _probeWord(r, abi.encodeWithSignature("feeder()"));
        if (!ok || address(uint160(w)) != address(this)) return false;
        (ok, w) = _probeWord(r, abi.encodeWithSignature("isDenomination(address)", _config[id].quote));
        if (ok) return w == 0; // multi-basket tracker
        (ok, w) = _probeWord(r, abi.encodeWithSignature("quote()"));
        address asset = ok ? address(uint160(w)) : address(0);
        return asset != _config[id].quote;
    }

    /// @dev Validates and stores a creator split via {RealmAnyPairsSplitLib.store} (DELEGATECALL, for size). Beyond
    /// the library's checks, refuses recipients that cannot claim or forward quote: launchers, the pool's own coin
    /// (`ownCoin`) or any configured coin, LP lockers, and foreign-asset trackers. An address that only later becomes
    /// one of these is not caught; the creator can rewrite the split.
    function _storeSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps, address ownCoin) internal {
        for (uint256 i; i < recipients.length; ++i) {
            address r = recipients[i];
            if (
                (ownCoin != address(0) && r == ownCoin) || isLauncher[r] || _coinPools[r].length != 0 || isSeeder[r]
                    || _isForeignTracker(id, r)
                    || _isLpLocker(r) // any Realm AnyPairs LP locker, including one not yet recorded
            ) {
                revert RealmAnyPairsSplitLib.BadSplit();
            }
        }
        RealmAnyPairsSplitLib.store(creatorSplits[id], recipients, bps, address(poolManager));
    }

    /// @dev True for a contract shaped like the LP locker: answers `availableOf(address)` and its `poolManager()` is
    /// this hook's PoolManager.
    function _isLpLocker(address r) internal view returns (bool) {
        if (r.code.length == 0) return false;
        (bool ok,) = _probeWord(r, abi.encodeWithSignature("availableOf(address)", address(0)));
        if (!ok) return false;
        uint256 pm;
        (ok, pm) = _probeWord(r, abi.encodeWithSignature("poolManager()"));
        return ok && address(uint160(pm)) == address(poolManager);
    }

    /// @dev 20,000-gas staticcall that copies at most one word of returndata; `ok` only for an exactly 32-byte answer.
    /// Avoids the memory cost of copying a returndata bomb.
    function _probeWord(address r, bytes memory data) internal view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            ok := staticcall(20000, r, add(data, 32), mload(data), 0, 0)
            ok := and(ok, eq(returndatasize(), 32)) // AFTER the call: Yul evaluates arguments right to left
            if ok {
                returndatacopy(0, 0, 32)
                word := mload(0)
            }
        }
    }

    function splitsOf(PoolId id) external view returns (RealmAnyPairsSplitLib.Split[] memory) {
        return creatorSplits[id];
    }

    // ─────────────────────────── hook callbacks ───────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: true, afterInitialize: false,
            beforeAddLiquidity: true, afterAddLiquidity: false,
            beforeRemoveLiquidity: false, afterRemoveLiquidity: false,
            beforeSwap: true, afterSwap: true, beforeDonate: false, afterDonate: false,
            beforeSwapReturnDelta: true, afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false, afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Refuses third-party liquidity on a guarded pool while its coin's max-wallet window is live.
    /// @dev AUDIT ROUND 11 (H-1, High). Max-wallet accumulation was metered on the SWAP path only, and
    /// `modifyLiquidity` had no hook callback at all, so a buyer never had to swap: mint a quote-only concentrated
    /// range on the side the price travels to on sells (a limit order), let ordinary sells walk the price through it,
    /// then withdraw -- the position is now coin, and taking it as ERC-6909 claims means no ERC-20 transfer and no
    /// `_checkMaxWallet` either. Measured against a 1e21 cap: 34,888e18 held, 34.9x the cap, with
    /// `boughtWhileCapped == 0` and `balanceOf == 0` throughout.
    ///
    /// WHY REFUSE RATHER THAN METER. A position's composition changes PASSIVELY as the price moves through it, with no
    /// callback at any point, so metering the add and the remove only sees the endpoints -- and it would have to cover
    /// partial removes, fee-only removes, adds that deposit coin, and the ERC-6909 leg, for a window that lasts minutes
    /// to hours. Refusing is one check and closes the whole class, including variants nobody has thought of yet. A
    /// launch's liquidity is the LP locker's; third-party LPs during an anti-sniper window are not a feature anyone
    /// needs, and allowing them is precisely what creates the route. Once `maxWalletUntil` lapses the pool is open to
    /// any LP, for ever, with no further check.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        // Unconfigured pools cannot exist behind this hook (beforeInitialize refuses them), but stay defensive.
        if (c.configured && !isLpProvider[sender] && !isLauncher[sender]) {
            // Round 16 (F-1): ONE question, answered in one place. A single-sided limit-order range dodges a max
            // wallet, a max buy and a launch tax equally well -- it fills from ordinary flow with no swap by its
            // owner, so neither the per-transaction buy meter nor the decaying tax ever runs. See
            // {_liquidityLockedUntil} for why each guard contributes the window it does.
            address coin = Currency.unwrap(c.quoteIsC0 ? key.currency1 : key.currency0);
            if (block.timestamp < _liquidityLockedUntil(c, coin)) revert LiquidityLockedDuringMaxWallet();
        }
        return this.beforeAddLiquidity.selector;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (!isLauncher[sender]) revert NotLauncher();
        _shape(key, sender); // validates shape + that one side is sender's coin
        return this.beforeInitialize.selector;
    }

    /// @dev The quote currency this pool taxes on (currency0 or currency1) as a Currency + its BalanceDelta side.
    function _quoteCurrency(PoolKey calldata key, bool quoteIsC0) internal pure returns (Currency) {
        return quoteIsC0 ? key.currency0 : key.currency1;
    }

    /// @dev Skims the quote-token tax when the QUOTE is the SPECIFIED currency of the swap.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireTradingOpen(id, c, sender);

        bool c0Specified = (params.zeroForOne == (params.amountSpecified < 0));
        bool quoteSpecified = c.quoteIsC0 ? c0Specified : !c0Specified;
        if (!quoteSpecified) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amt = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _taxOn(c, params.zeroForOne, amt);
        if (fee == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _quoteCurrency(key, c.quoteIsC0).take(poolManager, address(this), fee, true);
        accruedQuote[id] += fee;
        accruedPlatformQuote[id] +=
            _platformCutOn(id, c, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, amt);
        emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Skims the quote-token tax when the QUOTE is the UNSPECIFIED currency of the swap.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external onlyPoolManager returns (bytes4, int128)
    {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        // The coin is the non-quote currency; a positive delta there is coin leaving the pool (a buy).
        _requireUnderMaxBuy(
            id, c, sender, c.quoteIsC0 ? delta.amount1() : delta.amount0(),
            Currency.unwrap(c.quoteIsC0 ? key.currency1 : key.currency0)
        );

        int128 feeReturn = 0;
        uint256 swapTax;                 // observational only, for {SwapObserved}
        bool c0Specified = (params.zeroForOne == (params.amountSpecified < 0));
        bool quoteUnspecified = c.quoteIsC0 ? !c0Specified : c0Specified;
        if (quoteUnspecified) {
            int128 qDelta = c.quoteIsC0 ? delta.amount0() : delta.amount1();
            if (qDelta != 0) {
                uint256 amt = qDelta < 0 ? uint256(-int256(qDelta)) : uint256(int256(qDelta));
                uint256 fee = _taxOn(c, params.zeroForOne, amt);
                if (fee != 0) {
                    _quoteCurrency(key, c.quoteIsC0).take(poolManager, address(this), fee, true);
                    accruedQuote[id] += fee;
                    accruedPlatformQuote[id] +=
                        _platformCutOn(id, c, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, amt);
                    emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
                    feeReturn = fee.toInt128();
                    swapTax = fee;
                }
            }
        }
        // beforeSwap sized the fee against the requested amount, so check the rate against what actually traded.
        if (!quoteUnspecified) {
            uint256 requested = params.amountSpecified < 0
                ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 taken = _taxOn(c, params.zeroForOne, requested);
            if (taken != 0) {
                int128 moved = c.quoteIsC0 ? delta.amount0() : delta.amount1();
                uint256 filled = moved < 0 ? uint256(-int256(moved)) : uint256(int256(moved));
                // `filled` excludes the fee on exact-input and already includes it on exact-output.
                uint256 total = params.amountSpecified < 0 ? filled + taken : filled;
                // Reject a short fill charged above the ceiling. The ceiling uses hard constants (never the mutable
                // `maxSideBps`) so a later cap change cannot brick configured pools, and it is widened by the launch tax only
                // for buys on guarded pools, since only buys pay the launch premium. Shared with {launchBuyFee}.
                // AUDIT ROUND 14 (F-8): the widening must EXPIRE with the launch window. It used the raw
                // `launchTaxBps` for ever, so a year after launch a short fill could still clear an effective 30.9%
                // against an advertised 5% -- a guard band 47% looser on exactly the pools that advertised
                // anti-snipe protection, long after the tax that justified it had decayed to nothing.
                bool buySide = c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne;
                // Round 15 (F-1): the SAME clock {_effectiveBps} charges on. Anchoring this on `launchTime` while
                // the premium ran from `tradingOpensAt` made a fully-filled buy revert for the length of the delay.
                bool launchWindowLive = c.hasGuards && block.timestamp < _launchTaxEndsAt(c);
                uint256 ceilBps = _fillCeilBps(launchWindowLive && buySide ? c.guards.launchTaxBps : 0);
                if (taken * BPS > total * ceilBps) {
                    revert FillTooSmallForTax();
                }
                swapTax = taken;
            }
        }
        // Emitted before payouts. Buy direction depends on which currency is the quote.
        emit SwapObserved(
            id, sender, tx.origin, delta.amount0(), delta.amount1(),
            swapTax, params.amountSpecified < 0,
            c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne
        );
        {
            // The LARGEST tail seen in this transaction: a router swaps every hop before settling any, so an earlier hop's
            // dividend coin still needs its own post-swap transfer gas after a later pool's (smaller) in-swap work.
            uint256 t = _tailFor(key, c);
            if (t > _swapTail) _swapTail = t;
        }
        // Each step can be switched off globally by the admin ({setPausedSections}); a paused step simply does not
        // ride along with this trade, and its own deferral path picks the work up later.
        if (!sectionPaused(SECTION_AUTO_DISTRIBUTE)) _maybeAutoDistribute(id, c);
        // After the distribution, which is what credits {buybackPot}.
        if (!sectionPaused(SECTION_BUYBACK)) _maybeBuyback(key, id, c);
        if (!sectionPaused(SECTION_AUTO_LIQUIDITY)) _maybeAddLiquidity(key, id, c);
        if (!sectionPaused(SECTION_REFLECT)) _maybeReflect(key, id, c);
        if (!sectionPaused(SECTION_REWARDS)) _maybeRewardsStep(c);
        return (this.afterSwap.selector, feeReturn);
    }


    // In-swap conversions (buyback, liquidity, reflection) end with a `take` of the coin, which fails if the
    // PoolManager does not hold it yet (e.g. during a sell, before the router settles). The catch turns that into
    // a deferral: the pot is kept, and a later swap or the permissionless `run*` functions convert it.

    // ═══════════════════════════ BUYBACK-AND-BURN EXECUTION ═══════════════════════════════
    // A swap made by this hook skips its own hook callbacks (V4 `Hooks`), so the buyback is untaxed, cannot recurse
    // and is not subject to the launch guards.

    // Entry points derive the pool id from the key, so there is no key/id mismatch to check.

    /// @dev The buyback swap. External and self-only so {_maybeBuyback} can try/catch it (a revert is a deferral);
    /// {runBuyback} calls it directly so a revert reaches the caller.
    function buybackAndBurnSelf(PoolKey calldata key, uint256 amt)
        external
        returns (uint256 spent, uint256 burned)
    {
        if (msg.sender != address(this)) revert NotSelf();
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        bool quoteIsC0 = c.quoteIsC0;
        Currency qc = _quoteCurrency(key, quoteIsC0);
        Currency cc = quoteIsC0 ? key.currency1 : key.currency0;

        // Sell the quote for the coin, exact-input.
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsC0,
                amountSpecified: -int256(amt),
                // No slippage bound beyond the price extreme: any in-swap price source is manipulable, and the value at
                // stake is bounded by the pot.
                sqrtPriceLimitX96: quoteIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 qd = quoteIsC0 ? d.amount0() : d.amount1();
        int128 cd = quoteIsC0 ? d.amount1() : d.amount0();
        // Settle what the swap actually took, not the requested amount.
        if (qd < 0) {
            spent = uint256(uint128(-qd));
            qc.settle(poolManager, address(this), spent, false);
        }
        if (cd > 0) {
            burned = uint256(uint128(cd));
            // Straight to the sink; the coin never sits in this contract.
            poolManager.take(cc, BURN_SINK, burned);
        }
    }

    /// @dev The in-swap buyback attempt, after {_maybeAutoDistribute} credits the pot. Every failure (not enough gas,
    /// a revert) is a deferral: {buybackPot} is kept for the next swap or {runBuyback}.
    function _maybeBuyback(PoolKey calldata key, PoolId id, TaxConfig storage c) internal {
        uint256 pot = buybackPot[id];
        if (pot == 0 || c.buybackBps == 0) return;
        uint256 g = BUYBACK_CONVERT_GAS + _coinExtraGas(key, c);
        if (gasleft() < g + _tail()) {
            emit BuybackSkipped(id, pot, 0);
            return;
        }
        // Zeroed before the call and restored on failure, so a re-entrant read cannot spend the pot twice.
        buybackPot[id] = 0;
        try this.buybackAndBurnSelf{gas: g}(key, pot) returns (uint256 spent, uint256 burned) {
            // A short fill returns the unspent remainder to the pot.
            // AUDIT ROUND 12 (Low): `+=`, not `=`. The pot is zeroed before the call, so any credit booked WHILE
            // the call runs -- a nested swap on this pool reaching `buybackPot[id] += toBuyback` in the fee split --
            // is sitting in the slot when we return. Assigning would overwrite it and strand that quote for good
            // (`rescue` refuses pool assets). The LP sites have always used `+=`; these two had not.
            if (spent < pot) buybackPot[id] += pot - spent;
            emit BuybackExecuted(id, spent, burned);
        } catch {
            buybackPot[id] += pot; // round 12 (Low): see the note above -- never overwrite a nested credit
            emit BuybackSkipped(id, pot, 1);
        }
    }


    // ═══════════════════════════ AUTO-LIQUIDITY EXECUTION ═════════════════════════════════
    // The position is owned by this hook, which has no path to remove liquidity, so it is permanently locked.
    // One fixed full-range position per pool (salt 0); each add also harvests the fees it has earned.

    /// @dev The add itself. External and self-only so {_maybeAddLiquidity} can try/catch it; {runAddLiquidity}
    /// calls it directly.
    function addLiquiditySelf(PoolKey calldata key, uint256 amt)
        external
        returns (uint256 spentQuote, uint128 liquidityAdded)
    {
        if (msg.sender != address(this)) revert NotSelf();
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        bool quoteIsC0 = c.quoteIsC0;
        Currency qc = _quoteCurrency(key, quoteIsC0);
        Currency cc = quoteIsC0 ? key.currency1 : key.currency0;

        // ── 1. half the pot buys coin, so the add has both sides ──
        uint256 half = amt / 2;
        if (half == 0) revert NothingToAddLiquidity();
        BalanceDelta sd = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsC0,
                amountSpecified: -int256(half),
                // Price extreme, for the reason {buybackAndBurnSelf} gives.
                sqrtPriceLimitX96: quoteIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 sq = quoteIsC0 ? sd.amount0() : sd.amount1();
        int128 sc = quoteIsC0 ? sd.amount1() : sd.amount0();
        uint256 coinBought = sc > 0 ? uint256(uint128(sc)) : 0;
        if (coinBought == 0) revert NothingToAddLiquidity();

        // ── 2. size the add from what we ACTUALLY hold, at the post-swap price ──
        uint256 quoteLeft = amt - (sq < 0 ? uint256(uint128(-sq)) : 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        int24 spacing = key.tickSpacing;
        int24 lower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 upper = (TickMath.MAX_TICK / spacing) * spacing;
        uint128 liq = RealmAnyPairsLiquidityMath.liquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            quoteIsC0 ? quoteLeft : coinBought,
            quoteIsC0 ? coinBought : quoteLeft
        );
        // 1 bp haircut: liquidity math floors but the charge rounds up, so sizing to the last wei would ask for
        // slightly more than the hook holds. Leftovers go back to the pot (quote) or the sink (coin).
        liq = uint128((uint256(liq) * 9_999) / 10_000);
        if (liq == 0) revert NothingToAddLiquidity();

        (BalanceDelta md,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: 0}),
            ""
        );
        liquidityAdded = liq;

        // ── 3. NET the two operations, then settle only the residual ──
        // The swap left a positive coin delta (not a balance) that the add's negative delta cancels; the add's delta
        // is also net of fees the position earned.
        int128 mq = quoteIsC0 ? md.amount0() : md.amount1();
        int128 mc = quoteIsC0 ? md.amount1() : md.amount0();
        int256 netQ = int256(sq) + int256(mq);
        int256 netC = int256(sc) + int256(mc);

        if (netQ < 0) {
            qc.settle(poolManager, address(this), uint256(-netQ), false);
        } else if (netQ > 0) {
            // Leftover quote AND the quote-side fees this hook's own full-range position earned. AUDIT ROUND 8
            // (informational): these used to land on the hook with no accumulator, and {rescue} refuses pool
            // assets, so they could never reach anyone. They go back into the LP pot -- the pot the operation
            // came out of, the one programme the position belongs to -- so the next add re-deploys them. No new
            // withdrawal surface, and no accounting anywhere else has to learn about them. (The coin side
            // already goes to {BURN_SINK}, which credits every holder.)
            poolManager.take(qc, address(this), uint256(netQ));
            lpPot[id] += uint256(netQ);
            emit AutoLiquidityFeesRecycled(id, uint256(netQ));
        }
        if (netC < 0) {
            cc.settle(poolManager, address(this), uint256(-netC), false);
        } else if (netC > 0) {
            // Leftover coin and returned fees go to the burn sink; this contract has no sweep.
            poolManager.take(cc, BURN_SINK, uint256(netC));
        }

        // What the pot actually paid is the NET quote that left, never the nominal request.
        spentQuote = netQ < 0 ? uint256(-netQ) : 0;
        if (spentQuote > amt) spentQuote = amt;
    }

    /// @dev In-swap attempt, mirroring {_maybeBuyback}: gas-gated, pot zeroed before the call, restored on failure.
    function _maybeAddLiquidity(PoolKey calldata key, PoolId id, TaxConfig storage c) internal {
        uint256 pot = lpPot[id];
        if (pot == 0 || c.lpBps == 0) return;
        uint256 g = LP_CONVERT_GAS + _coinExtraGas(key, c);
        if (gasleft() < g + _tail()) {
            emit AutoLiquiditySkipped(id, pot, 0);
            return;
        }
        lpPot[id] = 0;
        try this.addLiquiditySelf{gas: g}(key, pot) returns (uint256 spent, uint128 liq) {
            // ADD, never assign: {addLiquiditySelf} may have credited recycled fees to the pot already.
            if (spent < pot) lpPot[id] += pot - spent;
            emit AutoLiquidityAdded(id, spent, liq);
        } catch {
            // AUDIT ROUND 17: `+=`, matching every other restore in this file (round 12's rule: never overwrite a
            // nested credit). On this branch the two are provably equal -- a revert unwinds the whole
            // `addLiquiditySelf` frame, nested credits included, so the slot still holds the zero written above --
            // but the rule does not depend on that argument holding at the next edit, and a reader should not have
            // to reconstruct it to know this site is safe.
            lpPot[id] += pot;
            emit AutoLiquiditySkipped(id, pot, 1);
        }
    }

    /// @notice Add this pool's accrued auto-liquidity now.
    /// @dev Permissionless, so a pot never strands on a pool that stopped trading.
    function runAddLiquidity(PoolKey calldata key)
        external
        nonReentrant
        returns (uint256 spent, uint128 liquidityAdded)
    {
        PoolId id = key.toId();
        if (!_config[id].configured) revert NotConfigured();
        uint256 pot = lpPot[id];
        if (pot == 0) revert NothingToAddLiquidity();
        lpPot[id] = 0;
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_ADDLIQ, key, pot));
        (spent, liquidityAdded) = abi.decode(ret, (uint256, uint128));
        // ADD, never assign: the add may have credited recycled fees to the pot already.
        if (spent < pot) lpPot[id] += pot - spent;
        emit AutoLiquidityAdded(id, spent, liquidityAdded);
    }


    // ═══════════════════════════ REFLECTIONS EXECUTION ════════════════════════════════════
    // Like the buyback, but the coin goes to the rewards tracker, which books its own measured balance increase.

    /// @dev Self-only so {_maybeReflect} can wrap it in a try/catch; called directly by {runReflect}.
    function reflectSelf(PoolKey calldata key, uint256 amt)
        external
        returns (uint256 spent, uint256 coinToHolders)
    {
        if (msg.sender != address(this)) revert NotSelf();
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        address tracker = c.rewardsTracker;
        if (tracker == address(0)) revert NothingToReflect();
        bool quoteIsC0 = c.quoteIsC0;
        Currency qc = _quoteCurrency(key, quoteIsC0);
        Currency cc = quoteIsC0 ? key.currency1 : key.currency0;

        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsC0,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: quoteIsC0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 qd = quoteIsC0 ? d.amount0() : d.amount1();
        int128 cd = quoteIsC0 ? d.amount1() : d.amount0();
        if (qd < 0) {
            spent = uint256(uint128(-qd));
            qc.settle(poolManager, address(this), spent, false);
        }
        if (cd > 0) {
            coinToHolders = uint256(uint128(cd));
            // Straight to the tracker; the coin never rests in this contract.
            poolManager.take(cc, tracker, coinToHolders);
            // The argument is ignored; the tracker measures what actually arrived.
            IDividendFeederToken(tracker).feedToken(0);
        }
    }

    /// @dev The in-swap attempt. Mirrors {_maybeBuyback}; every failure is a deferral.
    function _maybeReflect(PoolKey calldata key, PoolId id, TaxConfig storage c) internal {
        uint256 pot = reflectPot[id];
        if (pot == 0) return;
        uint256 g = REFLECT_CONVERT_GAS + _coinExtraGas(key, c);
        if (gasleft() < g + _tail()) {
            emit ReflectionSkipped(id, pot, 0);
            return;
        }
        reflectPot[id] = 0;
        try this.reflectSelf{gas: g}(key, pot) returns (uint256 spent, uint256 coin) {
            // Round 12 (Low): `+=` for the same reason as the buyback path above -- a nested swap can credit
            // `reflectPot[id]` while `reflectSelf` runs, and assigning would overwrite it.
            if (spent < pot) reflectPot[id] += pot - spent;
            emit ReflectionPaid(id, spent, coin);
        } catch {
            reflectPot[id] += pot; // round 12 (Low): never overwrite a nested credit
            emit ReflectionSkipped(id, pot, 1);
        }
    }

    /// @dev The post-swap rewards step. An auto-converting tracker converts one buffered leg (or pushes, with nothing to
    /// convert); any other tracker pushes accrued rewards to holders (`process`). Low-level, gas-capped and prechecked
    /// against {_tail}, so neither a revert, a hostile return nor the gas it burns can affect the swap or a later
    /// transfer. The trackers keep their own in-swap guards (in-swap registry, codeless-only ETH, no open delta/`sync`).
    function _maybeRewardsStep(TaxConfig storage c) internal {
        address t = c.rewardsTracker;
        if (t == address(0)) return;
        if (gasleft() < REWARD_CONVERT_GAS + _tail()) return;
        (bool ok,) = t.call{gas: REWARD_CONVERT_GAS}(
            c.rewardsAutoConvert
                ? abi.encodeWithSignature("convertStep()")
                : abi.encodeWithSignature("process(uint256)", REWARD_CONVERT_GAS)
        );
        ok; // failure is a deferral: the buffer or the accrual stays for the next swap, a claim or a manual call
    }

    /// @notice Convert this pool's accrued reflection slice into coin and book it for holders now.
    /// @dev Permissionless and uncapped, like {runBuyback} and {runAddLiquidity}.
    function runReflect(PoolKey calldata key) external nonReentrant returns (uint256 spent, uint256 coin) {
        PoolId id = key.toId();
        if (!_config[id].configured) revert NotConfigured();
        uint256 pot = reflectPot[id];
        if (pot == 0) revert NothingToReflect();
        reflectPot[id] = 0;
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_REFLECT, key, pot));
        (spent, coin) = abi.decode(ret, (uint256, uint256));
        // AUDIT ROUND 17: `+=`, for the round-12 reason the in-swap twin above already carries. The pot is zeroed
        // before the unlock, so anything credited to it WHILE the unlock runs -- a nested swap on this pool reaching
        // `reflectPot[id] += toRewards` in the fee split -- would be sitting in the slot on return, and assigning
        // would overwrite it and strand that quote for good (`rescue` refuses pool assets).
        //
        // AUDIT ROUND 18 -- WHY `+=` RATHER THAN `=`, stated accurately. Today that credit CANNOT happen, and an
        // earlier revision of this note gave a reason that does not exist ("`nonReentrant` guards this entry point,
        // not the `afterSwap` callback the PoolManager makes during the unlock"). No such callback is made:
        // {reflectSelf} calls `poolManager.swap` AS THE HOOK on the hook's own pool, and v4-core's
        // `Hooks.beforeSwap`/`Hooks.afterSwap` both open with `if (msg.sender == address(self)) return ...`
        // (lib/v4-core/src/libraries/Hooks.sol:253 and :293), so the hook is never called back during its own
        // unlock. Belt and braces: `reflectPot[id] += toRewards` lives only in {_distribute}, which a swap can reach
        // only through `this.autoDistribute{gas}` -- and {autoDistribute} IS `nonReentrant`, so it would revert into
        // a caught deferral rather than credit the slot.
        //
        // The door is therefore shut twice over, and `+=` is kept anyway because it is the UNIFORM RULE across all
        // six sibling restore sites in this file (round 12: never overwrite a nested credit). Where nothing credited
        // the slot it still holds the zero written above, so `+=` and `=` are identical -- `+=` costs nothing, and it
        // is the one of the two that stays correct the moment either of those two guarantees changes.
        if (spent < pot) reflectPot[id] += pot - spent;
        emit ReflectionPaid(id, spent, coin);
    }

    /// @notice True when this pool's holder rewards are paid in the COIN rather than the quote.
    function rewardsInCoinOf(PoolId id) external view returns (bool) {
        return _config[id].rewardsInCoin;
    }

    /// @notice This pool's auto-liquidity slice, in bps of the creator pool.
    function lpBpsOf(PoolId id) external view returns (uint16) {
        return _config[id].lpBps;
    }

    /// @notice This pool's buyback slice, in bps of the creator pool.
    /// @dev A separate getter so {config}'s positional tuple stays unchanged.
    function buybackBpsOf(PoolId id) external view returns (uint16) {
        return _config[id].buybackBps;
    }

    /// @notice Spend this pool's buyback pot now: buy the coin and send it to {BURN_SINK}.
    /// @dev Permissionless, so a pot never strands on an idle pool. Reverts on failure instead of deferring.
    function runBuyback(PoolKey calldata key) external nonReentrant returns (uint256 spent, uint256 burned) {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        uint256 pot = buybackPot[id];
        if (pot == 0) revert NothingToBuyBack();
        buybackPot[id] = 0;
        // Off-swap the PoolManager is locked, so the work runs inside an unlock.
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_BUYBACK, key, pot));
        (spent, burned) = abi.decode(ret, (uint256, uint256));
        // AUDIT ROUND 17: `+=`, for the round-12 reason -- see the identical note in {runReflect} and the in-swap
        // twin in {_maybeBuyback}. Never overwrite a credit booked during the unlock.
        if (spent < pot) buybackPot[id] += pot - spent;
        emit BuybackExecuted(id, spent, burned);
    }

    /// @dev The tax on `amount` at an explicit rate, floored.
    function _taxAt(uint256 bps, uint256 amount) internal pure returns (uint256) {
        if (bps == 0 || amount == 0) return 0;
        return FullMath.mulDiv(amount, bps * 100, FEE_DENOM);
    }

    /// @dev The platform's slice of the fee on `amount`, priced at the rate actually charged this swap (launch premium
    /// included). Always `<= _taxOn(...)`; rounding remainders stay on the creator side.
    function _platformCutOn(PoolId id, TaxConfig storage c, bool isBuy, uint256 amount)
        internal
        view
        returns (uint256)
    {
        id; // retained in the signature so every call site reads unchanged
        return _taxAt(_platformBps(c, _totalBps(c, _effectiveBps(c, isBuy))), amount);
    }

    /// @dev The total fee the trader pays: the effective creator rate, never below the pool's platform floor. A 0% coin
    /// still pays the floor.
    function _taxOn(TaxConfig storage c, bool zeroForOne, uint256 amount) internal view returns (uint256) {
        bool isBuy = c.quoteIsC0 ? zeroForOne : !zeroForOne;
        return _feeAtTotalBps(_totalBps(c, _effectiveBps(c, isBuy)), amount);
    }

    /// @dev The fee formula on a resolved total. Shared by {_taxOn} and {launchBuyFee} so the dev-buy quote matches
    /// what a swap is charged.
    function _feeAtTotalBps(uint256 totalBps, uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return FullMath.mulDiv(amount, totalBps * 100, FEE_DENOM);
    }

    /// @dev afterSwap's {FillTooSmallForTax} ceiling, in bps of the total. `launchTaxBps` must be passed as 0 unless
    /// the pool is guarded AND the swap is a buy -- the buys-only premium may widen only the buyer's bound.
    function _fillCeilBps(uint16 launchTaxBps) internal pure returns (uint256 ceilBps) {
        ceilBps = uint256(FILL_TOLERANCE_BPS) + FILL_PLATFORM_HEADROOM_BPS;
        uint256 ramp = uint256(launchTaxBps) + FILL_PLATFORM_HEADROOM_BPS;
        if (ramp > ceilBps) ceilBps = ramp;
    }

    /// @dev The launch-tax parameter rule, shared by {_guardsFor} (configurePool) and {launchBuyFee}.
    function _requireLaunchTaxOk(uint16 launchTaxBps, uint16 launchTaxSecs) internal pure {
        if ((launchTaxBps == 0) != (launchTaxSecs == 0)) revert BadLaunchGuard();
        if (launchTaxBps > MAX_LAUNCH_TAX_BPS || launchTaxSecs > MAX_LAUNCH_TAX_SECS) revert BadLaunchGuard();
    }

    /// @notice The fee the hook will charge a dev buy of `amount` quote in the LAUNCH TRANSACTION, and the
    /// {FillTooSmallForTax} ceiling that swap is checked against. Used by the launcher's `quoteDevBuy`.
    /// @dev At the launch instant `_effectiveBps` has `elapsed == 0`, so the rate is `buyBps` with no launch tax
    /// and `max(buyBps, launchTaxBps)` with one. Parameters are validated exactly as a launch validates them, so a
    /// combination that would make the launch revert makes this revert too.
    function launchBuyFee(uint16 buyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint256 amount)
        external
        view
        returns (uint256 fee, uint256 fillCeilBps)
    {
        _requireRatesOk(buyBps, buyBps);
        _requireLaunchTaxOk(launchTaxBps, launchTaxSecs);
        uint256 eff = launchTaxBps > buyBps ? launchTaxBps : buyBps;
        fee = _feeAtTotalBps(RealmAnyPairsFeeMath.totalBps(eff, platformFloorBps), amount);
        fillCeilBps = _fillCeilBps(launchTaxBps);
    }

    // ─────────────────────── distribution (Claim) ───────────────────────

    function distribute(PoolId id) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        uint256 amount = accruedQuote[id];
        if (amount == 0) revert NothingAccrued();
        uint256 plat = accruedPlatformQuote[id];
        accruedQuote[id] = 0;
        accruedPlatformQuote[id] = 0;
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, amount, plat, FLUSH_ALL));
    }

    /// @notice Settle and pay only the platform's accrued cut for `id`, leaving the creator side accrued.
    /// Permissionless; the money can only go to the platform side.
    /// @return settled The quote amount taken out of `accruedPlatformQuote` (0 if the call only drained a
    /// parked ring slot).
    function claimPlatform(PoolId id) external nonReentrant returns (uint256 settled) {
        // Revert only if nothing was settled and no parked platform slot was actually drained by this call.
        bool drained;
        (settled, drained) = _settlePlatform(id);
        if (settled == 0 && !drained) revert NothingAccrued();
    }

    /// @notice Claim the platform's cut across many pools in one transaction.
    /// @dev Each pool runs as a gas-metered self-call in try/catch, so one bad pool is skipped instead of reverting
    /// the batch or starving the pools behind it.
    /// @return paidPools How many pools actually settled something.
    /// @return skippedPools How many did not.
    function claimPlatformMany(PoolId[] calldata ids)
        external
        nonReentrant
        returns (uint256 paidPools, uint256 skippedPools)
    {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_CLAIM_BATCH) revert BadBatchLength();
        for (uint256 i; i < n; ++i) {
            // Stop before a forwarded call could exhaust the gas needed to finish; the returned counts show progress.
            if (gasleft() < CLAIM_ONE_GAS_CAP + CLAIM_BATCH_TAIL) break;
            // A drained parked slot paid the platform even with `amt == 0`, so it counts as paid, not skipped.
            try this.claimPlatformOne{gas: CLAIM_ONE_GAS_CAP}(ids[i]) returns (uint256 amt, bool drained) {
                if (amt != 0 || drained) {
                    unchecked { ++paidPools; }
                } else {
                    emit PlatformClaimSkipped(ids[i]);
                    unchecked { ++skippedPools; }
                }
            } catch {
                emit PlatformClaimSkipped(ids[i]);
                unchecked { ++skippedPools; }
            }
        }
    }

    /// @dev Self-only trampoline so {claimPlatformMany} can meter and catch each pool. Not `nonReentrant`: the batch
    /// already holds the guard.
    /// @return settled What came out of `accruedPlatformQuote`.
    /// @return drained Whether this call emptied a parked platform ring slot.
    function claimPlatformOne(PoolId id) external returns (uint256 settled, bool drained) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _settlePlatform(id);
    }

    /// @return plat what was settled out of `accruedPlatformQuote`.
    /// @return drained whether a parked platform ring slot was actually emptied (a walk short of gas leaves it parked).
    function _settlePlatform(PoolId id) internal returns (uint256 plat, bool drained) {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        plat = accruedPlatformQuote[id];
        uint256 acc = accruedQuote[id];
        // Defensive clamp; `plat <= acc` always holds.
        if (plat > acc) plat = acc;
        if (plat == 0) {
            // Nothing new to settle, but an earlier walk may have parked platform slices. Drain only those slots.
            if (pendingMask[id] & RING_PLATFORM != 0) {
                // Non-zero only if a platform slot was actually visited (pushed or credited to `owed[]`).
                drained = _runQueueMasked(id, c.quote, c.quote == address(0), RING_PLATFORM, false) != 0;
            }
            return (0, drained);
        }
        accruedPlatformQuote[id] = 0;
        accruedQuote[id] = acc - plat;
        // `amount == plat`, so {_distribute} computes `toPlatform == received` and `creatorPool == 0`.
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, plat, plat, FLUSH_PLATFORM));
        emit PlatformClaimed(id, c.quote, plat);
    }

    /// @notice Settle and pay ONLY the creator/rewards portion for `id`, leaving the platform's cut
    /// accrued and still claimable. Permissionless, like {distribute}.
    /// @dev The mirror of {claimPlatform}. `accruedQuote` is left holding exactly `accruedPlatformQuote`
    /// afterwards, so a later {claimPlatform} settles the identical figure it would have settled before.
    function claimCreator(PoolId id) external nonReentrant returns (uint256 settled) {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        uint256 acc = accruedQuote[id];
        uint256 plat = accruedPlatformQuote[id];
        if (plat > acc) plat = acc;
        settled = acc - plat;
        if (settled == 0) revert NothingAccrued();
        accruedQuote[id] = plat;
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, settled, 0, FLUSH_CREATOR));
    }

    /// @notice Claim your accrued fees for `token`. Paid in ETH when a quote→WETH path is configured, otherwise in the
    /// raw quote. `minWethOut` is the conversion's slippage floor; if it cannot be met the claim falls back to the raw
    /// quote. Pass 0 only if you accept that.
    /// @dev `owed[]` is paid nominally, first come first served; rebasing-down quotes are unsupported.
    function claim(address token, uint256 minWethOut) external nonReentrant returns (uint256 amountPaid, address tokenPaid) {
        return _claimTo(token, minWethOut, msg.sender);
    }

    /// @notice Pull your own accrued fees to another address. Only `msg.sender`'s balance is drained.
    /// @dev For payees that cannot receive directly (e.g. a contract with no receive path, or an address a
    /// compliance-gated quote froze). {Claimed} still names `msg.sender`.
    function claimTo(address token, uint256 minWethOut, address to)
        external
        nonReentrant
        returns (uint256 amountPaid, address tokenPaid)
    {
        if (to == address(0)) revert ZeroAddress();
        return _claimTo(token, minWethOut, to);
    }

    function _claimTo(address token, uint256 minWethOut, address to)
        internal
        returns (uint256 amountPaid, address tokenPaid)
    {
        // Body in {RealmAnyPairsSplitLib.claimTo} for size; DELEGATECALL preserves msg.sender and address(this).
        return RealmAnyPairsSplitLib.claimTo(owed, quoteToWethPath, token, minWethOut, to, weth, swapRouter);
    }


    /// @dev External-self-only so {claim} can try/catch the whole approve/swap/reset sequence. `minOut` is the router's
    /// `amountOutMinimum`, so a bad price reverts and {claim} falls back to the raw quote.
    function convertToWeth(address recipient, address token, bytes memory path, uint256 amount, uint256 minOut) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();
        // Body lives in the library for size; the self-only check stays here so the try has a real frame to cap and catch.
        return RealmAnyPairsSplitLib.swapToWeth(recipient, token, path, amount, minOut, swapRouter, weth);
    }

    /// @notice Deliver `who`'s accrued balance of `token` to `who`. Permissionless; funds can only go to `who`.
    /// @dev For contract payees that cannot call {claim} themselves (e.g. a dividend tracker, whose `sync()` then books
    /// the transfer). `owed[]` is paid nominally; rebasing-down quotes are unsupported.
    ///
    /// @dev ─── AUDIT ROUND 18: THE GAS COST OF THIS FUNCTION IS LOAD-BEARING. DO NOT MAKE IT MATERIALLY CHEAPER ───
    /// This is the CHEAPEST route by which this hook reaches `RealmAnyPairsDividendTracker.feed()`, and this hook is
    /// the only address that tracker accepts `feed()` from. That tracker's `feed()` is deliberately not
    /// `nonReentrant`, and during a paid poke the poker's fee sits there as an unbacked balance excess for the whole
    /// ring walk; a `feed()` re-entered from inside a recipient payout would book that fee as a dividend AND it would
    /// still be paid to the poker, leaving `reserve > balance` so honest claims revert.
    /// The ONLY thing preventing that is arithmetic: this call costs ~76,700 gas against the ~57,200 the tracker's
    /// `PUSH_GAS` (60,000) leaves inside a payout callback, so the re-entrant call OOGs and the frame unwinds.
    /// Shaving ~19,000 gas off this path -- or adding a cheaper hook->`feed()` route -- makes an insolvency bug live
    /// in a contract nobody edited. Before changing this path's cost, or adding another feed route, run:
    ///     forge test --match-test test_R18_TRIPWIRE --threads 1 -vv
    /// (`test/audit/R18PokeFeeRealHook.t.sol`); it measures both sides of the margin and fails if either closes it.
    /// See the matching note at `RealmAnyPairsDividendTracker.PUSH_GAS`.
    function pushOwed(address who, address token) external nonReentrant returns (uint256 amount) {
        // Contracts only: an EOA can call {claim} itself, and a third-party push would strip its choice of payout
        // asset.
        if (who.code.length == 0) revert NotAContract();
        // AUDIT ROUND 14 (F-9): a contract payee can OPT OUT. The EOA case is blocked precisely because a
        // third-party push strips the payee's choice -- raw quote, no `quoteToWethPath`, no `minWethOut` -- and a
        // contract payee has exactly the same interest. It stays permissionless by default (a sink that wants to be
        // pushed keeps working with no action), but a payee that would rather route its own claim can say so.
        if (noPush[who]) revert PushOptedOut();
        amount = owed[who][token];
        if (amount == 0) revert NothingAccrued();
        owed[who][token] = 0;
        // Native: try a plain send, then `feed{value:}` (the native tracker has no `receive`); if both fail the frame
        // reverts and the `owed` entry is restored. Native reports `amount` (all-or-nothing); ERC20 reports the measured
        // balance increase, so a fee-on-transfer quote is reported accurately.
        uint256 delivered;
        if (token == address(0)) {
            (bool ok,) = payable(who).call{value: amount}("");
            if (!ok) {
                try IDividendFeeder(who).feed{value: amount}() {}
                catch { revert EthTransferFailed(); }
            }
            delivered = amount;
        } else {
            // Saturating: a bare subtraction would revert a successful transfer if `who` ends with less.
            // AUDIT ROUND 15 (F-2, Medium). MEASURE THE SENDER'S DECREASE, not the recipient's increase. Round 14 added
            // a re-credit of `amount - delivered` with `delivered` read from the RECIPIENT's balance -- but this
            // contract's balance falls by what LEFT. On a fee-on-transfer quote those differ by the fee, so tokens that
            // genuinely left and can never be delivered went back on the ledger as a live claim. Repeat-claiming then
            // drew `A / (1 - f)` out of the hook per cycle: measured, an attacker owed 100e18 received 100e18 while
            // consuming 111.11e18, leaving the next payee's 100e18 entry backed by 88.89e18 and their claim reverting
            // until new income arrived. Permissionless, repeatable, no admin involved.
            //
            // The sender-side measurement is right in BOTH cases the re-credit exists for: `amount` for a fee-on-transfer
            // quote (a full, correct debit -- the fee is not ours to re-credit), and `0` for the soft-blocklist case
            // round 14 set out to fix (a full, correct re-credit). It is also immune to a recipient that moves its own
            // balance during the transfer, which is the same flaw with direct theft instead of grief for an ERC777/1363
            // quote with an attacker-chosen `to` -- and note the {InSwapRegistry} kill switch does NOT cover the pull
            // ledger, so nothing else was standing behind this.
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(who, amount);
            uint256 aft = IERC20(token).balanceOf(address(this));
            delivered = before > aft ? before - aft : 0;
            // AUDIT ROUND 14 (F-5): RE-CREDIT what never left. The ledger is zeroed up front, so a token that
            // reports success while moving nothing -- a soft blocklist -- would destroy the credit permanently, and
            // the hook's `rescue` refuses pool assets, so nothing could recover it.
            if (delivered < amount) owed[who][token] += amount - delivered;
        }
        // The ledger debit is only what actually arrived; any shortfall is back on the ledger above.
        emit Claimed(who, token, delivered);
        amount = delivered;
    }

    /// @dev Accepts native ETH from the PoolManager only (native `take`s). Any other ETH would be unbacked and stuck.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // The leading op selects the payload shape. Only this contract's own unlocks reach here, so an unknown op reverts.
        uint8 op = abi.decode(data[:32], (uint8));
        if (op == UNLOCK_BUYBACK) {
            (, PoolKey memory key, uint256 amt) = abi.decode(data, (uint8, PoolKey, uint256));
            (uint256 spent, uint256 burned) = this.buybackAndBurnSelf(key, amt);
            return abi.encode(spent, burned);
        }
        if (op == UNLOCK_ADDLIQ) {
            (, PoolKey memory key, uint256 amt) = abi.decode(data, (uint8, PoolKey, uint256));
            (uint256 spent, uint128 liq) = this.addLiquiditySelf(key, amt);
            return abi.encode(spent, liq);
        }
        if (op == UNLOCK_REFLECT) {
            (, PoolKey memory key, uint256 amt) = abi.decode(data, (uint8, PoolKey, uint256));
            (uint256 spent, uint256 coin) = this.reflectSelf(key, amt);
            return abi.encode(spent, coin);
        }
        (, PoolId id, uint256 amount, uint256 plat, uint8 mode) =
            abi.decode(data, (uint8, PoolId, uint256, uint256, uint8));
        _distribute(id, amount, plat, mode);
        return "";
    }

    /// @dev This hook's balance of `quote` (native balance for `address(0)`), for balance-delta re-measurement.
    function _selfBalance(address quote) internal view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    /// @dev Redeem `amount` of the pool's accrued quote-token claim for real quote tokens and split it.
    function _distribute(PoolId id, uint256 amount, uint256 plat, uint8 mode) internal {
        TaxConfig storage c = _config[id];
        address quote = c.quote;
        // Selects native vs ERC20 gas budgets for the payouts below.
        bool native = quote == address(0);
        Currency qc = Currency.wrap(quote);

        qc.settle(poolManager, address(this), amount, true);
        // Re-measure what actually arrived, so a fee-on-transfer quote never credits more than the hook holds.
        uint256 balBefore = _selfBalance(quote);
        poolManager.take(qc, address(this), amount);
        // Saturating, in case the hook ends holding less than it started with.
        uint256 balAfter = _selfBalance(quote);
        uint256 received = balAfter > balBefore ? balAfter - balBefore : 0;
        // Never credit more than was taken, whatever else landed on the hook during the take (audit round 8,
        // informational). Attacker-negative today, but the clamp removes the class.
        if (received > amount) received = amount;
        // Revert rather than return: callers have already zeroed the accrual, and reverting restores it (e.g. a frozen
        // quote whose transfer silently does nothing).
        if (received == 0) revert NothingAccrued();

        // Scale the platform's cut by what actually arrived, sharing any transfer fee proportionally.
        uint256 toPlatform = amount == 0 ? 0 : plat * received / amount;
        amount = received;
        if (toPlatform > amount) toPlatform = amount;
        uint256 creatorPool = amount - toPlatform;
        // Every slice is a share of the same base, snapshotted before any is taken. Slices floor, so rounding
        // remainders stay with the creator; each is also clamped to what remains.
        uint256 sliceBase = creatorPool;

        // ── divide now, push as gas allows ──
        // Each slice is booked to its payee's ring slot, then {_runQueue} pushes what `gasleft()` affords; the rest
        // waits for a later swap, {runPayouts} or the pull ledger.
        if (toPlatform > 0) {
            // Book the platform cut to the ring for in-swap push; failures credit `owed[]` and emit {FeeCutPaid}.
            // Round 9: {SECTION_PLATFORM_SEND} sends it straight to the pull ledger instead -- the platform-side twin
            // of {SECTION_AUTO_SEND}. Same money, same payee, just not pushed during someone's trade.
            // Round 12: the platform now receives the WHOLE of `toPlatform`. The referral slice used to be carved out
            // of this same number, so removing it changes nothing the trader pays and leaves nothing unassigned.
            bool pushPlat = !sectionPaused(SECTION_PLATFORM_SEND);
            if (pushPlat) _bookSlot(id, PAY_SLOT_PLATFORM, platform, quote, toPlatform);
            else owed[platform][quote] += toPlatform;
        }

        // FLUSH_PLATFORM leaves `creatorPool` at 0; skip the creator side so a large split is never walked for nothing.
        if (mode != FLUSH_PLATFORM) {
        address tracker = c.rewardsTracker;
        if (tracker != address(0) && c.rewardsBps != 0 && creatorPool != 0) {
            uint256 toRewards = sliceBase * c.rewardsBps / BPS;
            if (toRewards > creatorPool) toRewards = creatorPool;
            if (toRewards != 0) {
                creatorPool -= toRewards;
                if (c.rewardsInCoin) {
                    // Coin-paid rewards cannot go through the quote ring; accrue for {_maybeReflect} instead.
                    reflectPot[id] += toRewards;
                    emit ReflectionAccrued(id, toRewards);
                } else {
                    _bookSlot(id, PAY_SLOT_REWARDS, tracker, quote, toRewards);
                }
            }
        }

        // ── buyback-and-burn, carved from the SAME creatorPool as the rewards slice ──
        // Booked to a pot, not executed here: off-swap callers have no PoolKey. Drained by {_maybeBuyback} or {runBuyback}.
        if (mode != FLUSH_PLATFORM && c.buybackBps != 0 && creatorPool != 0) {
            uint256 toBuyback = sliceBase * c.buybackBps / BPS;
            if (toBuyback > creatorPool) toBuyback = creatorPool;
            if (toBuyback != 0) {
                creatorPool -= toBuyback;
                buybackPot[id] += toBuyback;
                emit BuybackAccrued(id, toBuyback);
            }
        }

        // ── auto-liquidity, carved from the SAME creatorPool, after the buyback slice ──
        if (mode != FLUSH_PLATFORM && c.lpBps != 0 && creatorPool != 0) {
            uint256 toLp = sliceBase * c.lpBps / BPS;
            if (toLp > creatorPool) toLp = creatorPool;
            if (toLp != 0) {
                creatorPool -= toLp;
                lpPot[id] += toLp;
                emit AutoLiquidityAccrued(id, toLp);
            }
        }

        // Round 9: the global brake forces the pull ledger, exactly as `autoSend == false` does. Nothing is lost --
        // the share is booked to `owed[]` and stays claimable.
        bool push = c.autoSend && !sectionPaused(SECTION_AUTO_SEND);
        RealmAnyPairsSplitLib.Split[] storage sp = creatorSplits[id];
        if (sp.length == 0) {
            // Split-less pool: the creator IS split slot 0, at ring index PAY_SLOT_SPLIT_BASE.
            if (creatorPool > 0) {
                if (push) _bookSlot(id, PAY_SLOT_SPLIT_BASE, c.creator, quote, creatorPool);
                else owed[c.creator][quote] += creatorPool;
            }
        } else {
            uint256 rem = creatorPool;
            uint256 last = sp.length - 1;
            for (uint256 i; i <= last; i++) {
                uint256 part = i == last ? rem : (creatorPool * sp[i].bps) / BPS;
                rem -= part;
                if (part > 0) {
                    // Pull-mode pools book straight to `owed[]`.
                    if (push) _bookSlot(id, PAY_SLOT_SPLIT_BASE + i, sp[i].to, quote, part);
                    else owed[sp[i].to][quote] += part;
                }
            }
        }

        }

        emit TaxDistributed(id, creatorPool, toPlatform);
        // A platform-only flush walks only platform slots and leaves the cursor alone, so a hostile creator recipient
        // cannot interfere and platform sweeps cannot drive the creator ring's rotation.
        if (mode == FLUSH_PLATFORM) _runQueueMasked(id, quote, native, RING_PLATFORM, false);
        else if (mode == FLUSH_CREATOR) _runQueueMasked(id, quote, native, RING_CREATOR, true);
        else _runQueue(id, quote, native);
    }

    /// @dev Assign `amt` of `quote` in ring slot `i` to `to`, for a later push. Anything that cannot use the slot is
    /// booked to `owed[]` instead, so nothing is lost.
    function _bookSlot(PoolId id, uint256 i, address to, address quote, uint256 amt) internal {
        if (amt == 0) return;
        PaySlot storage sl = _paySlots[id][i];
        uint256 cur = sl.amt;
        address prev = sl.to;
        // A different payee is still parked here (split rewritten or creator changed): evict them to the pull ledger.
        if (cur != 0 && prev != to) {
            owed[prev][quote] += cur;
            cur = 0;
        }
        uint256 sum = cur + amt;
        // Amounts beyond uint96 go straight to the pull ledger rather than truncating.
        if (sum > type(uint96).max) {
            owed[to][quote] += sum - type(uint96).max;
            sum = type(uint96).max;
        }
        sl.to = to;
        sl.amt = uint96(sum);
        pendingMask[id] |= uint32(1 << i);
    }

    /// @notice Push as much of `id`'s payout ring as `gasleft()` affords, resuming from the cursor. Unreached slots
    /// stay booked for a later walk.
    /// @dev Clears each slot before its external call (CEI). A slot the budget cannot afford is skipped and the cursor
    /// parked on it, so one expensive payee never blocks cheaper ones. Cannot revert: every payment is a try-isolated
    /// self-call, a raw call, or an `owed[]` credit.
    /// @return pushed how many payees were actually paid on this walk.
    function _runQueue(PoolId id, address quote, bool native) internal returns (uint256 pushed) {
        return _runQueueMasked(id, quote, native, RING_ALL, true);
    }

    /// @dev The walk itself. `filter` restricts it to part of the ring (see {RING_PLATFORM}); `moveCursor` is false
    /// only for platform-only walks, which must not perturb the creator ring's rotation.
    function _runQueueMasked(PoolId id, address quote, bool native, uint32 filter, bool moveCursor)
        internal
        returns (uint256 pushed)
    {
        uint32 mask = pendingMask[id];
        if (mask & filter == 0) return 0;
        // Bits cleared by this walk, so the final store can be a masked update.
        uint32 cleared;
        uint256 start = payCursor[id];
        uint256 i = start;
        uint256 park = PAY_SLOTS;                     // PAY_SLOTS == "nothing was skipped"
        for (uint256 k; k < PAY_SLOTS; ++k) {
            if (mask & filter & uint32(1 << i) != 0) {
                // Only the rewards slot is a feed; the platform and split slots use the push floors. The swap tail is
                // already withheld by the caller's gas cap, so it is not charged again here.
                uint256 floorGas = i == PAY_SLOT_REWARDS
                    ? (native ? PAY_FLOOR_FEED_NATIVE : PAY_FLOOR_FEED_TOKEN)
                    : (native ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN);
                if (gasleft() < floorGas) {
                    if (park == PAY_SLOTS) park = i;  // remember the FIRST one we could not afford
                } else {
                    PaySlot storage sl = _paySlots[id][i];
                    address to = sl.to;
                    uint256 amt = sl.amt;
                    sl.to = address(0);               // CEI: clear before any external call
                    sl.amt = 0;
                    mask &= ~uint32(1 << i);
                    cleared |= uint32(1 << i);
                    if (i == PAY_SLOT_REWARDS) _payRewardsSlot(id, to, quote, amt, native);
                    else if (i == PAY_SLOT_PLATFORM) _payPlatformSlot(id, i, to, quote, amt);
                    else _payCreatorShare(to, quote, amt);
                    unchecked { ++pushed; }
                }
            }
            unchecked { i = i + 1 == PAY_SLOTS ? 0 : i + 1; }
        }
        // Masked update (`& ~cleared`), not an absolute write of the pre-call snapshot, so a bit set during the walk
        // is never lost.
        uint32 stored = pendingMask[id] & ~cleared;
        pendingMask[id] = stored;
        uint256 next = park == PAY_SLOTS ? i : park;  // `i` is back at `start` after a full lap
        if (!moveCursor) next = start;
        // The cursor is only a rotation hint, so an absolute write is fine.
        if (next != start) payCursor[id] = uint8(next);
        // Emit the stored mask, not the pre-call local.
        emit PayoutsProcessed(id, pushed, stored, uint8(next));
    }

    /// @dev Push for the platform-side slot ({PAY_SLOT_PLATFORM}). Native only to a codeless
    /// address AND only while the native quote is not denied; ERC20 only when {_inSwapAllowed}, through the capped
    /// {pushSplit}. Any failure credits `owed[to][quote]` in full; {FeeCutPaid} reports which happened.
    /// @dev AUDIT ROUND 10: the native branch now consults {_inSwapAllowed} too, with `address(0)` as the key. It
    /// never did, so a native-quote pool was the one coin type the kill switch could not reach.
    function _payPlatformSlot(PoolId id, uint256 slot, address to, address quote, uint256 amt) internal {
        if (quote == address(0)) {
            if (to.code.length == 0 && _inSwapAllowed(address(0))) {
                (bool ok,) = to.call{value: amt}("");
                if (ok) {
                    emit FeeCutPaid(id, to, quote, amt, uint8(slot), true);
                    return;
                }
            }
        } else if (_inSwapAllowed(quote)) {
            try this.pushSplit{gas: SPLIT_PUSH_LIVENESS_CAP}(to, quote, amt) returns (uint256 delivered) {
                // Round 15 (F-2): re-credit anything that did not leave this contract.
                if (delivered < amt) owed[to][quote] += amt - delivered;
                emit FeeCutPaid(id, to, quote, delivered, uint8(slot), true);
                return;
            } catch {}
        }
        owed[to][quote] += amt;
        emit FeeCutPaid(id, to, quote, amt, uint8(slot), false);
    }

    /// @dev Push for the rewards slot. On failure the slice is credited to the tracker, never the creator. The
    /// delivered amount is measured by {pushRewards} itself, inside the forwarded {FEED_GAS_CAP_TOKEN} budget and in
    /// the same frame as the transfer. Native needs no measurement: `feed{value:}` is the transfer.
    function _payRewardsSlot(PoolId id, address tracker, address quote, uint256 amt, bool native) internal {
        // AUDIT ROUND 14 (F-7): the rewards slot now consults the in-swap registry like the other two pushes. It was
        // the ONE push that ran a denied quote's code with a contract recipient during someone else's trade with no
        // way for the operator to switch it off, and the comment justifying the exemption was contradicted by this
        // function's own `owed[]` fallback -- the tracker can and does claim from the ledger, which is exactly what
        // the exemption claimed was impossible.
        //
        // AUDIT ROUND 17 (F-1): ...but round 14 gated the ERC20 branch ONLY (`!native && !_inSwapAllowed(quote)`),
        // so a native-quote pool was left as the one shape the kill switch could not reach on this slot -- the exact
        // hole round 10 closed on {_payPlatformSlot} and {_payCreatorShare}, reopened on the third push. The native
        // quote is a real key in {inSwapRegistry} (`address(0)`), so it is keyed the same way its two siblings key it.
        // `native` and `quote == address(0)` are the same predicate at the only call site; the ternary states the key
        // explicitly rather than relying on that.
        if (!_inSwapAllowed(native ? address(0) : quote)) {
            owed[tracker][quote] += amt;
            return;
        }
        // AUDIT ROUND 14 (F-6): the balance reads must not be able to revert this frame. They sat in the outer frame
        // -- `before` ahead of the try, `aft` inside its success block -- so a quote whose `balanceOf` reverts for
        // this tracker specifically made `runPayouts` / `distribute` revert at slot 21 and unwind every payment
        // already made in that walk, stranding the platform's and the creator's booked slices. This function's
        // contract is that it cannot revert.
        //
        // Round 15 (F-2): measure THIS CONTRACT's decrease, not the tracker's increase, and re-credit any shortfall,
        // so a quote that returns true while moving nothing cannot consume the whole slice.
        //
        // AUDIT ROUND 17 (F-2): ONE MEASUREMENT RULE, used by both push paths. Round 14's fix for F-6 read the
        // balance through a 30,000-gas-capped `staticcall` in the OUTER frame and, when that read failed, reported
        // FULL DELIVERY with no verification -- on the grounds that crediting `owed[]` on an unmeasurable success
        // would pay twice. {pushSplit} solves the identical problem the opposite way, with an UNCAPPED `balanceOf`
        // in the same frame as the transfer, and {pushSplit} is right:
        //   * Measuring in the transfer's own frame makes "unmeasurable" and "not delivered" the SAME state. A read
        //     that reverts or runs out reverts the push, which reverts the transfer with it, so the outer catch's
        //     full `owed[]` credit is exactly correct and cannot double-pay. Nothing has to be assumed.
        //   * The cap was the defect, not the protection. A soft-blocklist quote whose `balanceOf` costs more than
        //     30,000 gas made the read fail while the transfer moved nothing -- the round-15 F-2 loss (a slice gone
        //     from the payee, from `owed[]`, from `accruedQuote` and from `rescue`, unrecoverable by anyone)
        //     surviving inside the branch added to fix it. Reporting a delivery you could not measure is precisely
        //     the failure mode that made F-2 unrecoverable, so no path reports one any more.
        // The reads move inside the forwarded budget; {FEED_GAS_CAP_TOKEN} is raised by {MEASURE_GAS_RESERVE} so the
        // tracker's `feedToken` budget is unchanged by the move. Native is unaffected and forwards its own cap.
        try this.pushRewards{gas: _feedGasCap(native)}(tracker, quote, amt) returns (uint256 delivered) {
            if (delivered > amt) delivered = amt;          // saturate; a hostile quote cannot inflate the event
            if (delivered < amt) owed[tracker][quote] += amt - delivered;
            emit RewardsRouted(id, tracker, delivered);
            return;
        } catch {}
        // Nothing was delivered, so the full `amt` is still owed to the tracker.
        owed[tracker][quote] += amt;
    }

    /// @notice Push whatever `id`'s payout ring can afford right now. Permissionless: money only goes to recorded payees.
    /// @dev Drains a ring funded by the final swap of an idle pool.
    function runPayouts(PoolId id) external nonReentrant returns (uint256 pushed) {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        return _runQueue(id, c.quote, c.quote == address(0));
    }

    /// @notice What ring slot `slot` of `id` still owes, and to whom. `to == address(0)` means empty.
    function pendingPayout(PoolId id, uint256 slot) external view returns (address to, uint256 amt) {
        PaySlot storage sl = _paySlots[id][slot];
        return (sl.to, sl.amt);
    }

    /// @notice Everything `id`'s ring still owes, summed. Informational; walks every ring slot.
    function pendingPayoutTotal(PoolId id) external view returns (uint256 total) {
        uint32 mask = pendingMask[id];
        for (uint256 i; i < PAY_SLOTS; ++i) {
            if (mask & uint32(1 << i) != 0) total += _paySlots[id][i].amt;
        }
    }

    /// @dev Transfer the rewards slice and let the tracker book its own measured increase. No amount is passed to the
    /// tracker, since a hostile quote could make any hook-side figure wrong.
    /// @return delivered what actually LEFT this contract, measured the same way {pushSplit} measures it.
    /// @dev AUDIT ROUND 17 (F-2). The measurement lives here, not in {_payRewardsSlot}, and uses a plain uncapped
    /// `balanceOf`: in this frame an unreadable balance reverts the push and therefore the transfer, so
    /// "unmeasurable" and "not delivered" are one state and the caller's full `owed[]` re-credit is always correct.
    /// The `aft` read is taken BEFORE the `feedToken` booking, so a tracker whose booking runs out of gas still keeps
    /// the quote (its permissionless `sync()` books it later) exactly as it did before, and so that a tracker moving
    /// the quote onward inside `feedToken` cannot be mistaken for a short delivery.
    function pushRewards(address tracker, address quote, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) revert OnlySelf();
        // Native: `feed{value:}` is both the transfer and the booking, so a failure reverts and {_payRewardsSlot}
        // credits the slice to `owed[tracker][address(0)]` for {pushOwed} to deliver. Nothing to measure.
        if (quote == address(0)) {
            IDividendFeeder(tracker).feed{value: amt}();
            return amt;
        }
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransfer(tracker, amt);
        uint256 aft = IERC20(quote).balanceOf(address(this));
        // Saturating: a quote that somehow returns value to this contract must not make a successful transfer revert.
        delivered = before > aft ? before - aft : 0;
        // Booking is best-effort; the transfer must stand. If `feedToken` fails (e.g. the tracker is reentrancy-locked)
        // the quote is already at the tracker, and its permissionless `sync()` books it later.
        try IDividendFeederToken(tracker).feedToken(0) {} catch {}   // arg ignored; the tracker measures itself
    }

    /// @dev Gas an in-swap distribution of `id` must have to be attempted: base + one booking per payee + the cheapest
    /// push floor + {SWAP_TAIL_RESERVE}. Further pushes are deferred, not lost. Keyed on the quote because native pushes
    /// are much cheaper. Buyback/LP pot writes are not reserved, so at the exact boundary a large pool may book
    /// without pushing.
    function _autoDistributeNeed(PoolId id, TaxConfig storage c) internal view returns (uint256 need) {
        bool native = c.quote == address(0);
        // Slots this distribution will book: one per split recipient (or the bare creator), plus rewards if set.
        uint256 slots = creatorSplits[id].length;
        if (slots == 0) slots = 1;
        // The platform slot is booked on every distribution. (Round 12: there is no referral slot any more.)
        ++slots;

        if (c.rewardsTracker != address(0) && c.rewardsBps != 0) ++slots;
        need = AUTO_DISTRIBUTE_BASE + slots * AUTO_DISTRIBUTE_PER_SPLIT + _tail();
        need += native ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN;
    }

    /// @notice Gas an in-swap auto-distribution of `id` reserves (redeem plus one payout), assuming the default tail. For
    /// a dividend coin prefer {autoDistributeGasNeed(PoolKey)}, which includes the coin's own post-swap transfer gas.
    function autoDistributeGasNeed(PoolId id) external view returns (uint256) {
        return _viewNeed(id, _config[id]);
    }

    /// @dev What a swap on `id` must carry for EVERY in-swap step the pool actually has configured to run.
    /// @dev AUDIT ROUND 9 (Low): this used to return `max(distribute, rewards)`. `afterSwap` runs the steps
    /// SEQUENTIALLY -- distribute, then buyback, then auto-liquidity, then reflect, then the rewards step -- each with
    /// its own precheck against the gas still left, so a wallet sized on the largest single term got the distribution
    /// and then skipped the rewards step, which is exactly the promise the view makes. Measured on a 3-leg pool: it
    /// returned 1,581,015, precisely the rewards term, with the distribution's own need unaccounted for. The terms are
    /// SUMMED now, over the steps that pool has configured, minus the tail that every term carries (it is reserved
    /// once, not once per step). A pool with nothing configured is unchanged.
    function _viewNeed(PoolId id, TaxConfig storage c) internal view returns (uint256 need) {
        need = _autoDistributeNeed(id, c); // already includes one tail
        if (c.rewardsTracker != address(0)) need += REWARD_CONVERT_GAS; // the rewards step, on top
        // The buyback / auto-liquidity / reflect steps share the distribution's own budget, so they add nothing here:
        // they run out of the pot the distribution books and are individually skippable without a failed call.
    }

    /// @notice {autoDistributeGasNeed(PoolId)} with the pool's real tail: the coin's balance-sync `minDebit` plus margin
    /// when that exceeds the default. Wallet estimates settle on the cheaper deferral path, so a frontend that wants
    /// in-swap payouts should add this to its estimate.
    function autoDistributeGasNeed(PoolKey calldata key) external view returns (uint256) {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        uint256 cur = _tail();
        uint256 t = _tailFor(key, c) + SWAP_HOP_GAS * SWAP_HOPS_COVERED;
        return _viewNeed(id, c) - cur + (t > cur ? t : cur);
    }

    /// @dev Per-swap payout step, in two independent parts: (1) redeem the pot if it is over the threshold, affordable
    /// and not latched; (2) otherwise still walk the ring so payees booked by earlier swaps get paid.
    function _maybeAutoDistribute(PoolId id, TaxConfig storage c) internal {
        if (!c.autoEnabled) return;
        uint256 acc = accruedQuote[id];
        // Skip the redeem while latched (no event; it would fire every swap). The ring walk below still runs.
        if (c.autoThreshold != 0 && acc >= c.autoThreshold && !c.autoRedeemLatched) {
            if (gasleft() >= _autoDistributeNeed(id, c)) {
                uint256 plat = accruedPlatformQuote[id];
                accruedQuote[id] = 0;
                accruedPlatformQuote[id] = 0;
                // {_distribute} walks the ring itself. The explicit gas cap withholds {SWAP_TAIL_RESERVE} so the swap can always
                // finish, and {AUTO_DISTRIBUTE_MAX} bounds the trader's cost. The precheck guarantees no underflow.
                uint256 payBudget = gasleft() - _tail();
                if (payBudget > AUTO_DISTRIBUTE_MAX) payBudget = AUTO_DISTRIBUTE_MAX;
                // Latch only if the attempt proves the pool can never redeem in-swap: it had the full ceiling (not a budget
                // clamped by a thin trade) AND spent at least AUTO_REDEEM_SPEND_NUM/DEN of it. A cheap revert, such as the
                // first buy of a pool before the router settles, must not latch.
                bool fullBudget = payBudget == AUTO_DISTRIBUTE_MAX;
                uint256 gasBefore = gasleft();
                try this.autoDistribute{gas: payBudget}(id, acc, plat) {} catch {
                    // Measured first in the catch, before the restores, so storage warmth does not skew it.
                    uint256 spent = gasBefore - gasleft();
                    emit AutoDistributeSkipped(id, acc);
                    // `+=`, not `=`: an absolute write would discard anything accrued inside the failed attempt. Do not weaken.
                    accruedQuote[id] += acc;
                    accruedPlatformQuote[id] += plat;
                    if (fullBudget && spent >= (payBudget * AUTO_REDEEM_SPEND_NUM) / AUTO_REDEEM_SPEND_DEN) {
                        c.autoRedeemLatched = true;
                        emit AutoRedeemLatched(id, acc);
                    }
                }
                return;
            }
            emit AutoDistributeSkipped(id, acc);
        }
        // No redeem this swap, but pay payees booked by earlier swaps. Goes through the external self-call for the
        // reentrancy guard, with the same withheld tail; below the floor the ring waits.
        uint256 walkFloor = _tail() + (c.quote == address(0) ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN);
        if (pendingMask[id] != 0 && gasleft() > walkFloor) {
            // Same bounds as the redeem path: the withheld tail and {AUTO_DISTRIBUTE_MAX}.
            uint256 walkBudget = gasleft() - _tail();
            if (walkBudget > AUTO_DISTRIBUTE_MAX) walkBudget = AUTO_DISTRIBUTE_MAX;
            try this.runPayouts{gas: walkBudget}(id) {} catch {}
        }
    }

    /// @dev `nonReentrant` is load-bearing: this is the only quote-moving entry point reachable from a swap, so a
    /// callback quote cannot re-enter a claim mid-distribution. A blocked re-entry makes {pushRewards} revert, and
    /// {_payRewardsSlot} credits the slice to `owed[tracker][quote]`.
    function autoDistribute(PoolId id, uint256 amount, uint256 plat) external nonReentrant {
        if (msg.sender != address(this)) revert OnlySelf();
        _distribute(id, amount, plat, FLUSH_ALL);
    }
    /// @dev Push one recipient's slice of the creator pool; on any failure fall back to the pull ledger, so a failed
    /// payout never fails the trade.
    /// @dev Safety does not rely on gas caps. Native pushes go only to codeless addresses (no code runs). ERC20 pushes
    /// run the token's code, so they are gated per quote by {inSwapRegistry} (a denylist: allowed unless denied). The
    /// quote's code also runs in `take` and the rewards transfer; `nonReentrant` and CEI on ring slots contain that.
    /// try/catch contains a reverting recipient, not one that leaves an unsettled delta.
    function _payCreatorShare(address to, address quote, uint256 amt) internal {
        // Native: gate on `to.code.length == 0`, not the registry; a value transfer to a codeless address runs no code.
        // Gas is uncapped, and a failed send returns false and falls through to the pull ledger.
        if (quote == address(0)) {
            // Round 10: the native quote is a real key in the registry, so this branch is gated too.
            if (to.code.length == 0 && _inSwapAllowed(address(0))) {
                (bool ok,) = to.call{value: amt}("");
                if (ok) {
                    emit CreatorSharePushed(to, quote, amt);
                    return;
                }
            }
        } else if (_inSwapAllowed(quote)) {
            try this.pushSplit{gas: SPLIT_PUSH_LIVENESS_CAP}(to, quote, amt) returns (uint256 delivered) {
                // Round 15 (F-2): whatever did not LEAVE this contract goes back on the ledger, so a silent
                // shortfall books rather than disappears.
                if (delivered < amt) owed[to][quote] += amt - delivered;
                emit CreatorSharePushed(to, quote, delivered);
                return;
            } catch {}
        }
        owed[to][quote] += amt;
    }

    /// @notice Whether `quote` may be paid to arbitrary recipients (creator and split) during a swap. True unless
    /// denied in {inSwapRegistry}. Exposed so the coin's tracker reads the same live switch.
    /// @dev `true` does not mean vetted. `false` does not stop the quote's code running inside a V4 lock; it only
    /// keeps creator-chosen recipients from being paid mid-swap.
    function inSwapAllowed(address quote) external view returns (bool) {
        return _inSwapAllowed(quote);
    }

    /// @dev Default-open denylist check: no registry -> allowed; registry answers -> that answer; registry unreadable
    /// -> not allowed (fail-closed, so a broken registry cannot disable the kill switch).
    function _inSwapAllowed(address quote) internal view returns (bool) {
        address r = inSwapRegistry;
        if (r == address(0)) return true;
        (bool ok, bytes memory d) =
            r.staticcall{gas: 20_000}(abi.encodeWithSignature("denied(address)", quote));
        // Raw word, not `abi.decode(d, (bool))`: a non-0/1 word would revert this frame instead of reading as denied.
        if (!ok || d.length != 32) return false;
        return abi.decode(d, (uint256)) == 0;
    }

    /// @dev External-self-only so {_payCreatorShare} can try/catch the transfer (`safeTransfer` bubbles). ERC20 only.
    /// Re-measured so a fee-on-transfer quote is reported correctly.
    /// @return delivered what the recipient's balance actually rose by.
    /// @dev AUDIT ROUND 15 (F-2, Medium). Measures THIS CONTRACT'S balance decrease, and every caller re-credits
    /// `amt - delivered` to `owed[]`.
    ///
    /// The three in-swap ring pushes measured the RECIPIENT's balance, used it only for an event, and never
    /// re-credited a short delivery -- `owed[]` was reached on a REVERT and never on a silent shortfall. So a quote
    /// that returns true while moving nothing consumed the payee's whole slice. Measured: a 2.4e19 creator slice
    /// vanishing -- payee balance 0, `owed` 0, ring slot cleared, `accruedQuote` zeroed so `_distribute` can never
    /// re-book it, the quote sitting on the hook, and `rescue` refusing it as `RescueForbiddenAsset`. **Permanently
    /// unrecoverable by anyone.** This is the same defect round 15 (F-2) fixed on the PULL ledger, on the push side.
    ///
    /// Sender-side is correct in both directions: `amt` for a genuine fee-on-transfer quote (the fee left and is not
    /// ours to re-credit) and `0` for a soft blocklist (a full, correct re-credit). It is also immune to a recipient
    /// that moves its own balance during the transfer.
    function pushSplit(address to, address quote, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransfer(to, amt);
        uint256 aft = IERC20(quote).balanceOf(address(this));
        // Saturating: a quote that somehow returns value to this contract must not make a successful transfer revert.
        delivered = before > aft ? before - aft : 0;
    }

    /// @notice Turn in-swap auto-send on/off for a pool. Creator only.
    function setAutoSend(PoolId id, bool on) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        _setAutoSend(c, id, on);
    }

    /// @notice Same, as the platform. Lets a mis-set pool be corrected without touching the creator role.
    function adminSetAutoSend(PoolId id, bool on) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        _setAutoSend(c, id, on);
    }

    /// @notice Arm or clear the in-swap redeem latch for `id`. Platform or admin only.
    /// @dev Clearing makes the next swap over the threshold retry at full cost; if it still fails the pool re-latches.
    /// The creator is excluded so they cannot repeatedly bill traders for doomed attempts. Survives renounce.
    function resetAutoRedeem(PoolId id, bool latched) external {
        if (msg.sender != platform && (msg.sender != admin || admin == address(0))) revert NotPlatformOrAdmin();
        TaxConfig storage c = _config[id];
        if (!c.configured) revert NotConfigured();
        c.autoRedeemLatched = latched;
        emit AutoRedeemReset(id, msg.sender);
    }

    /// @notice True when `id`'s in-swap redeem is latched off because a full-ceiling attempt was proven to
    /// fail. Payouts are NOT stuck: {distribute} and {runPayouts} are uncapped and still pay in full.
    function autoRedeemLatchedOf(PoolId id) external view returns (bool) {
        return _config[id].autoRedeemLatched;
    }

    /// @dev Whether anything on this pool still needs the in-swap auto path. Every configured pool does, since the
    /// platform cut is pushed in-swap. The single check for every site that would clear `autoEnabled`.
    function _autoStillNeeded(TaxConfig storage c) internal view returns (bool) {
        return c.configured;
    }

    function _setAutoSend(TaxConfig storage c, PoolId id, bool on) internal {
        c.autoSend = on;
        if (on) {
            c.autoEnabled = true;
            // This writes `autoThreshold`, so announce it.
            if (c.autoThreshold == 0) {
                c.autoThreshold = _initialAutoThreshold(c.quote);
                emit AutoThresholdSet(id, c.autoThreshold);
            }
        } else if (!_autoStillNeeded(c)) {
            // Only disable the auto path if nothing else needs it. See {_autoStillNeeded}.
            c.autoEnabled = false;
        }
        emit AutoSendSet(id, on);
    }

    // ─────────────────────── optional launch guards ───────────────────────

    /// @notice The pool's tax config in its original, frozen tuple shape. Use {configOf} for the full struct.
    function config(PoolId id)
        external
        view
        returns (
            address creator, uint16 buyBps, uint16 sellBps, bool configured, bool autoEnabled, bool autoSend,
            bool quoteIsC0, address quote, address rewardsTracker, uint16 rewardsBps, uint80 autoThreshold
        )
    {
        TaxConfig storage c = _config[id];
        return (
            c.creator, c.buyBps, c.sellBps, c.configured, c.autoEnabled, c.autoSend,
            c.quoteIsC0, c.quote, c.rewardsTracker, c.rewardsBps, c.autoThreshold
        );
    }

    /// @notice The full config for `id` as a named struct. Prefer this over the {config} tuple getter.
    function configOf(PoolId id) external view returns (TaxConfig memory) {
        return _config[id];
    }

    /// @notice The tax rate `id` is charging on this side right now, in bps -- the decaying launch rate
    /// during the window, the creator's configured rate after it. Read this, not buyBps/sellBps, if you
    /// want what a trader will actually pay.
    function effectiveBps(PoolId id, bool isBuy) external view returns (uint16) {
        return _effectiveBps(_config[id], isBuy);
    }

    /// @dev Linear decay from `launchTaxBps` to the side's normal rate over `launchTaxSecs`, buys only. Returns the
    /// normal rate when the feature is off or the window has passed.
    /// @dev The instant the launch-tax window CLOSES, on the same anchor {_effectiveBps} charges it from.
    ///
    /// AUDIT ROUND 15 (F-1, High). The window and its two bounds were anchored to DIFFERENT clocks. `_effectiveBps`
    /// deliberately anchors on `tradingOpensAt` so a trading delay does not eat the window, but the round-14 fill
    /// ceiling and liquidity lock both computed `launchTime + launchTaxSecs`. Since
    /// `tradingOpensAt = launchTime + 1 + (jitter % tradingDelaySecs)`, that left a `delay`-second gap in which the
    /// premium is still CHARGED while the ceiling has narrowed back to 2100 and the liquidity lock is already off:
    ///   * BUYING BRICKS. Measured at `buyBps 100`, `launchTaxBps 3000`, `launchTaxSecs 20`, `tradingDelaySecs 60`
    ///     (delay 57): at the first legal second of trading `effectiveBps == 3000` against `ceilBps == 2100`, so a
    ///     fully-filled buy reverts `FillTooSmallForTax` -- even at 100% fill, because on the `beforeSwap` path
    ///     `total == requested` exactly. When `delay >= launchTaxSecs` that covers the WHOLE tradable window and the
    ///     pool cannot be bought at all until the premium decays under 21%. A 60s delay with a 30s launch tax is an
    ///     ordinary advertised configuration.
    ///   * AND IT REOPENS THE ROUND-11 H-1 DODGE. For those seconds the lock's launch-tax clause has expired while
    ///     the tax is still charged, so a sniper can place a single-sided quote-side range below spot, let ordinary
    ///     sells walk the price through it, and acquire coin at 0% launch tax with no swap of their own.
    /// One function now answers the question for all three call sites.
    function _launchTaxEndsAt(TaxConfig storage c) internal view returns (uint256) {
        uint256 anchor = c.guards.tradingOpensAt != 0 ? uint256(c.guards.tradingOpensAt) : uint256(c.guards.launchTime);
        return anchor + uint256(c.guards.launchTaxSecs);
    }

    /// @dev The instant third-party liquidity stops being locked on this pool: the LATEST of every launch guard's
    /// window. Zero means never locked.
    ///
    /// AUDIT ROUND 16 (F-1, High). {beforeAddLiquidity} had grown three ad-hoc clauses over rounds 11, 14 and 15,
    /// and each round independently found the SAME class of bug: a clause that did not cover a guard, or covered it
    /// on the wrong clock. F-1 is the fourth instance -- `maxBuyBps` was missed entirely.
    ///
    /// WHY MAX BUY WAS MISSED. It is the one launch guard with NO window: `_guardsFor` resolves it once into
    /// `maxBuyAmount` and {_requireUnderMaxBuy} enforces it for the life of the pool. A launch guarded ONLY by
    /// `maxBuyBps` is reachable -- `_maxWalletOf` returns zero when the coin has no max wallet, and the three
    /// tax-guard fields are independent -- and satisfied none of the three clauses at ANY timestamp, including the
    /// launch second. So the round-11 H-1 route was open from block one. Measured: supply 1e24, `maxBuyBps 10`
    /// (the floor, cap 1e21), no max wallet, no launch tax, no delay; in the SAME second as the launch a quote-only
    /// range below spot funded with 38,692.887e18 quote, filled by ordinary sells, taken as ERC-6909 claims:
    /// **173,917.431e18 coin against an advertised permanent cap of 1.000e21 -- 173.9x** -- with zero buy tax paid
    /// against 1,934.644e18 owed, and `boughtWhileCapped` and `balanceOf` both zero throughout.
    ///
    /// TWO AUDITORS DISAGREED ABOUT THIS ONE, SO HERE IS THE ADJUDICATION. One called it a High (173.9x the
    /// advertised cap acquired in the launch second); the other called the gap deliberate, on the grounds that
    /// `maxBuy` is per-transaction anyway so the dodge "buys nothing". The second is RIGHT ABOUT THE MECHANISM and
    /// WRONG ABOUT THE CONCLUSION, and the first is right about the conclusion for the wrong reason.
    ///
    /// The mechanism: {_requireUnderMaxBuy}'s accumulator lives in TRANSIENT storage (`_txBoughtSlot`), so it resets
    /// every transaction. `maxBuyAmount` has never bounded cumulative acquisition -- 174 ordinary transactions buy
    /// the same 174 caps' worth. So "173.9x the cap" is NOT the finding; that framing is rejected.
    ///
    /// What is actually gained is two things, and both are real:
    ///   * THE BUY TAX IS EVADED ENTIRELY. A swap buyer pays `buyBps` on every purchase; a limit-order range fills
    ///     from ordinary sell flow and pays nothing. Measured at `buyBps 500`: 1,934.644e18 quote of tax that would
    ///     have gone to the creator, the platform and the rewards holders, simply not paid.
    ///   * IT HAPPENS IN THE ANTI-SNIPE WINDOW. A launch advertising a max buy got ZERO liquidity protection at any
    ///     timestamp, while a launch advertising a max wallet, a launch tax or a trading delay each got the window
    ///     its guard implies. During the seconds sniping actually happens, one untaxed position beat 174 taxed
    ///     transactions. That asymmetry is the defect.
    ///
    /// AND WHAT THIS DELIBERATELY DOES NOT DO. `maxBuyAmount` never expires, so LP-based acquisition is inherently
    /// available on every pool once the windows lapse, and locking liquidity for ever is not an option -- a pool has
    /// to become a normal pool. So the window is {MAX_BUY_LOCK_SECS}: the same 300 seconds {setMaxBuy} already uses
    /// to mean "the advertised cap governs real trading", on the same `tradingOpensAt ?: launchTime` anchor it
    /// already uses. This protects the advertised window without pretending to bound LP acquisition for ever.
    ///
    /// Single-sourcing all four clauses here is the durable fix; a fourth ad-hoc clause would have been the
    /// fifth instance of the same drift.
    function _liquidityLockedUntil(TaxConfig storage c, address coin) internal view returns (uint256 until_) {
        // The coin's max-wallet window, packed as `until << 128 | cap`.
        uint256 packed = _maxWalletOf[coin];
        if (packed != 0) until_ = packed >> 128;
        // Trading delay: no third-party liquidity before the pool is even tradable.
        uint256 opens = uint256(c.guards.tradingOpensAt);
        if (opens > until_) until_ = opens;
        // The launch tax, on the SAME clock it is charged over (round 15, F-1).
        if (c.guards.launchTaxBps != 0) {
            uint256 taxEnds = _launchTaxEndsAt(c);
            if (taxEnds > until_) until_ = taxEnds;
        }
        // Max buy: no window of its own, so it gets the anti-snipe window (round 16, F-1).
        if (c.guards.maxBuyAmount != 0) {
            uint256 anchor = opens != 0 ? opens : uint256(c.guards.launchTime);
            uint256 maxBuyEnds = anchor + uint256(MAX_BUY_LOCK_SECS);
            if (maxBuyEnds > until_) until_ = maxBuyEnds;
        }
    }

    function _effectiveBps(TaxConfig storage c, bool isBuy) internal view returns (uint16) {
        uint16 normal = isBuy ? c.buyBps : c.sellBps;
        if (!c.hasGuards) return normal;                    // slot 0 only; never touches the guard slot
        // Buys only: the launch tax deters snipers, and sellers can always exit at the advertised sell rate.
        if (!isBuy) return normal;
        uint16 startBps = c.guards.launchTaxBps;
        if (startBps <= normal) return normal;              // also covers startBps == 0 (feature off)
        uint16 window = c.guards.launchTaxSecs;
        // Seconds, anchored to when trading opens (not launch), so a trading delay does not consume the window.
        // Clamped below so the public view cannot underflow before the open.
        uint256 anchor = c.guards.tradingOpensAt != 0 ? uint256(c.guards.tradingOpensAt) : uint256(c.guards.launchTime);
        uint256 elapsed = block.timestamp <= anchor ? 0 : block.timestamp - anchor;
        if (window == 0 || elapsed >= window) return normal;
        // Premium term rounded up so it lasts until the real end of the window; exactly `normal` at `elapsed == window`.
        uint256 rem = window - elapsed;
        uint256 prem = (uint256(startBps - normal) * rem + window - 1) / window;
        return uint16(uint256(normal) + prem);
    }

    /// @dev Validates the guard params and returns the absolute per-buy ceiling. Reverts rather than silently clamping.
    function _guardsFor(uint16 maxBuyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint8 delaySecs, address coin)
        internal
        view
        returns (uint128 maxBuyAmount)
    {
        if (maxBuyBps != 0) {
            if (maxBuyBps < MIN_MAX_BUY_BPS || maxBuyBps > BPS) revert BadLaunchGuard();
            uint256 cap = FullMath.mulDiv(IERC20Supply(coin).totalSupply(), maxBuyBps, BPS);
            // Resolved to absolute units once, at launch, so enforcement costs no external call per swap.
            // Safe because these tokens are fixed-supply with no mint and no burn hook.
            if (cap == 0 || cap > type(uint128).max) revert BadLaunchGuard();
            maxBuyAmount = uint128(cap);
        }
        // Launch tax rate and window must be set together (window in seconds).
        _requireLaunchTaxOk(launchTaxBps, launchTaxSecs);
        if (delaySecs > MAX_TRADING_DELAY) revert BadLaunchGuard();
    }

    /// @dev Jittered trading-open time. Not a secret and not anti-snipe protection: all inputs are public, the result is
    /// emitted, and a wrapper contract can grind it.
    function _jitteredOpen(uint8 secs) internal view returns (uint40) {
        if (secs == 0) return 0;
        uint256 r = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp, msg.sender)));
        return uint40(block.timestamp + 1 + (r % secs));
    }

    /// @dev Reverts a non-seeder swap before the pool opens.
    function _requireTradingOpen(PoolId id, TaxConfig storage c, address sender) internal view {
        if (!c.hasGuards) return;
        uint40 opensAt = c.guards.tradingOpensAt;
        if (opensAt == 0 || block.timestamp >= opensAt) return;
        if (_inLaunchTx(id, c, sender)) return;
        revert TradingNotOpen();
    }

    /// @dev Rejects a buy that takes this transaction's total coin bought over the per-transaction cap, and --
    /// since audit round 9 -- a buy that takes `tx.origin`'s running total over the coin's MAX WALLET while that
    /// window is live. The launch transaction's dev buy is exempt from both, once.
    /// @dev AUDIT ROUND 8 (Medium): the per-transaction counter used to be keyed on the POOL, so a coin with
    /// several pools had its cap multiplied by its pool count (measured 1.60e22 against a 1.0e22 cap over two
    /// pools). It is keyed on the COIN now, which aggregates every pool of that coin in the transaction at no
    /// extra cost. Round 8 also argued the counter should stay transient because "cross-transaction accumulation
    /// is max wallet's job" -- ROUND 9 OVERTURNED THAT: max wallet could not do the job (see
    /// {_requireUnderMaxWallet}), so both caps fell together and the accumulation is now done here.
    /// @dev AUDIT ROUND 9 (L5): the transient record used to sit AFTER the `cap == 0` and whitelist returns, so a
    /// whitelisted origin's buy -- or any buy on a pool with no per-transaction cap -- never joined the per-coin
    /// total, and a second address in the SAME transaction could then still take a full cap on top of it. The
    /// record is unconditional now, and only the REFUSAL is exempted, so the total is always the truth about the
    /// transaction.
    function _requireUnderMaxBuy(PoolId id, TaxConfig storage c, address sender, int128 coinOut, address coin)
        internal
    {
        if (!c.hasGuards) return;
        // Consume the launch-transaction exemption on first use, so only the locker's dev buy is exempt. Cleared here
        // (not in {_requireTradingOpen}, which runs for the same swap) and before the `cap == 0` check.
        if (_inLaunchTx(id, c, sender)) {
            _clearLaunchTx(id);
            return;
        }
        if (coinOut <= 0) return;
        uint256 bought = uint256(int256(coinOut));

        bytes32 slot = _txBoughtSlot(coin);
        uint256 acc;
        assembly ("memory-safe") {
            acc := tload(slot)
        }
        acc += bought;
        assembly ("memory-safe") {
            tstore(slot, acc)
        }
        uint128 cap = c.guards.maxBuyAmount;
        // Whitelisted wallets (matched on tx.origin, since the hook only sees the router) skip the max buy only --
        // their buy still counts above, so the whitelist cannot be used to launder someone else's headroom.
        if (cap != 0 && acc > cap && !sniperWhitelisted[id][tx.origin]) revert MaxBuyExceeded();

        _requireUnderMaxWallet(coin, bought);
    }

    /// @dev AUDIT ROUND 9 (High). Max wallet lives in the COIN's `_update`, so it only ever sees ERC-20 transfers.
    /// A V4 buy produces a DELTA, and `PoolManager.mint(buyer, coinId, amount)` turns that delta into ERC-6909
    /// claim tokens while the coin's ERC-20 balance never leaves the PoolManager: no transfer, no `_update`, no
    /// check. The hoard stays fully liquid (selling is burn + settle) and, once `maxWalletUntil` lapses, a single
    /// `burn` + `take` delivers all of it to one wallet. An out-of-range V4 liquidity position is the same trick.
    /// Measured: a 5e22 cap and 40 buys left 7.9129e23 held -- 15.8x the cap -- with `balanceOf` zero throughout.
    /// {_requireUnderMaxBuy} could not cover it either: it is per-transaction by design and deferred accumulation
    /// to max wallet, so N transactions in one block accumulated N caps and both guards fell together.
    ///
    /// The accumulation is therefore done HERE, where the buy is visible whatever the delivery mechanism, against
    /// the coin's own cap, in PERSISTENT storage across transactions.
    ///
    /// WHY `tx.origin` IS THE KEY, and not the recipient. On a V4 swap the recipient is not knowable at this
    /// point: delivery happens afterwards, in the caller's own frame, by `take`, `mint`, or a liquidity position,
    /// and the hook is never told which. `tx.origin` is the EOA behind a sniper contract and the EOA behind an
    /// ordinary user's router -- exactly the entity a wallet cap is aimed at. Infrastructure is never `tx.origin`,
    /// so the PoolManager, the routers, the LP locker and the launcher cannot be caught by it, and the launch
    /// transaction is exempted by the caller above. The coin's own launch-time `maxWalletExempt` allowlist is
    /// honoured, read only on the failure path so an ordinary buy never pays for it.
    ///
    /// COST. While the window is live: one cold SSTORE (~22,100) the first time an origin buys that coin, a warm
    /// update (~2,900) after. Once the window lapses the cached entry is zeroed on the next buy and the check is
    /// one zero SLOAD for the rest of the coin's life -- post-window trading is unaffected.
    ///
    /// ACCEPTED, and deliberately conservative: the total does not fall on sells, so during the window an origin
    /// may buy at most one cap in TOTAL even across a sell and a re-buy, and one EOA buying for two wallets is
    /// held to one cap between them. The window is a launch guard measured in minutes to hours, and that same EOA
    /// could never have HELD more than one cap anyway.
    function _requireUnderMaxWallet(address coin, uint256 bought) internal {
        uint256 packed = _maxWalletOf[coin];
        if (packed == 0) return; // never armed, or the window is over for good
        uint256 cap = uint256(uint128(packed));
        if (block.timestamp >= packed >> 128) {
            delete _maxWalletOf[coin]; // the window lapsed: stop paying for it, permanently
            return;
        }
        address origin = tx.origin;
        uint256 acc = boughtWhileCapped[coin][origin] + bought;
        boughtWhileCapped[coin][origin] = acc;
        if (acc > cap && !_maxWalletExempt(coin, origin)) revert MaxWalletAccumulated();
    }

    /// @dev Cache the coin's max-wallet immutables. Returns true when a live cap is armed for it.
    function _cacheMaxWallet(address coin) internal returns (bool) {
        if (_maxWalletOf[coin] != 0) return true; // another pool of this coin already cached it
        (bool okA, bytes memory a) = coin.staticcall{gas: 20_000}(abi.encodeWithSignature("maxWallet()"));
        (bool okB, bytes memory b) = coin.staticcall{gas: 20_000}(abi.encodeWithSignature("maxWalletUntil()"));
        if (!okA || !okB || a.length < 32 || b.length < 32) return false;
        uint256 cap = abi.decode(a, (uint256));
        uint256 until_ = abi.decode(b, (uint256));
        if (cap == 0 || cap > type(uint128).max || until_ <= block.timestamp || until_ > type(uint128).max) {
            return false;
        }
        _maxWalletOf[coin] = (until_ << 128) | cap;
        return true;
    }

    /// @dev The coin's launch-time max-wallet allowlist. Read only when a buy is about to be refused, so the
    /// common path never pays for it; an unreadable coin is treated as "not exempt" (fail closed).
    function _maxWalletExempt(address coin, address who) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            coin.staticcall{gas: 20_000}(abi.encodeWithSignature("maxWalletExempt(address)", who));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev Per-COIN, per-transaction running total bought, so every pool of a coin shares one cap in a
    /// transaction. Distinct from {_launchTxSlot} by prefix.
    function _txBoughtSlot(address coin) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("realm.txBought", coin));
    }

    /// @notice Creator-only: relax the per-buy cap, or remove it with 0. It can only ever be loosened.
    /// @dev Takes the PoolKey so the coin is derived, not supplied.
    function setMaxBuy(PoolKey calldata key, uint16 maxBuyBps) external nonReentrant {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        // Validate before reading `quoteIsC0`.
        if (!c.configured) revert NotConfigured();
        _requireActiveCreator(c, id);
        address coin = Currency.unwrap(c.quoteIsC0 ? key.currency1 : key.currency0);
        if (c.guards.maxBuyAmount == 0) revert CannotTighten();   // already unlimited; nothing to loosen
        // Locked for {MAX_BUY_LOCK_SECS} after trading opens, so the advertised cap governs real trading.
        // `tradingOpensAt` is 0 when no delay was set.
        uint256 opensAt = c.guards.tradingOpensAt == 0 ? uint256(c.guards.launchTime) : uint256(c.guards.tradingOpensAt);
        if (block.timestamp < opensAt + MAX_BUY_LOCK_SECS) revert TooSoonAfterLaunch();
        uint128 next;
        if (maxBuyBps != 0) {
            if (maxBuyBps > BPS) revert BadLaunchGuard();
            uint256 cap = FullMath.mulDiv(IERC20Supply(coin).totalSupply(), maxBuyBps, BPS);
            if (cap > type(uint128).max) revert BadLaunchGuard();
            next = uint128(cap);
            if (next <= c.guards.maxBuyAmount) revert CannotTighten();
        }
        c.guards.maxBuyBps = maxBuyBps;
        c.guards.maxBuyAmount = next;
        emit MaxBuySet(id, maxBuyBps, next);
    }


    // ── sniper whitelist storage (appended so no existing slot moves) ───────────────────────────
    /// @notice Most wallets a launch may whitelist.
    uint8 public constant MAX_SNIPER_WHITELIST = 50;
    /// @notice poolId => wallet => skips this pool's max buy (matched on tx.origin). Set once at launch.
    mapping(PoolId => mapping(address => bool)) public sniperWhitelisted;

    // ── creator hand-off storage (appended) ─────────────────────────────────────────────────────
    struct CreatorProposal {
        address from;
        address to;
    }
    /// @notice coin => every pool configured for it (written once per pool in configurePool).
    mapping(address => PoolId[]) internal _coinPools;
    /// @notice poolId => the creator renounced it. Cleared only by an admin CTO.
    mapping(PoolId => bool) public creatorRenounced;
    /// @notice coin => the pending creator hand-off, if any.
    mapping(address => CreatorProposal) public creatorProposalOf;

    // ── rescue storage (appended) ───────────────────────────────────────────────────────────────
    /// @notice token => a pool quote or coin, or a configured WETH (address(0) = a native pool exists). Never rescuable.
    mapping(address => bool) public isPoolAsset;

    // ── creator-change nonce storage (appended) ─────────────────────────────────────────────────
    /// @dev Incremented on every creator change (voluntary or admin). Monotonic, so an away-and-back sequence cannot
    /// reproduce an earlier state the way comparing creator addresses can.
    uint256 internal _creatorChangeNonce;
    /// @dev poolId => the nonce of its most recent creator change (0 = never changed since configuration).
    mapping(PoolId => uint256) internal _creatorChangedAt;
    /// @dev coin => the nonce when its pending proposal was made. A pool changed after it makes the proposal stale.
    mapping(address => uint256) internal _proposedAtNonce;

    // ── LP locker registry (appended) ───────────────────────────────────────────────────────────
    /// @notice An LP locker a registered launcher reported at configuration. Refused as a creator split recipient.
    mapping(address => bool) public isSeeder;
}

/// @dev Minimal view used to resolve a bps max-buy into absolute units at launch.
interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @dev Read-only view used to learn which address performs a launch's atomic dev buy.
interface ILauncherSeeder {
    function lpLocker() external view returns (address);
}
