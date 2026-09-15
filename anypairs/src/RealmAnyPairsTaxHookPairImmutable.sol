// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// v4-core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    toBeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
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

/// @notice Referral sink for a QUOTE-token pool: the hook transfers the platform cut to the sink then notifies.
interface IPlatformFeeSinkToken {
    function onPlatformFeeToken(address token, address quote, uint256 amount) external;
}

/// @notice Native-quote referral sink entry point. Same selector the ETH hook used, so existing splitters that
/// implement both entry points need no change.
interface IPlatformFeeSink {
    function onPlatformFeeETH(address token) external payable;
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
    /// @notice Hard ceiling on any per-side tax rate (5%), for creator, admin and owner alike ({_requireRatesOk}).
    /// {setMaxSideBps} cannot exceed it. Not the partial-fill ceiling: see {FILL_TOLERANCE_BPS}.
    uint16 public constant MAX_SIDE_BPS_LIMIT = 500; // 5% per side, absolute
    /// @notice Partial-fill sanity ceiling for {afterSwap}'s {FillTooSmallForTax} check. Not a rate. Kept separate
    /// from {MAX_SIDE_BPS_LIMIT} because lowering it raises the minimum acceptable fill.
    uint16 public constant FILL_TOLERANCE_BPS = 2000;

    // ── optional launch guards ──────────────────────────────────────────────────────────────────────
    /// @dev Ceiling on the opening launch tax. Above {MAX_SIDE_BPS_LIMIT} on purpose; it decays to the normal rate.
    uint16 public constant MAX_LAUNCH_TAX_BPS = 3000; // 30%
    /// @dev Maximum launch-tax window, in seconds. Seconds rather than blocks because `block.number` on this chain
    /// is the L1 block number and advances only every ~12 seconds.
    uint16 public constant MAX_LAUNCH_TAX_SECS = 3600; // 1 hour
    /// @dev Floor on a max-buy cap. Without it, `maxBuyBps = 1` is a honeypot wearing a limit's clothes.
    uint16 public constant MIN_MAX_BUY_BPS = 10; // 0.1% of supply
    /// @dev Ceiling on the anti-snipe delay, for the same reason.
    uint8 public constant MAX_TRADING_DELAY = 60; // seconds
    /// @dev How long an advertised max buy cannot be loosened, measured from when trading opens (not from
    /// launch), so a trading delay cannot be used to wait out the lock.
    uint40 public constant MAX_BUY_LOCK_SECS = 300; // 5 minutes of real trading under the advertised number

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
    uint16 public constant MAX_PLATFORM_FLOOR_BPS = 100; // 1.00% of the trade
    uint16 public constant MAX_PLATFORM_CAP_BPS = 300; // 3.00% of the trade
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
    uint24 public constant POOL_FEE = 3000; // required 0.30% LP fee (locker compounds it)
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
    /// rewards tracker (21), referrer (22).
    uint256 internal constant PAY_SLOT_PLATFORM = 0;
    uint256 internal constant PAY_SLOT_SPLIT_BASE = 1;
    /// @dev Derived from {MAX_SPLIT_RECIPIENTS} so a split recipient and the rewards tracker can never share a slot.
    uint256 internal constant PAY_SLOT_REWARDS = PAY_SLOT_SPLIT_BASE + MAX_SPLIT_RECIPIENTS;
    /// @dev The referrer's cut, pushed in-swap like the platform's. After the rewards slot so earlier indices are unchanged.
    uint256 internal constant PAY_SLOT_REFERRAL = PAY_SLOT_REWARDS + 1;
    /// @dev Must stay a literal (solc rejects a library-qualified constant as an array length). Keep in step:
    ///     PAY_SLOTS == PAY_SLOT_REFERRAL + 1 == PAY_SLOT_SPLIT_BASE + MAX_SPLIT_RECIPIENTS + 2 == 23.
    uint256 internal constant PAY_SLOTS = 23;

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
    /// Platform side: {PAY_SLOT_PLATFORM} and {PAY_SLOT_REFERRAL} (the referrer is paid out of the platform's cut).
    uint32 internal constant RING_PLATFORM =
        (uint32(1) << uint32(PAY_SLOT_PLATFORM)) | (uint32(1) << uint32(PAY_SLOT_REFERRAL));
    uint32 internal constant RING_CREATOR = ~RING_PLATFORM;

    /// @notice Maximum pools per {claimPlatformMany} call, sized so `MAX_CLAIM_BATCH * CLAIM_ONE_GAS_CAP` fits a block.
    uint256 public constant MAX_CLAIM_BATCH = 64;

    /// @dev Gas forwarded to each pool in a {claimPlatformMany} batch, so one hostile quote cannot starve the rest.
    uint256 internal constant CLAIM_ONE_GAS_CAP = 1_200_000;
    /// @dev Left in this frame after the last forwarded call so the loop can finish its own bookkeeping.
    uint256 internal constant CLAIM_BATCH_TAIL = 60_000;

    /// @dev One ring entry, packed into one slot. `to` is snapshotted at booking and never re-derived at push
    /// time, so a later split or creator change cannot redirect money already earned.
    struct PaySlot {
        address to;
        uint96 amt;
    }
    mapping(PoolId => PaySlot[PAY_SLOTS]) internal _paySlots;

    /// @notice Bit `i` set when ring slot `i` of this pool is funded; lets a swap skip the walk with one SLOAD.
    mapping(PoolId => uint32) public pendingMask;
    /// @notice Where the next ring walk resumes. Rotates to avoid starvation; parks on the first unaffordable slot.
    mapping(PoolId => uint8) public payCursor;
    // Gas forwarded to an ERC20 rewards push ({pushRewards}: self-call, two `balanceOf`, transfer, `feedToken`). Kept below
    // {PAY_FLOOR_FEED_TOKEN} so the catch always has gas for its `owed` fallback; an over-run only delays
    // booking, never loses funds. Tracker `feedToken` cost grows with a multi-basket's denomination count, so
    // re-check this cap against a realistic quote before raising a tracker's denomination limit.
    uint256 internal constant FEED_GAS_CAP_TOKEN = 320_000;
    /// @dev The NATIVE cap, restored to the deleted ETH hook's figure.
    uint256 internal constant FEED_GAS_CAP_NATIVE = 200_000;
    // Per-visit floors of the payout ring. Each gates one ring visit and is checked just before its push; a
    // visit the budget cannot afford is deferred (the slice stays booked), not cancelled. Keyed on the quote
    // because native pushes are far cheaper than ERC20 ones. The FEED floors must be >= FEED_GAS_CAP_* * 64/63
    // so the full cap is always forwarded.
    uint256 internal constant PAY_FLOOR_FEED_TOKEN = 380_000;
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
        uint16 maxBuyBps; // informational: the cap as bps of supply (maxBuyAmount is what's enforced)
        uint16 launchTaxBps; // opening tax for the launch window, decaying to buyBps/sellBps
        uint128 maxBuyAmount; // absolute per-transaction ceiling in coin units, resolved from supply
        uint40 launchTime; // unix ts the pool was configured at; anchors the decay window
        uint16 launchTaxSecs; // length of the decay window, in SECONDS
        uint40 tradingOpensAt; // unix ts before which swaps revert (the launch tx itself excepted)
    }

    struct TaxConfig {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        bool configured;
        bool autoEnabled;
        bool autoSend; // true = PUSH the creator share to its recipients in-swap (pull ledger is the fallback)
        bool quoteIsC0; // true if the QUOTE token is currency0 (else currency1). Set at configure time.
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
        address quote; // the pool's quote token (stock/USDG) — the currency tax is skimmed/paid in
        /// @dev Creator-pool slice routed to buyback-and-burn. Placed after `quote` to pack into its slot.
        uint16 buybackBps;
        /// @dev Creator-pool slice routed to auto-liquidity. Packs into `quote`'s slot.
        uint16 lpBps;
        /// @dev Platform rates snapshotted at launch by {configurePool} and never rewritten. Pack into `quote`'s slot.
        uint16 platformShareBps;
        uint16 platformFloorBps;
        uint16 platformCapBps;
        address rewardsTracker; // 0 = not a rewards pool; else the coin's quote-token DividendTracker
        uint16 rewardsBps; // slice of the CREATOR pool routed to holders; 0 = none
        uint80 autoThreshold; // accrued-quote (raw units) that triggers the in-swap auto-distribute
        Guards guards;
    }

    // The `Split` struct lives in {RealmAnyPairsSplitLib} so the storage array can be passed to library functions.

    IPoolManager public immutable poolManager;

    mapping(address => bool) public isLauncher;
    uint256 public launcherCount; // number of addresses currently whitelisted in isLauncher
    address public platform;
    address public admin;

    mapping(PoolId => TaxConfig) internal _config;
    mapping(PoolId => RealmAnyPairsSplitLib.Split[]) internal creatorSplits;
    mapping(PoolId => uint256) public accruedQuote; // per-pool tax accrued, in the pool's quote token

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

    /// @dev Gas for an auto-converting tracker's `convertStep` after a swap, beyond {SWAP_TAIL_RESERVE}. Skipped
    /// unless the whole amount is available.
    uint256 internal constant REWARD_CONVERT_GAS = 650_000;

    /// @notice Quote accrued for this pool's coin-denominated holder rewards, awaiting conversion.
    mapping(PoolId => uint256) public reflectPot;
    mapping(address => mapping(address => uint256)) public owed; // recipient => quoteToken => amount (pull ledger)

    /// @notice Owner-set initial auto-distribute threshold per quote token, in that quote's units. 0 = use the
    /// decimals-derived default from {_initialAutoThreshold}.
    mapping(address => uint80) public defaultAutoThreshold;

    /// @notice Who referred this pool's coin, or 0. Set once by a launcher at launch and never changed.
    /// @dev No correction path, so nobody can redirect a referrer's earnings.
    mapping(PoolId => address) public referrerOf;

    /// @notice The referrer's share of the platform fee (never of the creator's tax).
    /// @dev A constant, so there is no owner lever over money promised to a referrer.
    uint16 public constant REFERRAL_BPS = 1000;

    /// @notice {RealmAnyPairsInSwapRegistry}: denylist of quotes that may not be paid to arbitrary recipients during
    /// a swap. Owner-settable so a quote can be revoked quickly.
    address public inSwapRegistry;

    address public weth;
    address public swapRouter;
    mapping(address => bytes) public quoteToWethPath; // quote token -> V3 path quote→…→WETH

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
    /// @dev Emitted at configure time when the pool's holder rewards are paid in the coin.
    event RewardsInCoin(PoolId indexed id, address tracker);

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
    event LaunchGuardsSet(
        PoolId indexed poolId, uint16 maxBuyBps, uint16 launchTaxBps, uint16 launchTaxSecs, uint40 tradingOpensAt
    );
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
    /// @dev Records a pool's referrer at launch.
    event PoolReferred(PoolId indexed poolId, address indexed token, address indexed referrer);
    /// @dev The referrer's cut was booked for payout.
    event ReferralCredited(PoolId indexed poolId, address indexed referrer, address quote, uint256 amount);
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
    error SplitLibraryMissing();
    /// @dev Renounce attempted while {setSwapConfig} has never been called. See {_requireRenounceReady}.
    error SwapConfigUnset();
    /// @dev Thrown by {RealmAnyPairsSplitLib.requireQuotePath} for {setQuoteToWethPath}; redeclared so this ABI decodes it.
    error BadQuotePath();
    error QuoteIsWeth();
    /// @dev Thrown by {RealmAnyPairsSplitLib.claimTo} when the destination is `address(0)`, this hook or the
    /// PoolManager. Redeclared so this ABI decodes it.
    error BadClaimDestination();
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
    /// @dev {markReferred} given an address that can never be a referrer (e.g. zero, the coin, the quote, the
    /// creator or this hook).
    error BadReferrer();
    /// @dev `rewardsBps + buybackBps + lpBps` exceeds {BPS}.
    error BadSliceSum();
    error BadAutoThreshold();
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
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        _;
    }

    /// @dev Owner or admin. The admin survives {renounceOwnership}, so configuration remains possible afterwards;
    /// a compromised admin is unrecoverable once ownership is renounced (accepted risk).
    /// {transferOwnership} and {renounceOwnership} stay owner-only; do not widen them to this modifier.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner && (msg.sender != admin || admin == address(0))) {
            revert NotOwnerOrAdmin();
        }
        _;
    }

    constructor(IPoolManager pm, address owner_, address platform_) RealmAnyPairsImmutableBase(owner_) {
        // Fail at construction if the linked library is not deployed (proves code exists, not that it is the right code).
        if (address(RealmAnyPairsSplitLib).code.length == 0) {
            revert SplitLibraryMissing();
        }
        if (platform_ == address(0)) {
            revert ZeroAddress();
        }
        // poolManager is immutable and has no setter — a zero would brick every hook callback permanently.
        if (address(pm) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = pm;
        admin = owner_;
        platform = platform_;
    }

    // ─────────────────────────── admin ───────────────────────────

    function setLauncher(address launcher, bool allowed) external onlyOwnerOrAdmin {
        // Reject zero so a bogus launcher entry cannot satisfy {_requireRenounceReady}.
        if (launcher == address(0)) {
            revert ZeroAddress();
        }
        if (allowed != isLauncher[launcher]) {
            if (allowed) {
                launcherCount += 1;
            } else {
                launcherCount -= 1;
            }
        }
        isLauncher[launcher] = allowed;
        emit LauncherSet(launcher, allowed);
    }

    /// @dev Blocks {renounceOwnership} until the hook is fully wired: a launcher, a non-zero admin, the swap config
    /// and the in-swap registry. Each would be unrepairable after renounce.
    function _requireRenounceReady() internal view override {
        if (launcherCount == 0) {
            revert NoLauncherWhitelisted();
        }
        // A zero admin could never be restored after renounce, bricking CTO reassignment.
        if (admin == address(0)) {
            revert AdminZero();
        }
        // Unset weth/swapRouter is legal while owned, but only the admin could repair it after renounce.
        if (weth == address(0) || swapRouter == address(0)) {
            revert SwapConfigUnset();
        }
        // An unset registry means no kill switch: every quote would be pushed in-swap with no way to deny one.
        if (inSwapRegistry == address(0)) {
            revert InSwapRegistryNotSet();
        }
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
        if (configured != 0) {
            return configured;
        }
        // Native: fixed 0.02 ETH, not derived from decimals() (a staticcall to address(0) returns empty data).
        if (quote == address(0)) {
            return uint80(0.02 ether);
        }
        // Raw staticcall rather than a typed call in try/catch: a typed call to a codeless address, or a return value
        // that does not decode as uint8, reverts this frame and would brick every launch against that quote.
        uint256 dec = 18;
        (bool ok, bytes memory ret) = quote.staticcall{gas: 20_000}(abi.encodeWithSelector(0x313ce567)); // decimals()
        if (ok && ret.length >= 32) {
            dec = abi.decode(ret, (uint256));
        }
        if (dec > 30) {
            dec = 18; // nonsense/hostile decimals -> treat as standard
        }
        uint256 t = (10 ** dec) / 100; // 0.01 quote units
        if (t == 0) {
            t = 1; // 0- and 1-decimal tokens
        }
        if (t > type(uint80).max) {
            t = type(uint80).max;
        }
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
        if (total == 0) {
            return 0;
        }
        return _platformBps(c, total) * BPS / total;
    }

    /// @notice The CREATOR pool's share of what the trader paid on this side, in bps -- the complement of
    /// {platformBpsOf}, on the same EFFECTIVE rate. Zero on a side that charges nothing at all.
    function creatorPoolBpsOf(PoolId id, bool isBuy) external view returns (uint256) {
        TaxConfig storage c = _config[id];
        uint256 total = _totalBps(c, _effectiveBps(c, isBuy));
        if (total == 0) {
            return 0;
        }
        return BPS - (_platformBps(c, total) * BPS / total);
    }

    /// @notice Tighten the per-side tax ceiling. Cannot exceed {MAX_SIDE_BPS_LIMIT}.
    /// @dev Does not affect configured pools' partial-fill ceiling, which reads constants only.
    function setMaxSideBps(uint16 bps) external onlyOwnerOrAdmin {
        if (bps > MAX_SIDE_BPS_LIMIT) {
            revert SideCapExceeded();
        }
        maxSideBps = bps;
        emit MaxSideBpsSet(bps);
    }

    /// @notice Set the platform rates NEW launches snapshot: `shareBps` of what a trader pays, clamped between
    /// `floorBps` and `capBps` of the trade. Bounds: share 10%-30%, floor <= 1%, floor <= cap <= 3%. Live coins keep their rates.
    function setPlatformRates(uint16 shareBps, uint16 floorBps, uint16 capBps) external onlyOwnerOrAdmin {
        if (shareBps < MIN_PLATFORM_SHARE_BPS || shareBps > MAX_PLATFORM_SHARE_BPS) {
            revert BadPlatformRates();
        }
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
        if (cap > MAX_SIDE_BPS_LIMIT) {
            cap = MAX_SIDE_BPS_LIMIT;
        }
        if (buyBps > cap || sellBps > cap) {
            revert SideCapExceeded();
        }
    }

    /// @dev Admin ratchet for {adminSetRates}: the admin may only lower a pool's rate, per side. Only the creator can raise it.
    function _requireRatchetDown(TaxConfig storage c, uint16 buyBps, uint16 sellBps) internal view {
        if (buyBps > c.buyBps || sellBps > c.sellBps) {
            revert RateNotLowered();
        }
    }

    // ── admin overrides of the creator-owned knobs ──

    /// @dev Downward-only ({_requireRatchetDown}): the admin can lower a pool's rate, never raise one. Only the creator
    /// can raise their own rate ({setRates}).
    function adminSetRates(PoolId id, uint16 buyBps, uint16 sellBps) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
        if (c.rewardsTracker == address(0)) {
            revert BadRewardsBps();
        }
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
        if (msg.sender != admin || admin == address(0)) {
            revert NotAdmin();
        }
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        if (c.rewardsTracker != address(0)) {
            revert TrackerAlreadySet();
        }
        if (tracker == address(0)) {
            revert ZeroAddress();
        }
        if (tracker == address(this)) {
            revert SelfAddress();
        }
        if (tracker.code.length == 0) {
            revert TrackerCodeless();
        }
        c.rewardsTracker = tracker;
        c.rewardsAutoConvert = _rewardsAutoConvert(tracker);
        emit RewardsTrackerSet(id, tracker);
    }

    function adminSetAutoThreshold(PoolId id, uint80 threshold) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        if (!c.autoEnabled || threshold == 0) {
            revert BadAutoThreshold();
        }
        c.autoThreshold = threshold;
        emit AutoThresholdSet(id, threshold);
    }

    /// @dev Flushes at the old terms first, like {setCreatorSplit}: the split is read at distribution time.
    function adminSetCreatorSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps)
        external
        onlyOwnerOrAdmin
        nonReentrant
    {
        if (!_config[id].configured) {
            revert NotConfigured();
        }
        _flushAtOldTerms(id);
        _storeSplit(id, recipients, bps, address(0));
        emit CreatorSplitSet(id, msg.sender, recipients.length);
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
        if (ok && d.length == 32) {
            seeder = address(uint160(abi.decode(d, (uint256))));
        }
        if (seeder == address(0)) {
            return;
        }
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
        if (sender == address(0)) {
            return false;
        }
        if (block.timestamp != uint256(c.guards.launchTime)) {
            return false;
        }
        bytes32 s = _launchTxSlot(id);
        uint256 v;
        assembly ("memory-safe") { v := tload(s) }
        return v == uint256(uint160(sender));
    }

    function setPlatform(address platform_) external onlyOwnerOrAdmin {
        if (platform_ == address(0)) {
            revert ZeroAddress();
        }
        // `owed[address(this)][quote]` could never be drained.
        if (platform_ == address(this)) {
            revert SelfAddress();
        }
        platform = platform_;
        emit PlatformSet(platform_);
    }

    /// @dev `address(this)` is rejected: {setTokenCreator} is admin-gated, so it would kill the CTO path.
    /// `address(0)` is allowed and disables admin powers (permanently, once ownership is renounced).
    function setAdmin(address admin_) external onlyOwnerOrAdmin {
        if (admin_ == address(this)) {
            revert SelfAddress();
        }
        admin = admin_;
        emit AdminSet(admin_);
    }

    /// @notice Configure the WETH token and SwapRouter02 used to convert quote fees to ETH at claim time.
    /// Both must be non-zero.
    function setSwapConfig(address weth_, address router_) external onlyOwnerOrAdmin {
        if (weth_ == address(0) || router_ == address(0)) {
            revert ZeroAddress();
        }
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
        if (quote == address(0)) {
            revert NativeQuote();
        }
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
        if (key.fee != POOL_FEE) {
            revert BadPoolFee();
        }
        if (address(key.hooks) != address(this)) {
            revert WrongHook();
        }
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        // `address(0)` (native ETH) is a legal quote. Native can only be currency0, so a zero currency1 is a malformed key.
        if (c1 == address(0)) {
            revert NotPairPool();
        }
        // Probe currency1 first: {_isCoin} is a typed call, and probing address(0) would revert instead of returning false.
        if (_isCoin(c1, launcher)) {
            coin = c1;
            quote = c0;
            quoteIsC0 = true;
        } else if (c0 != address(0) && _isCoin(c0, launcher)) {
            coin = c0;
            quote = c1;
            quoteIsC0 = false;
        } else {
            revert NotLauncher();
        }
    }

    function _isCoin(address t, address launcher) internal view returns (bool) {
        try RealmAnyPairsTokenPlain(t).launcher() returns (address l) {
            return l == launcher;
        } catch {
            return false;
        }
    }

    /// @notice Launcher-only: record who referred this pool. One-shot; a later launcher cannot redirect it.
    /// @dev Referrers that can never claim are rejected here, so every launcher gets the same checks.
    function markReferred(PoolKey calldata key, address referrer) external {
        if (!isLauncher[msg.sender]) {
            revert NotLauncher();
        }
        (address coin,,) = _shape(key, msg.sender);
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        // Refuse every address this launch itself puts in the pool's graph: none can claim, so naming one would burn
        // the referral share of the platform fee for the life of the coin. The launcher screens its LP locker.
        if (
            referrer == address(0) || referrer == coin || referrer == c.creator || referrer == c.quote
                || referrer == address(this) || referrer == address(poolManager) || referrer == c.rewardsTracker
                || isLauncher[referrer] || referrer == BURN_SINK
        ) {
            revert BadReferrer();
        }
        if (referrerOf[id] == address(0)) {
            referrerOf[id] = referrer;
            emit PoolReferred(id, coin, referrer);
        }
    }

    // ─────────────────────── pool configuration ───────────────────────

    struct ConfigParams {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        address[] recipients;
        uint16[] splitBps;
        address rewardsTracker;
        uint16 rewardsBps;
        bool autoSend; // true = pay the creator share out in-swap instead of accruing it to owed[]
        /// @dev Auto-distribute threshold in the quote's units. 0 = use the default. Retunable via {setAutoThreshold}.
        uint80 autoThreshold;
        // ── optional launch guards; leave every one at 0 to opt out (existing callers unaffected) ──
        uint16 maxBuyBps; // max single buy as bps of total supply
        uint16 launchTaxBps; // opening tax for the launch window
        uint16 launchTaxSecs; // decay window length, in SECONDS (block.number here is the L1 block)
        uint8 tradingDelaySecs; // jitter window: trading opens 1..N seconds after launch
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
        if (tracker == address(0) || coin == address(0)) {
            return false;
        }
        (bool ok, bytes memory data) = tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("quote()"));
        if (!ok || data.length != 32) {
            return false;
        }
        return abi.decode(data, (address)) == coin;
    }

    /// @dev True when `tracker` answers `autoConvertsRewards() == true`. Fail-closed: no readable answer means false.
    function _rewardsAutoConvert(address tracker) internal view returns (bool) {
        if (tracker == address(0)) {
            return false;
        }
        (bool ok, bytes memory data) = tracker.staticcall{gas: 20_000}(abi.encodeWithSignature("autoConvertsRewards()"));
        return ok && data.length == 32 && abi.decode(data, (uint256)) == 1;
    }

    /// @dev Rewards, buyback and LP slices are shares of the same creator pool, so their sum must fit {BPS} after
    /// every change. Shared by every caller that can change a term; add any new slice here.
    function _requireSliceSum(uint256 rewardsBps, uint256 buybackBps, uint256 lpBps) internal pure {
        if (rewardsBps > BPS || buybackBps > BPS || lpBps > BPS) {
            revert BadSliceSum();
        }
        if (rewardsBps + buybackBps + lpBps > BPS) {
            revert BadSliceSum();
        }
    }

    function configurePool(PoolKey calldata key, ConfigParams calldata p) external {
        if (!isLauncher[msg.sender]) {
            revert NotLauncher();
        }
        (address coin, address quote, bool quoteIsC0) = _shape(key, msg.sender);

        PoolId id = key.toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        if (sqrtP == 0) {
            revert PoolNotInitialized();
        }
        if (_config[id].configured) {
            revert AlreadyConfigured();
        }
        if (p.creator == address(0)) {
            revert ZeroAddress();
        }
        // Never this hook: `owed[address(this)][quote]` is unreachable and a self-push is backed by no accrual.
        if (p.creator == address(this)) {
            revert SelfAddress();
        }
        _requireRatesOk(p.buyBps, p.sellBps);
        // Same self-address rule for the tracker.
        if (p.rewardsTracker == address(this)) {
            revert SelfAddress();
        }
        _requireSliceSum(p.rewardsBps, p.buybackBps, p.lpBps);

        // Hoisted out of the struct literal below to avoid stack-too-deep.
        uint128 maxBuyAmount_ = _guardsFor(
            p.maxBuyBps,
            p.launchTaxBps,
            p.launchTaxSecs,
            p.tradingDelaySecs,
            Currency.unwrap(quoteIsC0 ? key.currency1 : key.currency0)
        );
        uint40 opensAt_ = _jitteredOpen(p.tradingDelaySecs);
        bool hasGuards_ = p.maxBuyBps != 0 || p.launchTaxBps != 0 || p.tradingDelaySecs != 0;
        bool rewards = p.rewardsTracker != address(0);
        _config[id] = TaxConfig({
            creator: p.creator,
            buyBps: p.buyBps,
            sellBps: p.sellBps,
            configured: true,
            // Every pool needs the in-swap path: the platform and referral cuts are pushed in-swap. A pull-mode
            // creator's own share is still booked to `owed[]`.
            autoEnabled: true,
            autoSend: p.autoSend,
            quoteIsC0: quoteIsC0,
            quote: quote,
            rewardsTracker: p.rewardsTracker,
            rewardsBps: rewards ? p.rewardsBps : 0,
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
        isPoolAsset[coin] = true; // never rescuable
        isPoolAsset[quote] = true; // address(0) here marks that a native pool exists
        emit PoolConfigured(id, p.creator, p.buyBps, p.sellBps);
        emit PoolPlatformRates(id, platformShareBps, platformFloorBps, platformCapBps);
        TaxConfig storage nc = _config[id];
        // Announce the state set here with the same events its setters emit, so indexers see the initial values.
        if (nc.rewardsBps != 0) {
            emit RewardsBpsSet(id, nc.rewardsBps);
        }
        if (nc.autoSend) {
            emit AutoSendSet(id, true);
        }
        if (nc.autoThreshold != 0) {
            emit AutoThresholdSet(id, nc.autoThreshold);
        }
        if (nc.guards.maxBuyAmount != 0) {
            emit MaxBuySet(id, nc.guards.maxBuyBps, nc.guards.maxBuyAmount);
        }
        if (nc.guards.maxBuyBps != 0 || nc.guards.launchTaxBps != 0 || nc.guards.tradingOpensAt != 0) {
            emit LaunchGuardsSet(
                id, nc.guards.maxBuyBps, nc.guards.launchTaxBps, nc.guards.launchTaxSecs, nc.guards.tradingOpensAt
            );
            _markLaunchTx(id, msg.sender);
        }
    }

    // ─────────────────── mutable fee routing (creator + CTO) ───────────────────

    /// @notice Set this pool's tax, up or down, within the 5% hard cap. Creator only. A raise applies to the very
    /// next swap, so front ends should read the live rate ({totalFeeBpsOf}) at quote time.
    /// @dev No flush needed: accrued fees were already collected at the old rate. The launch-tax ramp is unaffected.
    function setRates(PoolId id, uint16 buyBps, uint16 sellBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
        _requireActiveCreator(c, id);
        // Validate before flushing.
        if (c.rewardsTracker == address(0)) {
            revert BadRewardsBps();
        }
        _requireSliceSum(rewardsBps, c.buybackBps, c.lpBps);
        _flushAtOldTerms(id);
        c.rewardsBps = rewardsBps;
        emit RewardsBpsSet(id, rewardsBps);
    }

    /// @notice Retune the slice of this pool's creator share that is bought back and burned. Creator only.
    /// @dev Flushes at the old terms first. Not ratchet-limited; bounded by the slice sum check.
    function setBuybackBps(PoolId id, uint16 buybackBps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
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

    function setAutoThreshold(PoolId id, uint80 threshold) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        _requireActiveCreator(c, id);
        if (!c.autoEnabled || threshold == 0) {
            revert BadAutoThreshold();
        }
        c.autoThreshold = threshold;
        emit AutoThresholdSet(id, threshold);
    }

    function setCreatorSplit(PoolId id, address[] calldata recipients, uint16[] calldata bps) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
        if (amount == 0) {
            return;
        }
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
        if (amount == 0) {
            return;
        }
        // Calling from inside a V4 lock is the caller's own state, so fail hard instead of silently repricing the pot.
        // Checked before the try because a hostile quote could fake `AlreadyUnlocked` revert data.
        if (_managerAlreadyUnlocked()) {
            revert PendingDistribution();
        }
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
    bytes32 internal constant V4_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

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
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, amount, plat, FLUSH_ALL));
    }

    /// @dev Flushes first and is `nonReentrant`: it replaces the creator and deletes the split in one call.
    function setTokenCreator(PoolId id, address newCreator) external nonReentrant {
        if (msg.sender != admin || admin == address(0)) {
            revert NotAdmin();
        }
        _changeCreator(id, newCreator, true);
    }

    /// @dev The single place a pool's creator changes, used by the admin CTO ({setTokenCreator}) and the voluntary
    /// hand-off ({acceptCreator}). They differ in how an outstanding pot is settled and whether a renounce is cleared.
    function _changeCreator(PoolId id, address newCreator, bool byAdmin) internal {
        if (newCreator == address(0)) {
            revert ZeroAddress();
        }
        // Reject this hook (unreachable `owed` key) and the PoolManager (a pushed share would be taken by the next settler).
        if (newCreator == address(this) || newCreator == address(poolManager)) {
            revert SelfAddress();
        }
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        address old = c.creator;
        if (newCreator == old) {
            revert SameCreator();
        }
        // Admin CTO. With split partners: fail-soft flush at the old terms (still reverts inside a V4 lock).
        // With no partners: the unsettled pot follows the new creator. Already-booked ring slots and `owed[]`
        // still pay the old creator either way.
        if (byAdmin) {
            if (creatorSplits[id].length != 0) {
                _flushAtOldTermsSoft(id);
            } else {
                uint256 pot = accruedQuote[id];
                if (pot != 0) {
                    emit HandoverPotFollowed(id, newCreator, pot);
                }
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
        if (msg.sender != c.creator) {
            revert NotCreator();
        }
        if (creatorRenounced[id]) {
            revert CreatorIsRenounced();
        }
    }

    /// @dev A renounce is per coin: refuse configuring a new creator-controlled pool on a renounced coin.
    function _requireCoinNotRenounced(address coin) internal view {
        PoolId[] storage ids = _coinPools[coin];
        if (ids.length != 0 && creatorRenounced[ids[0]]) {
            revert CreatorIsRenounced();
        }
    }

    function _requireActiveCreatorOfCoin(address coin) internal view returns (PoolId[] storage ids) {
        ids = _coinPools[coin];
        uint256 n = ids.length;
        if (n == 0) {
            revert NotConfigured();
        }
        for (uint256 i; i < n; ++i) {
            TaxConfig storage c = _config[ids[i]];
            _requireActiveCreator(c, ids[i]);
        }
    }

    /// @notice Propose handing EVERY pool of `coin` to `newCreator`. CREATOR ONLY, and only while not renounced.
    /// Nothing changes until `newCreator` calls {acceptCreator}; a new proposal replaces the old one.
    function proposeCreator(address coin, address newCreator) external nonReentrant {
        _requireActiveCreatorOfCoin(coin);
        if (newCreator == address(0)) {
            revert ZeroAddress();
        }
        // Nor the PoolManager: a creator share pushed there would be taken by the next settler.
        if (newCreator == address(this) || newCreator == address(poolManager)) {
            revert SelfAddress();
        }
        if (newCreator == msg.sender) {
            revert SameCreator();
        }
        creatorProposalOf[coin] = CreatorProposal({from: msg.sender, to: newCreator});
        _proposedAtNonce[coin] = _creatorChangeNonce; // any creator change after this voids it
        emit CreatorProposed(coin, msg.sender, newCreator);
    }

    /// @notice Withdraw a pending hand-off. Only the address that proposed it.
    function cancelCreatorProposal(address coin) external nonReentrant {
        CreatorProposal storage pr = creatorProposalOf[coin];
        if (pr.to == address(0)) {
            revert NoCreatorProposal();
        }
        if (msg.sender != pr.from) {
            revert NotCreator();
        }
        delete creatorProposalOf[coin];
        emit CreatorProposalCancelled(coin, msg.sender);
    }

    /// @notice Accept a pending hand-off: every pool of `coin` moves to the caller, after settling at the old terms.
    /// Reverts {StaleCreatorProposal} if any creator change or renounce happened since the proposal. A pool whose
    /// PoolManager cannot cover its accrual (e.g. a rebasing-down quote) blocks this until the shortfall is covered.
    function acceptCreator(address coin) external nonReentrant {
        CreatorProposal memory pr = creatorProposalOf[coin];
        if (pr.to == address(0)) {
            revert NoCreatorProposal();
        }
        if (msg.sender != pr.to) {
            revert NotProposedCreator();
        }
        PoolId[] storage ids = _coinPools[coin];
        uint256 n = ids.length;
        uint256 proposedAt = _proposedAtNonce[coin];
        for (uint256 i; i < n; ++i) {
            // `_creatorChangedAt` also catches an admin CTO away and back.
            if (
                _config[ids[i]].creator != pr.from || creatorRenounced[ids[i]] || _creatorChangedAt[ids[i]] > proposedAt
            ) {
                revert StaleCreatorProposal();
            }
        }
        delete creatorProposalOf[coin];
        for (uint256 i; i < n; ++i) {
            _changeCreator(ids[i], pr.to, false);
        }
    }

    /// @notice Give up creator control of every pool of `coin`, permanently for the creator. Requires a fee split on
    /// every pool; payouts, buyback, liquidity adds and reflections continue. The admin can still reassign each pool
    /// ({setTokenCreator}), which clears the renounce on that pool.
    function renounceCreator(address coin) external nonReentrant {
        PoolId[] storage ids = _requireActiveCreatorOfCoin(coin);
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (creatorSplits[ids[i]].length == 0) {
                revert RenounceNeedsSplit();
            }
        }
        for (uint256 i; i < n; ++i) {
            creatorRenounced[ids[i]] = true;
        }
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
        if (ids.length == 0 || creatorRenounced[ids[0]]) {
            return address(0);
        }
        return _config[ids[0]].creator;
    }

    // ─────────────────────── rescue ───────────────────────

    /// @notice Send `amount` of a token (or native ETH, `address(0)`) that no pool can ever owe to `to`. Admin only.
    /// @dev Refused for any {isPoolAsset}: every pool quote and coin, every configured WETH, and native ETH once a
    /// native pool exists (or while WETH is unset). Refused while the PoolManager is unlocked.
    function rescue(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != admin || admin == address(0)) {
            revert NotAdmin();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (to == address(this)) {
            revert SelfAddress();
        }
        if (isPoolAsset[token] || token == weth) {
            revert RescueForbiddenAsset(token);
        }
        if (_managerAlreadyUnlocked()) {
            revert PendingDistribution();
        }
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) {
                revert RescueFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    /// @dev Set once from {configurePool}; no other writer.
    function _storeSniperWhitelist(PoolId id, address[] calldata wallets) internal {
        uint256 n = wallets.length;
        if (n == 0) {
            return;
        }
        if (n > MAX_SNIPER_WHITELIST) {
            revert WhitelistTooLarge();
        }
        for (uint256 i; i < n; ++i) {
            sniperWhitelisted[id][wallets[i]] = true;
        }
        emit SniperWhitelistSet(id, wallets);
    }

    /// @dev Records the calling launcher's LP locker so {_storeSplit} can refuse it as a split recipient (a locker
    /// cannot claim or forward quote).
    function _recordSeeder(address launcher_) internal {
        (bool ok, bytes memory d) =
            launcher_.staticcall{gas: 20_000}(abi.encodeWithSelector(ILauncherSeeder.lpLocker.selector));
        if (!ok || d.length != 32) {
            return;
        }
        address seeder = address(uint160(abi.decode(d, (uint256))));
        if (seeder != address(0) && !isSeeder[seeder]) {
            isSeeder[seeder] = true;
        }
    }

    /// @dev True for a rewards tracker funded by this hook whose payout asset is not this pool's quote: quote pushed
    /// to it could never be booked. A multi-basket tracker is allowed only if the quote is one of its denominations
    /// (never for native); a tracker without `quote()` is treated as the native tracker.
    function _isForeignTracker(PoolId id, address r) internal view returns (bool) {
        if (r.code.length == 0) {
            return false;
        }
        // Probes copy at most one word of returndata, so a returndata bomb costs nothing extra.
        (bool ok, uint256 w) = _probeWord(r, abi.encodeWithSignature("feeder()"));
        if (!ok || address(uint160(w)) != address(this)) {
            return false;
        }
        (ok, w) = _probeWord(r, abi.encodeWithSignature("isDenomination(address)", _config[id].quote));
        if (ok) {
            return w == 0; // multi-basket tracker
        }
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
                    || _isForeignTracker(id, r) || _isLpLocker(r) // any Realm AnyPairs LP locker, including one not yet recorded
            ) {
                revert RealmAnyPairsSplitLib.BadSplit();
            }
        }
        RealmAnyPairsSplitLib.store(creatorSplits[id], recipients, bps, address(poolManager));
    }

    /// @dev True for a contract shaped like the LP locker: answers `availableOf(address)` and its `poolManager()` is
    /// this hook's PoolManager.
    function _isLpLocker(address r) internal view returns (bool) {
        if (r.code.length == 0) {
            return false;
        }
        (bool ok,) = _probeWord(r, abi.encodeWithSignature("availableOf(address)", address(0)));
        if (!ok) {
            return false;
        }
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
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (!isLauncher[sender]) {
            revert NotLauncher();
        }
        _shape(key, sender); // validates shape + that one side is sender's coin
        return this.beforeInitialize.selector;
    }

    /// @dev The quote currency this pool taxes on (currency0 or currency1) as a Currency + its BalanceDelta side.
    function _quoteCurrency(PoolKey calldata key, bool quoteIsC0) internal pure returns (Currency) {
        return quoteIsC0 ? key.currency0 : key.currency1;
    }

    /// @dev Skims the quote-token tax when the QUOTE is the SPECIFIED currency of the swap.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        _requireTradingOpen(id, c, sender);

        bool c0Specified = (params.zeroForOne == (params.amountSpecified < 0));
        bool quoteSpecified = c.quoteIsC0 ? c0Specified : !c0Specified;
        if (!quoteSpecified) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 amt = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _taxOn(c, params.zeroForOne, amt);
        if (fee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _quoteCurrency(key, c.quoteIsC0).take(poolManager, address(this), fee, true);
        accruedQuote[id] += fee;
        accruedPlatformQuote[id] += _platformCutOn(id, c, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, amt);
        emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Skims the quote-token tax when the QUOTE is the UNSPECIFIED currency of the swap.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        // The coin is the non-quote currency; a positive delta there is coin leaving the pool (a buy).
        _requireUnderMaxBuy(id, c, sender, c.quoteIsC0 ? delta.amount1() : delta.amount0());

        int128 feeReturn = 0;
        uint256 swapTax; // observational only, for {SwapObserved}
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
                    accruedPlatformQuote[
                        id
                    ] += _platformCutOn(id, c, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, amt);
                    emit TaxAccrued(id, c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne, fee);
                    feeReturn = fee.toInt128();
                    swapTax = fee;
                }
            }
        }
        // beforeSwap sized the fee against the requested amount, so check the rate against what actually traded.
        if (!quoteUnspecified) {
            uint256 requested =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 taken = _taxOn(c, params.zeroForOne, requested);
            if (taken != 0) {
                int128 moved = c.quoteIsC0 ? delta.amount0() : delta.amount1();
                uint256 filled = moved < 0 ? uint256(-int256(moved)) : uint256(int256(moved));
                // `filled` excludes the fee on exact-input and already includes it on exact-output.
                uint256 total = params.amountSpecified < 0 ? filled + taken : filled;
                // Reject a short fill charged above the ceiling. The ceiling uses hard constants (never the mutable
                // `maxSideBps`) so a later cap change cannot brick configured pools, and it is widened by the launch tax only
                // for buys on guarded pools, since only buys pay the launch premium. Shared with {launchBuyFee}.
                uint256 ceilBps = _fillCeilBps(
                    (c.hasGuards && (c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne)) ? c.guards.launchTaxBps : 0
                );
                if (taken * BPS > total * ceilBps) {
                    revert FillTooSmallForTax();
                }
                swapTax = taken;
            }
        }
        // Emitted before payouts. Buy direction depends on which currency is the quote.
        emit SwapObserved(
            id,
            sender,
            tx.origin,
            delta.amount0(),
            delta.amount1(),
            swapTax,
            params.amountSpecified < 0,
            c.quoteIsC0 ? params.zeroForOne : !params.zeroForOne
        );
        _maybeAutoDistribute(id, c);
        // After the distribution, which is what credits {buybackPot}.
        _maybeBuyback(key, id, c);
        _maybeAddLiquidity(key, id, c);
        _maybeReflect(key, id, c);
        _maybeConvertRewards(c);
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
    function buybackAndBurnSelf(PoolKey calldata key, uint256 amt) external returns (uint256 spent, uint256 burned) {
        if (msg.sender != address(this)) {
            revert NotSelf();
        }
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
        if (pot == 0 || c.buybackBps == 0) {
            return;
        }
        if (gasleft() < BUYBACK_CONVERT_GAS + SWAP_TAIL_RESERVE) {
            emit BuybackSkipped(id, pot, 0);
            return;
        }
        // Zeroed before the call and restored on failure, so a re-entrant read cannot spend the pot twice.
        buybackPot[id] = 0;
        try this.buybackAndBurnSelf{gas: BUYBACK_CONVERT_GAS}(key, pot) returns (uint256 spent, uint256 burned) {
            // A short fill returns the unspent remainder to the pot.
            if (spent < pot) {
                buybackPot[id] = pot - spent;
            }
            emit BuybackExecuted(id, spent, burned);
        } catch {
            buybackPot[id] = pot;
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
        if (msg.sender != address(this)) {
            revert NotSelf();
        }
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        bool quoteIsC0 = c.quoteIsC0;
        Currency qc = _quoteCurrency(key, quoteIsC0);
        Currency cc = quoteIsC0 ? key.currency1 : key.currency0;

        // ── 1. half the pot buys coin, so the add has both sides ──
        uint256 half = amt / 2;
        if (half == 0) {
            revert NothingToAddLiquidity();
        }
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
        if (coinBought == 0) {
            revert NothingToAddLiquidity();
        }

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
        if (liq == 0) {
            revert NothingToAddLiquidity();
        }

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
            poolManager.take(qc, address(this), uint256(netQ));
        }
        if (netC < 0) {
            cc.settle(poolManager, address(this), uint256(-netC), false);
        } else if (netC > 0) {
            // Leftover coin and returned fees go to the burn sink; this contract has no sweep.
            poolManager.take(cc, BURN_SINK, uint256(netC));
        }

        // What the pot actually paid is the NET quote that left, never the nominal request.
        spentQuote = netQ < 0 ? uint256(-netQ) : 0;
        if (spentQuote > amt) {
            spentQuote = amt;
        }
    }

    /// @dev In-swap attempt, mirroring {_maybeBuyback}: gas-gated, pot zeroed before the call, restored on failure.
    function _maybeAddLiquidity(PoolKey calldata key, PoolId id, TaxConfig storage c) internal {
        uint256 pot = lpPot[id];
        if (pot == 0 || c.lpBps == 0) {
            return;
        }
        if (gasleft() < LP_CONVERT_GAS + SWAP_TAIL_RESERVE) {
            emit AutoLiquiditySkipped(id, pot, 0);
            return;
        }
        lpPot[id] = 0;
        try this.addLiquiditySelf{gas: LP_CONVERT_GAS}(key, pot) returns (uint256 spent, uint128 liq) {
            if (spent < pot) {
                lpPot[id] = pot - spent;
            }
            emit AutoLiquidityAdded(id, spent, liq);
        } catch {
            lpPot[id] = pot;
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
        if (!_config[id].configured) {
            revert NotConfigured();
        }
        uint256 pot = lpPot[id];
        if (pot == 0) {
            revert NothingToAddLiquidity();
        }
        lpPot[id] = 0;
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_ADDLIQ, key, pot));
        (spent, liquidityAdded) = abi.decode(ret, (uint256, uint128));
        if (spent < pot) {
            lpPot[id] = pot - spent;
        }
        emit AutoLiquidityAdded(id, spent, liquidityAdded);
    }

    // ═══════════════════════════ REFLECTIONS EXECUTION ════════════════════════════════════
    // Like the buyback, but the coin goes to the rewards tracker, which books its own measured balance increase.

    /// @dev Self-only so {_maybeReflect} can wrap it in a try/catch; called directly by {runReflect}.
    function reflectSelf(PoolKey calldata key, uint256 amt) external returns (uint256 spent, uint256 coinToHolders) {
        if (msg.sender != address(this)) {
            revert NotSelf();
        }
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        address tracker = c.rewardsTracker;
        if (tracker == address(0)) {
            revert NothingToReflect();
        }
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
        if (pot == 0) {
            return;
        }
        if (gasleft() < REFLECT_CONVERT_GAS + SWAP_TAIL_RESERVE) {
            emit ReflectionSkipped(id, pot, 0);
            return;
        }
        reflectPot[id] = 0;
        try this.reflectSelf{gas: REFLECT_CONVERT_GAS}(key, pot) returns (uint256 spent, uint256 coin) {
            if (spent < pot) {
                reflectPot[id] = pot - spent;
            }
            emit ReflectionPaid(id, spent, coin);
        } catch {
            reflectPot[id] = pot;
            emit ReflectionSkipped(id, pot, 1);
        }
    }

    /// @dev Let an auto-converting tracker convert one buffered leg after a swap. Low-level and gas-capped, so neither
    /// a revert nor a hostile return can affect the swap.
    function _maybeConvertRewards(TaxConfig storage c) internal {
        if (!c.rewardsAutoConvert) {
            return;
        }
        if (gasleft() < REWARD_CONVERT_GAS + SWAP_TAIL_RESERVE) {
            return;
        }
        (bool ok,) = c.rewardsTracker.call{gas: REWARD_CONVERT_GAS}(abi.encodeWithSignature("convertStep()"));
        ok; // failure is a deferral: the buffer stays for the next swap or a manual call
    }

    /// @notice Convert this pool's accrued reflection slice into coin and book it for holders now.
    /// @dev Permissionless and uncapped, like {runBuyback} and {runAddLiquidity}.
    function runReflect(PoolKey calldata key) external nonReentrant returns (uint256 spent, uint256 coin) {
        PoolId id = key.toId();
        if (!_config[id].configured) {
            revert NotConfigured();
        }
        uint256 pot = reflectPot[id];
        if (pot == 0) {
            revert NothingToReflect();
        }
        reflectPot[id] = 0;
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_REFLECT, key, pot));
        (spent, coin) = abi.decode(ret, (uint256, uint256));
        if (spent < pot) {
            reflectPot[id] = pot - spent;
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
        uint256 pot = buybackPot[id];
        if (pot == 0) {
            revert NothingToBuyBack();
        }
        buybackPot[id] = 0;
        // Off-swap the PoolManager is locked, so the work runs inside an unlock.
        bytes memory ret = poolManager.unlock(abi.encode(UNLOCK_BUYBACK, key, pot));
        (spent, burned) = abi.decode(ret, (uint256, uint256));
        if (spent < pot) {
            buybackPot[id] = pot - spent;
        }
        emit BuybackExecuted(id, spent, burned);
    }

    /// @dev The tax on `amount` at an explicit rate, floored.
    function _taxAt(uint256 bps, uint256 amount) internal pure returns (uint256) {
        if (bps == 0 || amount == 0) {
            return 0;
        }
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
        if (amount == 0) {
            return 0;
        }
        return FullMath.mulDiv(amount, totalBps * 100, FEE_DENOM);
    }

    /// @dev afterSwap's {FillTooSmallForTax} ceiling, in bps of the total. `launchTaxBps` must be passed as 0 unless
    /// the pool is guarded AND the swap is a buy -- the buys-only premium may widen only the buyer's bound.
    function _fillCeilBps(uint16 launchTaxBps) internal pure returns (uint256 ceilBps) {
        ceilBps = uint256(FILL_TOLERANCE_BPS) + FILL_PLATFORM_HEADROOM_BPS;
        uint256 ramp = uint256(launchTaxBps) + FILL_PLATFORM_HEADROOM_BPS;
        if (ramp > ceilBps) {
            ceilBps = ramp;
        }
    }

    /// @dev The launch-tax parameter rule, shared by {_guardsFor} (configurePool) and {launchBuyFee}.
    function _requireLaunchTaxOk(uint16 launchTaxBps, uint16 launchTaxSecs) internal pure {
        if ((launchTaxBps == 0) != (launchTaxSecs == 0)) {
            revert BadLaunchGuard();
        }
        if (launchTaxBps > MAX_LAUNCH_TAX_BPS || launchTaxSecs > MAX_LAUNCH_TAX_SECS) {
            revert BadLaunchGuard();
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
        uint256 amount = accruedQuote[id];
        if (amount == 0) {
            revert NothingAccrued();
        }
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
        if (settled == 0 && !drained) {
            revert NothingAccrued();
        }
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
        if (n == 0 || n > MAX_CLAIM_BATCH) {
            revert BadBatchLength();
        }
        for (uint256 i; i < n; ++i) {
            // Stop before a forwarded call could exhaust the gas needed to finish; the returned counts show progress.
            if (gasleft() < CLAIM_ONE_GAS_CAP + CLAIM_BATCH_TAIL) {
                break;
            }
            // A drained parked slot paid the platform even with `amt == 0`, so it counts as paid, not skipped.
            try this.claimPlatformOne{gas: CLAIM_ONE_GAS_CAP}(ids[i]) returns (uint256 amt, bool drained) {
                if (amt != 0 || drained) {
                    unchecked {
                        ++paidPools;
                    }
                } else {
                    emit PlatformClaimSkipped(ids[i]);
                    unchecked {
                        ++skippedPools;
                    }
                }
            } catch {
                emit PlatformClaimSkipped(ids[i]);
                unchecked {
                    ++skippedPools;
                }
            }
        }
    }

    /// @dev Self-only trampoline so {claimPlatformMany} can meter and catch each pool. Not `nonReentrant`: the batch
    /// already holds the guard.
    /// @return settled What came out of `accruedPlatformQuote`.
    /// @return drained Whether this call emptied a parked platform ring slot.
    function claimPlatformOne(PoolId id) external returns (uint256 settled, bool drained) {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        return _settlePlatform(id);
    }

    /// @return plat what was settled out of `accruedPlatformQuote`.
    /// @return drained whether a parked platform ring slot was actually emptied (a walk short of gas leaves it parked).
    function _settlePlatform(PoolId id) internal returns (uint256 plat, bool drained) {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        plat = accruedPlatformQuote[id];
        uint256 acc = accruedQuote[id];
        // Defensive clamp; `plat <= acc` always holds.
        if (plat > acc) {
            plat = acc;
        }
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
        if (!c.configured) {
            revert NotConfigured();
        }
        uint256 acc = accruedQuote[id];
        uint256 plat = accruedPlatformQuote[id];
        if (plat > acc) {
            plat = acc;
        }
        settled = acc - plat;
        if (settled == 0) {
            revert NothingAccrued();
        }
        accruedQuote[id] = plat;
        poolManager.unlock(abi.encode(UNLOCK_DISTRIBUTE, id, settled, 0, FLUSH_CREATOR));
    }

    /// @notice Claim your accrued fees for `token`. Paid in ETH when a quote→WETH path is configured, otherwise in the
    /// raw quote. `minWethOut` is the conversion's slippage floor; if it cannot be met the claim falls back to the raw
    /// quote. Pass 0 only if you accept that.
    /// @dev `owed[]` is paid nominally, first come first served; rebasing-down quotes are unsupported.
    function claim(address token, uint256 minWethOut)
        external
        nonReentrant
        returns (uint256 amountPaid, address tokenPaid)
    {
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
        if (to == address(0)) {
            revert ZeroAddress();
        }
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
    function convertToWeth(address recipient, address token, bytes memory path, uint256 amount, uint256 minOut)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        // Body lives in the library for size; the self-only check stays here so the try has a real frame to cap and catch.
        return RealmAnyPairsSplitLib.swapToWeth(recipient, token, path, amount, minOut, swapRouter, weth);
    }

    /// @notice Deliver `who`'s accrued balance of `token` to `who`. Permissionless; funds can only go to `who`.
    /// @dev For contract payees that cannot call {claim} themselves (e.g. a dividend tracker, whose `sync()` then books
    /// the transfer). `owed[]` is paid nominally; rebasing-down quotes are unsupported.
    function pushOwed(address who, address token) external nonReentrant returns (uint256 amount) {
        // Contracts only: an EOA can call {claim} itself, and a third-party push would strip its choice of payout asset.
        if (who.code.length == 0) {
            revert NotAContract();
        }
        amount = owed[who][token];
        if (amount == 0) {
            revert NothingAccrued();
        }
        owed[who][token] = 0;
        // Native: try a plain send, then `feed{value:}` (the native tracker has no `receive`); if both fail the frame
        // reverts and the `owed` entry is restored. Native reports `amount` (all-or-nothing); ERC20 reports the measured
        // balance increase, so a fee-on-transfer quote is reported accurately.
        uint256 delivered;
        if (token == address(0)) {
            (bool ok,) = payable(who).call{value: amount}("");
            if (!ok) {
                try IDividendFeeder(who).feed{value: amount}() {}
                catch {
                    revert EthTransferFailed();
                }
            }
            delivered = amount;
        } else {
            // Saturating: a bare subtraction would revert a successful transfer if `who` ends with less.
            uint256 before = IERC20(token).balanceOf(who);
            IERC20(token).safeTransfer(who, amount);
            uint256 aft = IERC20(token).balanceOf(who);
            delivered = aft > before ? aft - before : 0;
        }
        // The ledger debit is the full entry; only the reported amount reflects what arrived.
        emit Claimed(who, token, delivered);
        amount = delivered;
    }

    /// @dev Accepts native ETH from the PoolManager only (native `take`s). Any other ETH would be unbacked and stuck.
    receive() external payable {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
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
        // Revert rather than return: callers have already zeroed the accrual, and reverting restores it (e.g. a frozen
        // quote whose transfer silently does nothing).
        if (received == 0) {
            revert NothingAccrued();
        }

        // Scale the platform's cut by what actually arrived, sharing any transfer fee proportionally.
        uint256 toPlatform = amount == 0 ? 0 : plat * received / amount;
        amount = received;
        if (toPlatform > amount) {
            toPlatform = amount;
        }
        uint256 creatorPool = amount - toPlatform;
        // Every slice is a share of the same base, snapshotted before any is taken. Slices floor, so rounding
        // remainders stay with the creator; each is also clamped to what remains.
        uint256 sliceBase = creatorPool;

        // ── divide now, push as gas allows ──
        // Each slice is booked to its payee's ring slot, then {_runQueue} pushes what `gasleft()` affords; the rest
        // waits for a later swap, {runPayouts} or the pull ledger.
        if (toPlatform > 0) {
            // Book the platform and referral cuts to the ring for in-swap push; failures credit `owed[]` and emit
            // {FeeCutPaid}. The referrer is paid out of the platform's share, and the platform keeps rounding remainders.
            address ref = referrerOf[id];
            uint256 toRef = ref != address(0) ? toPlatform * REFERRAL_BPS / BPS : 0;
            if (toRef != 0) {
                _bookSlot(id, PAY_SLOT_REFERRAL, ref, quote, toRef);
                emit ReferralCredited(id, ref, quote, toRef);
            }
            _bookSlot(id, PAY_SLOT_PLATFORM, platform, quote, toPlatform - toRef);
        }

        // FLUSH_PLATFORM leaves `creatorPool` at 0; skip the creator side so a large split is never walked for nothing.
        if (mode != FLUSH_PLATFORM) {
            address tracker = c.rewardsTracker;
            if (tracker != address(0) && c.rewardsBps != 0 && creatorPool != 0) {
                uint256 toRewards = sliceBase * c.rewardsBps / BPS;
                if (toRewards > creatorPool) {
                    toRewards = creatorPool;
                }
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
                if (toBuyback > creatorPool) {
                    toBuyback = creatorPool;
                }
                if (toBuyback != 0) {
                    creatorPool -= toBuyback;
                    buybackPot[id] += toBuyback;
                    emit BuybackAccrued(id, toBuyback);
                }
            }

            // ── auto-liquidity, carved from the SAME creatorPool, after the buyback slice ──
            if (mode != FLUSH_PLATFORM && c.lpBps != 0 && creatorPool != 0) {
                uint256 toLp = sliceBase * c.lpBps / BPS;
                if (toLp > creatorPool) {
                    toLp = creatorPool;
                }
                if (toLp != 0) {
                    creatorPool -= toLp;
                    lpPot[id] += toLp;
                    emit AutoLiquidityAccrued(id, toLp);
                }
            }

            bool push = c.autoSend;
            RealmAnyPairsSplitLib.Split[] storage sp = creatorSplits[id];
            if (sp.length == 0) {
                // Split-less pool: the creator IS split slot 0, at ring index PAY_SLOT_SPLIT_BASE.
                if (creatorPool > 0) {
                    if (push) {
                        _bookSlot(id, PAY_SLOT_SPLIT_BASE, c.creator, quote, creatorPool);
                    } else {
                        owed[c.creator][quote] += creatorPool;
                    }
                }
            } else {
                uint256 rem = creatorPool;
                uint256 last = sp.length - 1;
                for (uint256 i; i <= last; i++) {
                    uint256 part = i == last ? rem : (creatorPool * sp[i].bps) / BPS;
                    rem -= part;
                    if (part > 0) {
                        // Pull-mode pools book straight to `owed[]`.
                        if (push) {
                            _bookSlot(id, PAY_SLOT_SPLIT_BASE + i, sp[i].to, quote, part);
                        } else {
                            owed[sp[i].to][quote] += part;
                        }
                    }
                }
            }
        }

        emit TaxDistributed(id, creatorPool, toPlatform);
        // A platform-only flush walks only platform slots and leaves the cursor alone, so a hostile creator recipient
        // cannot interfere and platform sweeps cannot drive the creator ring's rotation.
        if (mode == FLUSH_PLATFORM) {
            _runQueueMasked(id, quote, native, RING_PLATFORM, false);
        } else if (mode == FLUSH_CREATOR) {
            _runQueueMasked(id, quote, native, RING_CREATOR, true);
        } else {
            _runQueue(id, quote, native);
        }
    }

    /// @dev Assign `amt` of `quote` in ring slot `i` to `to`, for a later push. Anything that cannot use the slot is
    /// booked to `owed[]` instead, so nothing is lost.
    function _bookSlot(PoolId id, uint256 i, address to, address quote, uint256 amt) internal {
        if (amt == 0) {
            return;
        }
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
        if (mask & filter == 0) {
            return 0;
        }
        // Bits cleared by this walk, so the final store can be a masked update.
        uint32 cleared;
        uint256 start = payCursor[id];
        uint256 i = start;
        uint256 park = PAY_SLOTS; // PAY_SLOTS == "nothing was skipped"
        for (uint256 k; k < PAY_SLOTS; ++k) {
            if (mask & filter & uint32(1 << i) != 0) {
                // Only the rewards slot is a feed; platform, referral and split slots use the push floors. The swap tail is
                // already withheld by the caller's gas cap, so it is not charged again here.
                uint256 floorGas = i == PAY_SLOT_REWARDS
                    ? (native ? PAY_FLOOR_FEED_NATIVE : PAY_FLOOR_FEED_TOKEN)
                    : (native ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN);
                if (gasleft() < floorGas) {
                    if (park == PAY_SLOTS) {
                        park = i; // remember the FIRST one we could not afford
                    }
                } else {
                    PaySlot storage sl = _paySlots[id][i];
                    address to = sl.to;
                    uint256 amt = sl.amt;
                    sl.to = address(0); // CEI: clear before any external call
                    sl.amt = 0;
                    mask &= ~uint32(1 << i);
                    cleared |= uint32(1 << i);
                    if (i == PAY_SLOT_REWARDS) {
                        _payRewardsSlot(id, to, quote, amt, native);
                    } else if (i == PAY_SLOT_PLATFORM || i == PAY_SLOT_REFERRAL) {
                        _payPlatformSlot(id, i, to, quote, amt);
                    } else {
                        _payCreatorShare(to, quote, amt);
                    }
                    unchecked {
                        ++pushed;
                    }
                }
            }
            unchecked {
                i = i + 1 == PAY_SLOTS ? 0 : i + 1;
            }
        }
        // Masked update (`& ~cleared`), not an absolute write of the pre-call snapshot, so a bit set during the walk
        // is never lost.
        uint32 stored = pendingMask[id] & ~cleared;
        pendingMask[id] = stored;
        uint256 next = park == PAY_SLOTS ? i : park; // `i` is back at `start` after a full lap
        if (!moveCursor) {
            next = start;
        }
        // The cursor is only a rotation hint, so an absolute write is fine.
        if (next != start) {
            payCursor[id] = uint8(next);
        }
        // Emit the stored mask, not the pre-call local.
        emit PayoutsProcessed(id, pushed, stored, uint8(next));
    }

    /// @dev Push for a platform-side slot ({PAY_SLOT_PLATFORM}, {PAY_SLOT_REFERRAL}). Native only to a codeless
    /// address; ERC20 only when {_inSwapAllowed}, through the capped {pushSplit}. Any failure credits
    /// `owed[to][quote]` in full; {FeeCutPaid} reports which happened.
    function _payPlatformSlot(PoolId id, uint256 slot, address to, address quote, uint256 amt) internal {
        if (quote == address(0)) {
            if (to.code.length == 0) {
                (bool ok,) = to.call{value: amt}("");
                if (ok) {
                    emit FeeCutPaid(id, to, quote, amt, uint8(slot), true);
                    return;
                }
            }
        } else if (_inSwapAllowed(quote)) {
            try this.pushSplit{gas: SPLIT_PUSH_LIVENESS_CAP}(to, quote, amt) returns (uint256 delivered) {
                emit FeeCutPaid(id, to, quote, delivered, uint8(slot), true);
                return;
            } catch {}
        }
        owed[to][quote] += amt;
        emit FeeCutPaid(id, to, quote, amt, uint8(slot), false);
    }

    /// @dev Push for the rewards slot. On failure the slice is credited to the tracker, never the creator. The delivered
    /// amount is measured inside {pushRewards}, so a quote whose `balanceOf` reverts or burns gas for the tracker fails
    /// into the catch like any other push instead of reverting the whole distribution.
    function _payRewardsSlot(PoolId id, address tracker, address quote, uint256 amt, bool native) internal {
        try this.pushRewards{gas: _feedGasCap(native)}(tracker, quote, amt) returns (uint256 delivered) {
            emit RewardsRouted(id, tracker, delivered);
        } catch {
            // Nothing was delivered, so the full `amt` is still owed to the tracker.
            owed[tracker][quote] += amt;
        }
    }

    /// @notice Push whatever `id`'s payout ring can afford right now. Permissionless: money only goes to recorded payees.
    /// @dev Drains a ring funded by the final swap of an idle pool.
    function runPayouts(PoolId id) external nonReentrant returns (uint256 pushed) {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
            if (mask & uint32(1 << i) != 0) {
                total += _paySlots[id][i].amt;
            }
        }
    }

    /// @dev Transfer the rewards slice and let the tracker book its own measured increase. No amount is passed, since
    /// a hostile quote could make any hook-side figure wrong. Returns what the transfer delivered, for the event only.
    function pushRewards(address tracker, address quote, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        // Native: `feed{value:}` is both the transfer and the booking, so a failure reverts and {_payRewardsSlot}
        // credits the slice to `owed[tracker][address(0)]` for {pushOwed} to deliver.
        if (quote == address(0)) {
            IDividendFeeder(tracker).feed{value: amt}();
            return amt;
        }
        uint256 before = IERC20(quote).balanceOf(tracker);
        IERC20(quote).safeTransfer(tracker, amt);
        uint256 aft = IERC20(quote).balanceOf(tracker);
        // Saturating: a hostile quote must not over-report.
        delivered = aft > before ? aft - before : 0;
        if (delivered > amt) {
            delivered = amt;
        }
        // Booking is best-effort; the transfer must stand. If `feedToken` fails (e.g. the tracker is reentrancy-locked)
        // the quote is already at the tracker, and its permissionless `sync()` books it later.
        try IDividendFeederToken(tracker).feedToken(0) {} catch {} // arg ignored; the tracker measures itself
    }

    /// @dev Gas an in-swap distribution of `id` must have to be attempted: base + one booking per payee + the cheapest
    /// push floor + {SWAP_TAIL_RESERVE}. Further pushes are deferred, not lost. Keyed on the quote because native pushes
    /// are much cheaper. Referral/buyback/LP pot writes are not reserved, so at the exact boundary a large pool may book
    /// without pushing.
    function _autoDistributeNeed(PoolId id, TaxConfig storage c) internal view returns (uint256 need) {
        bool native = c.quote == address(0);
        // Slots this distribution will book: one per split recipient (or the bare creator), plus rewards if set.
        uint256 slots = creatorSplits[id].length;
        if (slots == 0) {
            slots = 1;
        }
        // The platform slot is booked on every distribution; a referred pool also books {PAY_SLOT_REFERRAL}.
        ++slots;
        if (referrerOf[id] != address(0)) {
            ++slots;
        }

        if (c.rewardsTracker != address(0) && c.rewardsBps != 0) {
            ++slots;
        }
        need = AUTO_DISTRIBUTE_BASE + slots * AUTO_DISTRIBUTE_PER_SPLIT + SWAP_TAIL_RESERVE;
        need += native ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN;
    }

    /// @notice Gas an in-swap auto-distribution of `id` reserves (redeem plus one payout). Wallet estimates settle on the
    /// cheaper deferral path, so a frontend that wants in-swap payouts should add this to its estimate.
    function autoDistributeGasNeed(PoolId id) external view returns (uint256) {
        return _autoDistributeNeed(id, _config[id]);
    }

    /// @dev Per-swap payout step, in two independent parts: (1) redeem the pot if it is over the threshold, affordable
    /// and not latched; (2) otherwise still walk the ring so payees booked by earlier swaps get paid.
    function _maybeAutoDistribute(PoolId id, TaxConfig storage c) internal {
        if (!c.autoEnabled) {
            return;
        }
        uint256 acc = accruedQuote[id];
        // Skip the redeem while latched (no event; it would fire every swap). The ring walk below still runs.
        if (c.autoThreshold != 0 && acc >= c.autoThreshold && !c.autoRedeemLatched) {
            if (gasleft() >= _autoDistributeNeed(id, c)) {
                uint256 plat = accruedPlatformQuote[id];
                accruedQuote[id] = 0;
                accruedPlatformQuote[id] = 0;
                // {_distribute} walks the ring itself. The explicit gas cap withholds {SWAP_TAIL_RESERVE} so the swap can always
                // finish, and {AUTO_DISTRIBUTE_MAX} bounds the trader's cost. The precheck guarantees no underflow.
                uint256 payBudget = gasleft() - SWAP_TAIL_RESERVE;
                if (payBudget > AUTO_DISTRIBUTE_MAX) {
                    payBudget = AUTO_DISTRIBUTE_MAX;
                }
                // Latch only if the attempt proves the pool can never redeem in-swap: it had the full ceiling (not a budget
                // clamped by a thin trade) AND spent at least AUTO_REDEEM_SPEND_NUM/DEN of it. A cheap revert, such as the
                // first buy of a pool before the router settles, must not latch.
                bool fullBudget = payBudget == AUTO_DISTRIBUTE_MAX;
                uint256 gasBefore = gasleft();
                try this.autoDistribute{gas: payBudget}(id, acc, plat) {}
                catch {
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
        uint256 walkFloor = SWAP_TAIL_RESERVE + (c.quote == address(0) ? PAY_FLOOR_PUSH_NATIVE : PAY_FLOOR_PUSH_TOKEN);
        if (pendingMask[id] != 0 && gasleft() > walkFloor) {
            // Same bounds as the redeem path: the withheld tail and {AUTO_DISTRIBUTE_MAX}.
            uint256 walkBudget = gasleft() - SWAP_TAIL_RESERVE;
            if (walkBudget > AUTO_DISTRIBUTE_MAX) {
                walkBudget = AUTO_DISTRIBUTE_MAX;
            }
            try this.runPayouts{gas: walkBudget}(id) {} catch {}
        }
    }

    /// @dev `nonReentrant` is load-bearing: this is the only quote-moving entry point reachable from a swap, so a
    /// callback quote cannot re-enter a claim mid-distribution. A blocked re-entry makes {pushRewards} revert, and
    /// {_payRewardsSlot} credits the slice to `owed[tracker][quote]`.
    function autoDistribute(PoolId id, uint256 amount, uint256 plat) external nonReentrant {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
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
            if (to.code.length == 0) {
                (bool ok,) = to.call{value: amt}("");
                if (ok) {
                    emit CreatorSharePushed(to, quote, amt);
                    return;
                }
            }
        } else if (_inSwapAllowed(quote)) {
            try this.pushSplit{gas: SPLIT_PUSH_LIVENESS_CAP}(to, quote, amt) returns (uint256 delivered) {
                // Report `delivered`, not `amt`; the difference is not held by the hook.
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
        if (r == address(0)) {
            return true;
        }
        (bool ok, bytes memory d) = r.staticcall{gas: 20_000}(abi.encodeWithSignature("denied(address)", quote));
        // Raw word, not `abi.decode(d, (bool))`: a non-0/1 word would revert this frame instead of reading as denied.
        if (!ok || d.length != 32) {
            return false;
        }
        return abi.decode(d, (uint256)) == 0;
    }

    /// @dev External-self-only so {_payCreatorShare} can try/catch the transfer (`safeTransfer` bubbles). ERC20 only.
    /// Re-measured so a fee-on-transfer quote is reported correctly.
    /// @return delivered what the recipient's balance actually rose by.
    function pushSplit(address to, address quote, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        uint256 before = IERC20(quote).balanceOf(to);
        IERC20(quote).safeTransfer(to, amt);
        uint256 aft = IERC20(quote).balanceOf(to);
        // Saturating: a recipient that forwards the quote onward must not make a successful transfer revert.
        delivered = aft > before ? aft - before : 0;
    }

    /// @notice Turn in-swap auto-send on/off for a pool. Creator only.
    function setAutoSend(PoolId id, bool on) external nonReentrant {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        _requireActiveCreator(c, id);
        _setAutoSend(c, id, on);
    }

    /// @notice Same, as the platform. Lets a mis-set pool be corrected without touching the creator role.
    function adminSetAutoSend(PoolId id, bool on) external onlyOwnerOrAdmin {
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
        _setAutoSend(c, id, on);
    }

    /// @notice Arm or clear the in-swap redeem latch for `id`. Platform or admin only.
    /// @dev Clearing makes the next swap over the threshold retry at full cost; if it still fails the pool re-latches.
    /// The creator is excluded so they cannot repeatedly bill traders for doomed attempts. Survives renounce.
    function resetAutoRedeem(PoolId id, bool latched) external {
        if (msg.sender != platform && (msg.sender != admin || admin == address(0))) {
            revert NotPlatformOrAdmin();
        }
        TaxConfig storage c = _config[id];
        if (!c.configured) {
            revert NotConfigured();
        }
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
            address creator,
            uint16 buyBps,
            uint16 sellBps,
            bool configured,
            bool autoEnabled,
            bool autoSend,
            bool quoteIsC0,
            address quote,
            address rewardsTracker,
            uint16 rewardsBps,
            uint80 autoThreshold
        )
    {
        TaxConfig storage c = _config[id];
        return (
            c.creator,
            c.buyBps,
            c.sellBps,
            c.configured,
            c.autoEnabled,
            c.autoSend,
            c.quoteIsC0,
            c.quote,
            c.rewardsTracker,
            c.rewardsBps,
            c.autoThreshold
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
    function _effectiveBps(TaxConfig storage c, bool isBuy) internal view returns (uint16) {
        uint16 normal = isBuy ? c.buyBps : c.sellBps;
        if (!c.hasGuards) {
            return normal; // slot 0 only; never touches the guard slot
        }
        // Buys only: the launch tax deters snipers, and sellers can always exit at the advertised sell rate.
        if (!isBuy) {
            return normal;
        }
        uint16 startBps = c.guards.launchTaxBps;
        if (startBps <= normal) {
            return normal; // also covers startBps == 0 (feature off)
        }
        uint16 window = c.guards.launchTaxSecs;
        // Seconds, anchored to when trading opens (not launch), so a trading delay does not consume the window.
        // Clamped below so the public view cannot underflow before the open.
        uint256 anchor = c.guards.tradingOpensAt != 0 ? uint256(c.guards.tradingOpensAt) : uint256(c.guards.launchTime);
        uint256 elapsed = block.timestamp <= anchor ? 0 : block.timestamp - anchor;
        if (window == 0 || elapsed >= window) {
            return normal;
        }
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
            if (maxBuyBps < MIN_MAX_BUY_BPS || maxBuyBps > BPS) {
                revert BadLaunchGuard();
            }
            uint256 cap = FullMath.mulDiv(IERC20Supply(coin).totalSupply(), maxBuyBps, BPS);
            // Resolved to absolute units once, at launch, so enforcement costs no external call per swap.
            // Safe because these tokens are fixed-supply with no mint and no burn hook.
            if (cap == 0 || cap > type(uint128).max) {
                revert BadLaunchGuard();
            }
            maxBuyAmount = uint128(cap);
        }
        // Launch tax rate and window must be set together (window in seconds).
        _requireLaunchTaxOk(launchTaxBps, launchTaxSecs);
        if (delaySecs > MAX_TRADING_DELAY) {
            revert BadLaunchGuard();
        }
    }

    /// @dev Jittered trading-open time. Not a secret and not anti-snipe protection: all inputs are public, the result is
    /// emitted, and a wrapper contract can grind it.
    function _jitteredOpen(uint8 secs) internal view returns (uint40) {
        if (secs == 0) {
            return 0;
        }
        uint256 r = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp, msg.sender)));
        return uint40(block.timestamp + 1 + (r % secs));
    }

    /// @dev Reverts a non-seeder swap before the pool opens.
    function _requireTradingOpen(PoolId id, TaxConfig storage c, address sender) internal view {
        if (!c.hasGuards) {
            return;
        }
        uint40 opensAt = c.guards.tradingOpensAt;
        if (opensAt == 0 || block.timestamp >= opensAt) {
            return;
        }
        if (_inLaunchTx(id, c, sender)) {
            return;
        }
        revert TradingNotOpen();
    }

    /// @dev Rejects a buy that takes this transaction's total coin bought from this pool over the cap. Tracked in
    /// transient storage, so splitting into several swaps does not help. Per transaction and per pool only; holdings
    /// across transactions are bounded by max wallet in the token. The launch transaction's dev buy is exempt once.
    function _requireUnderMaxBuy(PoolId id, TaxConfig storage c, address sender, int128 coinOut) internal {
        if (!c.hasGuards) {
            return;
        }
        // Consume the launch-transaction exemption on first use, so only the locker's dev buy is exempt. Cleared here
        // (not in {_requireTradingOpen}, which runs for the same swap) and before the `cap == 0` check.
        if (_inLaunchTx(id, c, sender)) {
            _clearLaunchTx(id);
            return;
        }
        if (coinOut <= 0) {
            return;
        }
        uint128 cap = c.guards.maxBuyAmount;
        if (cap == 0) {
            return;
        }
        // Whitelisted wallets (matched on tx.origin, since the hook only sees the router) skip the max buy only.
        if (sniperWhitelisted[id][tx.origin]) {
            return;
        }

        bytes32 slot = _txBoughtSlot(id);
        uint256 acc;
        assembly ("memory-safe") {
            acc := tload(slot)
        }
        acc += uint256(int256(coinOut));
        assembly ("memory-safe") {
            tstore(slot, acc)
        }
        if (acc > cap) {
            revert MaxBuyExceeded();
        }
    }

    /// @dev Per-pool, per-transaction running total of coin bought. Distinct from {_launchTxSlot} by prefix.
    function _txBoughtSlot(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("realm.txBought", id));
    }

    /// @notice Creator-only: relax the per-buy cap, or remove it with 0. It can only ever be loosened.
    /// @dev Takes the PoolKey so the coin is derived, not supplied.
    function setMaxBuy(PoolKey calldata key, uint16 maxBuyBps) external nonReentrant {
        PoolId id = key.toId();
        TaxConfig storage c = _config[id];
        // Validate before reading `quoteIsC0`.
        if (!c.configured) {
            revert NotConfigured();
        }
        _requireActiveCreator(c, id);
        address coin = Currency.unwrap(c.quoteIsC0 ? key.currency1 : key.currency0);
        if (c.guards.maxBuyAmount == 0) {
            revert CannotTighten(); // already unlimited; nothing to loosen
        }
        // Locked for {MAX_BUY_LOCK_SECS} after trading opens, so the advertised cap governs real trading.
        // `tradingOpensAt` is 0 when no delay was set.
        uint256 opensAt = c.guards.tradingOpensAt == 0 ? uint256(c.guards.launchTime) : uint256(c.guards.tradingOpensAt);
        if (block.timestamp < opensAt + MAX_BUY_LOCK_SECS) {
            revert TooSoonAfterLaunch();
        }
        uint128 next;
        if (maxBuyBps != 0) {
            if (maxBuyBps > BPS) {
                revert BadLaunchGuard();
            }
            uint256 cap = FullMath.mulDiv(IERC20Supply(coin).totalSupply(), maxBuyBps, BPS);
            if (cap > type(uint128).max) {
                revert BadLaunchGuard();
            }
            next = uint128(cap);
            if (next <= c.guards.maxBuyAmount) {
                revert CannotTighten();
            }
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
