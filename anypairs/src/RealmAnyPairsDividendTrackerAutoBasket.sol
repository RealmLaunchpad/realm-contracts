// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RealmAnyPairsRouteLib} from "./RealmAnyPairsRouteLib.sol";
import {RealmAnyPairsGasLib} from "./RealmAnyPairsGasLib.sol";

interface IAutoBasketExttload {
    function exttload(bytes32 slot) external view returns (bytes32);
}

interface IAutoBasketWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IAutoBasketV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IAutoBasketSwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title RealmAnyPairsDividendTrackerAutoBasket
 * @notice Holder rewards in ANY token or basket of tokens, CONVERTED AUTOMATICALLY and PUSHED automatically,
 *         with every holder's share fixed at the moment the fee arrives.
 *
 *         FLOW
 *           1. FEED. The hook delivers a rewards slice in an INPUT token (the pool's quote; WETH for a native pool). A leg
 *              whose asset IS the input is booked to holders at once. Every other ("converting") leg's share is
 *              credited to holders right away as PENDING input, by their balances at that moment.
 *           2. CONVERT. {convertStep} swaps one leg's whole pending pool into its asset. The tax hook calls it after every
 *              swap on the coin's pools (gas-capped, failure-isolated) -- no keeper; anyone may also call it or {convert}.
 *              Every holder's pending share of that pool becomes the asset at the conversion's rate.
 *           3. PAY. Holders are paid in the assets themselves: auto-pushed (by the coin's transfer poke out of swap, and by
 *              the hook's post-swap call whenever there is nothing to convert), or pulled with {claim}.
 *
 *         MANUAL WAYS OUT, always available to the holder
 *           * {claimPending} -- take your pending share of any not-yet-converted leg instantly, in the input token.
 *           * {claimAs} -- take everything as ONE token of your choice (USDG, native ETH, the quote, anything), each reward
 *             converted through a route your front end passes -- or, on THIS holder-side path only, discovered under
 *             your own per-denomination minimum. Automatic conversion never discovers anything (round 11).
 *
 *         EXACT PER-HOLDER ACCOUNTING. Each converting leg keeps an index of pending-input-per-share and a list of EPOCHS,
 *         one per conversion (or fallback): the index at that moment, the rate, and running sums of rate x index-growth.
 *         A holder's position -- index, pending, epoch -- is settled whenever their balance changes, in O(1) per leg no
 *         matter how many conversions happened since: the pending carried in converts at the first epoch's rate, and
 *         everything accrued after it converts through the running sums. Views compute the same thing without writing.
 *         The cost is paid on every transfer of the coin, per converting leg ({SYNC_PER_LEG_GAS}); the constructor refuses
 *         a configuration whose per-transfer stipend would exceed what the coin forwards ({MAX_AUTO_SYNC_GAS}
 *         -- AUDIT ROUND 14: this used to cite `MAX_TRACKER_SYNC_GAS`, which the constructor never checked and
 *         which was not even declared here any more).
 *
 *         SLIPPAGE. A conversion must return at least `spot x (1 - slippageBps)`, spot = the route pool's current price
 *         net of its LP fee. It bounds price impact; it does NOT stop a sandwich (accepted). Platform-admin-set,
 *         0.1%-50%, default 49% -- wide on purpose, so a conversion lands in the asset holders were promised rather
 *         than falling back to the input.
 *
 *         ROUTES. A leg converts through the route STORED for it, and through nothing else. The creator supplies its
 *         legs' routes as part of the LAUNCH CONFIGURATION; afterwards only the platform admin can change one
 *         ({setRoute}). Any venue, hooked pools included. A leg with no route does not convert: it resolves in the
 *         input on the clocks below. There is no on-chain discovery -- see the note above {MIN_FALLBACK_DELAY} for
 *         why it was removed.
 *         THE RISK, PLAINLY: whoever chose the pool chose the price every future conversion is measured against. A
 *         holder who does not accept it has {claimPending} (paid in the input) and {claimAs} (any token, own minimum).
 *
 *         FALLBACK. A leg whose conversion keeps failing is resolved in the input token instead, on either of two clocks
 *         that a success clears: {fallbackDelay} (platform-admin-set, 1 hour-7 days) of real failures -- route refusals, or the
 *         full budget actually burnt; not a short-budget failure, nor a price refusal inside someone else's unlock -- or
 *         {MAX_FALLBACK_DELAY} of any failure. {setRoute} clears both.
 *
 *         IN-SWAP V4. Inside a swap the PoolManager is already unlocked, so a conversion swaps and settles directly. It never
 *         does so while another caller has a `sync` pending on the PoolManager (read from its transient slot).
 */
contract RealmAnyPairsDividendTrackerAutoBasket {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal constant Q128 = 2 ** 128;
    /// @dev Top bit of an epoch's `rate`: the epoch resolved into the INPUT (a fallback), not the asset.
    uint256 internal constant QUOTE_FLAG = 1 << 255;
    uint16 internal constant BPS = 10_000;
    uint256 internal constant MAX_LEGS = 10;
    uint256 internal constant MAX_TOTAL_LEGS = 60;
    uint256 internal constant ABSOLUTE_MAX_DENOMINATIONS = 25;
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

    /// @notice Product cap on the per-transfer stipend this tracker may publish: one quote plus three converting reward
    /// tokens (170k + 34k x 4 + 80k x 3). The tax hook reserves the heaviest coin's transfer gas on EVERY pool, so this
    /// keeps that platform-wide reserve small. Direct (quote-paid) legs cost no converting-leg gas.
    uint256 public constant MAX_AUTO_SYNC_GAS = RealmAnyPairsGasLib.MAX_TRACKER_STIPEND;
    uint256 internal constant SYNC_BASE_GAS = 170_000;
    uint256 internal constant SYNC_PER_DENOM_GAS = 34_000;
    /// @dev Worst case to settle one holder on one converting leg (two epochs read, three slots written).
    uint256 internal constant SYNC_PER_LEG_GAS = 80_000;

    uint256 internal constant PUSH_GAS = 170_000;
    uint256 internal constant PUSH_TAIL_GAS = 40_000;
    /// @dev Fixed gas of one push of the coin ITSELF (a leg or donation denominated in {token}) on top of the coin's
    /// `minDebit` x 64/63, which {PUSH_GAS} never clears. Measured worst case 50,922 at the heaviest coin (minDebit 571,015,
    /// cold storage, inside an unlock); the rest is margin.
    uint256 internal constant COIN_PUSH_OVERHEAD = 70_000;
    uint256 internal constant GATE_GAS = 65_000;
    /// @dev Reserved for {claimableOf} before a push: a base plus each leg that feeds the denomination.
    uint256 internal constant VIEW_BASE_GAS = 10_000;
    uint256 internal constant VIEW_PER_LEG_GAS = 20_000;
    uint256 internal constant PROCESS_HOLDER_BASE_GAS = 140_000;
    uint256 internal constant PROCESS_HOLDER_PER_DENOM_GAS = 200_000;
    /// @dev Push budget used by {convertStep} when it has nothing to convert.
    uint256 internal constant CONVERT_PUSH_BUDGET = 400_000;

    /// @dev Sized so the hook's fixed 650k post-swap call can forward it IN FULL (650k less the step's prologue and the
    /// tail, x63/64): in-swap, running out of this budget is then a property of the route, never of the trader's gas.
    /// A real stock conversion measured ~250k on a Robinhood fork.
    /// @dev AUDIT ROUND 11: nothing but the swap itself is charged against this budget any more. Route discovery,
    /// which round 9 had to move OUT of this frame because probing measured up to ~106k, no longer exists: the route is
    /// a single SLOAD of the leg's stored route. This number is unchanged.
    uint256 internal constant CONVERT_GAS_MAX = 350_000;
    uint256 internal constant CONVERT_GAS_MIN = 150_000;
    uint256 internal constant CONVERT_TAIL_GAS = 150_000;
    uint256 internal constant CONVERT_SCAN = 3;
    /// @dev Gas a holder-side conversion in {claimAs} may spend per denomination.
    uint256 internal constant LEG_GAS_CAP = 450_000;

    /// @notice What a {distributeFor} caller is paid, in bps of the rewards that call actually delivers, skimmed
    /// from the delivery itself. Fixed at 2%, matching {RealmAnyPairsPlatformFeeConverter.MAX_REIMBURSE_BPS}; a
    /// creator-settable rate would be a lever to grief searchers or holders, so there is no setter.
    uint256 public constant POKE_FEE_BPS = 200;
    /// @notice Most addresses one {distributeFor} call may repair before it distributes.
    uint256 public constant MAX_POKE_SYNC = 64;
    /// @notice How long this tracker must be dead -- no distribution, no payout, eligible supply still under
    /// {minEligibleFloor} -- before {sweepStranded} can take its stranded buffers.
    uint256 public constant RESCUE_DELAY = 180 days;
    /// @dev Transient namespace for the per-denomination poke accrual. A transient mapping cannot be declared,
    /// so the slot is derived per denomination; transient storage also guarantees a second poke in the same
    /// transaction starts from zero and that nothing can be left stranded across transactions.
    bytes32 private constant _POKE_ACC_NS = keccak256("realm.anypairs.autobasket.pokeacc");

    /// @notice The band a STORED (admin-vetted) route is quoted on out of the box: 49%.
    /// @dev AUDIT ROUND 9. Deliberately wide. The band's only job on a stored route is to stop a conversion landing at a
    /// price the admin's pool could not have produced; it never stops a sandwich (a sandwicher sets the pre-swap spot the
    /// band is measured against). A tight band on a real pool mostly produces {BelowMinOut}, which resolves the leg into
    /// the INPUT instead of the asset the holder was promised -- the worse outcome. The platform accepts the wider
    /// sandwich exposure so conversions succeed.
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 4_900;
    uint16 public constant MIN_SLIPPAGE_BPS = 10;
    uint16 public constant MAX_SLIPPAGE_BPS = 5_000;
    // ─── NO ON-CHAIN ROUTE DISCOVERY (audit round 11, product decision) ───
    //
    // A leg converts through the route stored for it, and through nothing else. The tracker never goes looking for a
    // pool. Discovery was tried across three audit rounds and broken in each one by the same move: the conversion
    // prices itself off the pool it is about to trade on, so whoever can move that pool inside one transaction sets
    // the price the holders' rewards are sold at. Every defence -- a liquidity floor, a size cap, cross-pool
    // corroboration, a cross-block price anchor -- was defeated by rigging the pool, poking the permissionless
    // converter, and un-rigging in the same transaction, leaving the pool honest at every block boundary and so
    // exposed to no arbitrage at all. Nothing short of a price source the attack transaction cannot move (an
    // out-of-block TWAP) fixes that, and the product does not want to depend on one.
    //
    // So the route is CHOSEN, not found: set at launch by the creator as part of the launch configuration, and
    // changed afterwards only by the platform admin ({setRoute}). Any pool, any venue, hooked pools included; no
    // allowlist and no approval. The risk that carries is stated plainly in {setRoute} and in the integration
    // checklist: whoever picked the pool picked the price every future conversion is measured against.
    uint256 public constant MIN_FALLBACK_DELAY = 1 hours;
    uint256 public constant MAX_FALLBACK_DELAY = 7 days;

    bytes32 internal constant V4_IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    /// @dev v4-core `CurrencyReserves.CURRENCY_SLOT`: the currency of a pending `sync`, zero when none is pending.
    bytes32 internal constant V4_SYNCED_CURRENCY_SLOT =
        0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;

    address public immutable token;
    address public immutable feeder;
    address public immutable swapRouter;
    address public immutable v3Factory;
    address public immutable poolManager;
    address public immutable weth;
    uint256 public immutable minEligibleFloor;
    uint256 public minEligible;
    uint16 public slippageBps;
    uint256 public fallbackDelay;

    struct Leg {
        address asset;
        uint16 bps;
    }

    struct InputBasket {
        address input;
        Leg[] legs;
        /// @dev The route each CONVERTING leg converts through, in the same order as {legs}.
        ///
        /// LENGTH: EMPTY -- in which case every leg starts routeless -- or EXACTLY as long as {legs}. Any other
        /// length reverts {RoutesLengthMismatch} in the constructor; see the round-12 note at that check for the
        /// three silent failures a short or surplus array used to produce. A front end must NOT trim trailing
        /// routeless entries: inside a full-length array an EMPTY entry is how "this leg has no route" is spelled,
        /// and that leg pays out in the input until the platform admin sets one ({setRoute}). A non-empty entry at a
        /// DIRECT leg (`asset == input`) reverts {RouteAtDirectLeg}.
        /// AUDIT ROUND 11 (product decision): routes are part of the LAUNCH configuration, chosen by the creator and
        /// fixed before anyone can buy. After launch only the platform admin can change one ({setRoute}), so a
        /// healthy route cannot be flipped to a rigged one once holders have accrued rewards.
        bytes[] routes;
    }

    struct Config {
        address token;
        address feeder;
        address swapRouter;
        address v3Factory;
        address poolManager;
        address weth;
        uint256 minEligible;
        address[] excluded;
        InputBasket[] inputs;
    }

    /// @dev A converting leg, by id.
    struct ConvLeg {
        address input;
        address asset;
        uint16 bps;
    }

    /// @dev One conversion (or fallback) of a leg's whole pending pool.
    struct Epoch {
        uint256 idx; // the leg's index when it happened
        uint256 cAsset; // running sum of rate x index growth, asset side (per share, magnified)
        uint256 cQuote; // the same for fallback epochs, input side
        uint256 rate; // asset per input x 2^128, or QUOTE_FLAG for a fallback
    }

    /// @dev A holder's position on one leg as of their last settlement.
    struct HolderLeg {
        uint256 idx;
        uint128 pend;
        uint64 ep;
    }

    address[] public inputs;
    mapping(address => bool) public isInput;
    mapping(address => Leg[]) private _basketOf;
    mapping(address => uint16) public swapBpsOf;
    mapping(address => uint256) public receivedOf;
    /// @notice Input held for conversion: every leg's pending pool plus anything not yet credited to holders.
    mapping(address => uint256) public buffered;
    /// @notice Converting-leg input that arrived while the eligible book was below its floor; credited once it is not.
    /// @dev PERMANENTLY UNRECOVERABLE if eligible supply never returns above {minEligibleFloor} -- the same
    /// disclosure as {pending}, which it is the converting-leg twin of. {_attribute} is permissionless
    /// ({pokePending} calls it for every input), so any recovery only needs one registered holder.
    mapping(address => uint256) public unattributed;
    mapping(address => uint256[]) private _legIdsOf;
    mapping(address => uint256[]) private _denomLegs;
    ConvLeg[] private _convLegs;
    mapping(uint256 => uint256) public legIdx;
    mapping(uint256 => uint256) public legIn;
    mapping(uint256 => uint256) public legOut;
    mapping(uint256 => uint256) public epochCount;
    mapping(uint256 => mapping(uint256 => Epoch)) private _epochs;
    mapping(uint256 => uint64) public failingSince;
    /// @notice First failed attempt since leg `id` last converted (any failure; only a success or a fallback clears it).
    mapping(uint256 => uint64) public staleSince;
    /// @dev Per-holder, per-converting-leg settlement state: the epoch and pending index this account was last
    /// settled at, plus its carried pending. Read and advanced by {_lazy}, {_settle}, {_settleAll} and {_pullPending};
    /// this is what makes a holder's share of every past conversion computable without touching them at the time.
    mapping(address => mapping(uint256 => HolderLeg)) private _holderLeg;
    /// @notice Settled conversion credits, [account][denomination].
    mapping(address => mapping(address => uint256)) public credited;
    mapping(address => mapping(address => bytes)) private _routeOf;
    mapping(address => uint256) public minConvertOf;
    /// @notice Smallest push a {distributeFor} call is paid on, per denomination. A push below it is still made,
    /// in full, for free. Creator-settable; 0 = every push pays.
    mapping(address => uint256) public minPokeOf;
    uint256 private _convertCursor;
    bool private transient _v4Swapping;
    /// @dev Set for the duration of one {distributeFor}: the round-robin push skims the poke fee only while it
    /// is set, so the hook's in-swap step, the coin's transfer poke and every manual claim stay free.
    address private transient _poker;

    address[] public denominations;
    mapping(address => bool) public isDenomination;
    mapping(address => uint256) public magnifiedRewardPerShare;
    uint256 public eligibleSupply;
    mapping(address => uint256) public totalDistributed;
    /// @dev PERMANENTLY UNRECOVERABLE if eligible supply never returns above {minEligibleFloor} -- as in every tracker.
    mapping(address => uint256) public pending;
    mapping(address => uint256) public reserve;

    mapping(address => uint256) public trackedBalance;
    mapping(address => mapping(address => int256)) internal magnifiedCorrections;
    mapping(address => mapping(address => uint256)) public withdrawnRewards;
    mapping(address => bool) public excluded;

    /// @notice Last time reward value moved: a distribution ({_book}) or a successful payout ({_spend}).
    /// Anchors {sweepStranded}'s timeout.
    uint64 public lastActivityAt;

    address[] private _holders;
    mapping(address => uint256) private _holderIdx1;
    uint256 public lastProcessedIndex;
    address public lastProcessedHolder;
    uint96 private _lastProcessedDenom;

    uint256 private _entered = 1;

    event RewardsDistributed(address indexed denomination, uint256 amount, uint256 perShare);
    event RewardShortfall(address indexed denomination, uint256 held, uint256 balance);
    event ReserveUnderrun(address indexed denomination, uint256 reserve, uint256 amount);
    event RewardClaimed(address indexed account, address indexed asset, uint256 amount);
    event LegPaymentFailed(address indexed account, address indexed asset, uint256 amount);
    event LegSwapFailed(address indexed account, address indexed denomination, address indexed tokenOut, uint256 amount);
    event HolderPayoutFailed(address indexed holder);
    event MinEligibleSet(uint256 oldValue, uint256 newValue);
    event PendingCredited(address indexed input, uint256 amount);
    event Converted(uint256 indexed legId, address indexed input, address indexed asset, uint256 amountIn, uint256 amountOut);
    event ConversionFailed(uint256 indexed legId, address indexed input, address indexed asset, uint256 amountIn);
    event ConversionFallback(uint256 indexed legId, address indexed input, address indexed asset, uint256 amount);
    event PendingPulled(address indexed account, uint256 indexed legId, uint256 amount);
    event SlippageSet(uint16 oldBps, uint16 newBps);
    event FallbackDelaySet(uint256 oldDelay, uint256 newDelay);
    event RouteSet(address indexed input, address indexed asset, bytes route);
    event MinConvertSet(address indexed input, uint256 amount);
    /// @notice An asset the tracker never pays out was withdrawn by the platform admin.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Buffered income that stranded under a dead book was swept by the platform admin.
    event StrandedSwept(address indexed token, address indexed to, uint256 amount);
    event MinPokeSet(address indexed denomination, uint256 amount);
    /// @notice A {distributeFor} call paid `caller` `amount` of `denomination`, skimmed from what it delivered.
    event PokePaid(address indexed caller, address indexed denomination, uint256 amount);

    error OnlyToken();
    error OnlyFeeder();
    error OnlySelf();
    error Reentrancy();
    error NothingToClaim();
    error NothingDelivered();
    error ZeroRecipient();
    error BadBasket();
    error BadInputs();
    error AboveAbsoluteMax();
    error TooManyLegs();
    error TooHeavy();
    error NotADenomination();
    error NotDuringSwap();
    error NotCreator();
    error MinEligibleBelowFloor();
    error MinEligibleTooHigh();
    error NoRouteFound();
    /// @notice A launch-time `routes` array was neither empty nor exactly as long as its basket. See the round-12
    /// note in the constructor: the arrays align on LEGS, so any other length silently mis-assigns or drops routes.
    error RoutesLengthMismatch(uint256 given, uint256 expected);
    /// @notice A launch-time route was supplied at the index of a DIRECT leg (one whose asset IS the input, and which
    /// therefore converts through nothing). Almost always an off-by-one in the caller's array.
    error RouteAtDirectLeg(address input, uint256 legIndex);
    /// @dev Two legs of one input named the same asset. See the round-17 note at the check.
    error DuplicateLegAsset(address input, address asset);
    error NoPrice();
    error BelowMinOut();
    error BadSlippage();
    error BadFallbackDelay();
    error NotALeg();
    error NoNativeInput();
    error BadMinOuts();
    error BadRoutes();
    error LegMinOutUnmet();
    error InsufficientGasForLeg();
    error EthSendFailed();
    /// @notice An in-swap conversion would have left a PoolManager delta open (it would revert the trader's transaction).
    error OpenDelta();
    /// @notice The hook has in-swap payouts switched off for this input, so it is not converted inside a swap.
    error InSwapDenied();
    error NotPlatformAdmin();
    error RescueForbiddenAsset(address token);
    error ZeroAddress();
    error NotStranded();
    error AmountExceedsStranded();
    /// @dev More than {MAX_POKE_SYNC} addresses handed to {distributeFor}.
    error TooManyToSync();
    /// @notice The payout transfer reported success but moved nothing to the recipient, so it was rolled back.
    /// @dev AUDIT ROUND 8: `safeTransfer` accepts a token that returns true and moves nothing (a compliance
    /// soft-blocklist, a 100% fee-on-transfer token, a proxy upgraded to a no-op). Without this the holder was
    /// debited for a delivery that never happened, the value stayed here above `reserve`, the next sync re-booked
    /// it as fresh income, and a {distributeFor} caller was paid a fee on every round of that loop (measured:
    /// 702.4 of a 1000-token pool in one transaction).
    error ZeroDelivery();

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    modifier onlyFeeder() {
        if (msg.sender != feeder) revert OnlyFeeder();
        _;
    }

    modifier nonReentrant() {
        if (_entered == 2) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(Config memory c) {
        token = c.token;
        feeder = c.feeder;
        swapRouter = c.swapRouter;
        v3Factory = c.v3Factory;
        poolManager = c.poolManager;
        weth = c.weth;
        uint256 me_ = c.minEligible == 0 ? 1 : c.minEligible;
        minEligibleFloor = me_;
        minEligible = me_;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
        fallbackDelay = 1 days;
        for (uint256 i; i < c.excluded.length; ++i) {
            excluded[c.excluded[i]] = true;
        }
        excluded[c.token] = true;
        excluded[address(this)] = true;
        excluded[address(0)] = true;
        excluded[c.feeder] = true;
        if (c.swapRouter != address(0)) excluded[c.swapRouter] = true;
        if (c.poolManager != address(0)) excluded[c.poolManager] = true;

        uint256 inCount = c.inputs.length;
        if (inCount == 0) revert BadInputs();
        uint256 totalLegs;
        for (uint256 ii; ii < inCount; ++ii) {
            address input = c.inputs[ii].input;
            if (input == address(0) || isInput[input]) revert BadInputs();
            isInput[input] = true;
            inputs.push(input);
            _addDenomination(input);

            Leg[] memory legs = c.inputs[ii].legs;
            uint256 n = legs.length;
            if (n == 0 || n > MAX_LEGS) revert BadBasket();
            // AUDIT ROUND 12 (L-1). `routes` aligns on LEGS, not on converting legs, so it must be either absent or
            // EXACTLY as long as the basket. Unchecked, three silent failures were possible, and every one of them
            // shipped a working launch that quietly never converted: a SHORT array left the tail routeless; a SURPLUS
            // entry past the last leg was never read and so never validated (making "a bad route fails the launch"
            // true only for indices that happen to land on a converting leg); and a front end that omitted the
            // placeholder for a direct leg shifted every route by one, handing a converting leg nothing. The only
            // signal was an absent {RouteSet}, a day before the leg fell back to the input, repairable only by the
            // platform admin. Requiring the exact length turns all three into a revert at launch.
            bytes[] memory rs = c.inputs[ii].routes;
            if (rs.length != 0 && rs.length != n) revert RoutesLengthMismatch(rs.length, n);
            totalLegs += n;
            if (totalLegs > MAX_TOTAL_LEGS) revert TooManyLegs();
            uint256 sumBps;
            uint16 swapBps;
            for (uint256 i; i < n; ++i) {
                Leg memory leg = legs[i];
                if (leg.asset == address(0) || leg.bps == 0) revert BadBasket();
                // AUDIT ROUND 17. One asset, at most one leg. Two legs naming the same asset are not a different
                // configuration from one leg at the combined bps -- they share `_routeOf[input][asset]`, the same
                // fallback clocks and the same denomination -- so the only things the duplicate buys are a second
                // conversion pool, a second per-leg cost in {balanceSyncGas} and a second entry in every settlement
                // loop. What it much more likely IS, is the same class of caller mistake {RouteAtDirectLeg} already
                // refuses: a basket built by index where one entry was written twice, or a routes array read as if
                // it aligned on assets. Refuse it at launch, like that one, instead of shipping a launch that works
                // but is not what was asked for. `n <= MAX_LEGS` (10), so the scan is bounded and cold-path.
                for (uint256 j; j < i; ++j) {
                    if (legs[j].asset == leg.asset) revert DuplicateLegAsset(input, leg.asset);
                }
                sumBps += leg.bps;
                _basketOf[input].push(leg);
                _addDenomination(leg.asset);
                if (leg.asset != input) {
                    swapBps += leg.bps;
                    uint256 id = _convLegs.length;
                    _convLegs.push(ConvLeg(input, leg.asset, leg.bps));
                    _legIdsOf[input].push(id);
                    _denomLegs[leg.asset].push(id);
                    _denomLegs[input].push(id);
                    // Monotonic counters start at 1 so their first write is never a zero-to-nonzero SSTORE.
                    legIdx[id] = 1;
                    legIn[id] = 1;
                    legOut[id] = 1;
                    // The launch-time route for this leg, validated exactly as {setRoute} validates one.
                    if (i < rs.length && rs[i].length != 0) {
                        RealmAnyPairsRouteLib.supplied(
                            rs[i], c.swapRouter == address(0) ? address(0) : c.v3Factory, c.poolManager, input,
                            leg.asset, c.feeder
                        );
                        _routeOf[input][leg.asset] = rs[i];
                        emit RouteSet(input, leg.asset, rs[i]);
                    }
                } else if (i < rs.length && rs[i].length != 0) {
                    // A DIRECT leg (asset == input) converts through nothing, so a route at its index is a mistake --
                    // almost certainly an off-by-one in the caller's array. Round 12 (L-1): refuse it rather than drop
                    // it silently, so the misalignment is caught at launch instead of at the first conversion.
                    revert RouteAtDirectLeg(input, i);
                }
            }
            if (sumBps != BPS) revert BadBasket();
            swapBpsOf[input] = swapBps;
        }
        lastActivityAt = uint64(block.timestamp); // {sweepStranded}'s clock runs from deployment
        if (denominations.length > ABSOLUTE_MAX_DENOMINATIONS) revert AboveAbsoluteMax();
        if (_syncGasFor(denominations.length, _convLegs.length) > MAX_AUTO_SYNC_GAS) revert TooHeavy();
    }

    function _addDenomination(address d) private {
        if (isDenomination[d]) return;
        isDenomination[d] = true;
        denominations.push(d);
    }

    function _syncGasFor(uint256 dCount, uint256 legCount_) internal pure returns (uint256) {
        return SYNC_BASE_GAS + SYNC_PER_DENOM_GAS * dCount + SYNC_PER_LEG_GAS * legCount_;
    }

    receive() external payable {
        if (msg.sender != weth) revert NoNativeInput();
    }

    // ─────────────────────────── views ───────────────────────────

    /// @notice Tells the tax hook this tracker converts rewards itself, so the hook calls {convertStep} after swaps.
    function autoConvertsRewards() external pure returns (bool) {
        return true;
    }

    function inputCount() external view returns (uint256) {
        return inputs.length;
    }

    function denominationCount() external view returns (uint256) {
        return denominations.length;
    }

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Number of converting legs; ids run 0..legCount-1.
    function legCount() external view returns (uint256) {
        return _convLegs.length;
    }

    function basketOf(address input) external view returns (Leg[] memory) {
        return _basketOf[input];
    }

    /// @notice A converting leg: its pending pool, conversions so far, failure clock, and the route its next conversion
    /// would use (the admin-stored one; empty means the leg does not convert automatically).
    function legInfo(uint256 id)
        external
        view
        returns (
            address input,
            address asset,
            uint16 bps,
            uint256 pool,
            uint256 epochs,
            uint64 failingSince_,
            bytes memory route
        )
    {
        ConvLeg memory l = _convLegs[id];
        (input, asset, bps) = (l.input, l.asset, l.bps);
        pool = legIn[id] - legOut[id];
        epochs = epochCount[id];
        failingSince_ = failingSince[id];
        route = _routeOf[input][asset]; // automatic conversion uses only this; empty means the leg does not convert
    }

    function routeOf(address input, address asset) external view returns (bytes memory) {
        return _routeOf[input][asset];
    }

    /// @notice What `account` has waiting on leg `id`, in the input token -- pullable now with {claimPending}.
    function pendingOf(address account, uint256 id) public view returns (uint256 pend) {
        (pend,,) = _lazy(account, id, trackedBalance[account]);
    }

    /// @notice Gas {setBalance} needs: a base, each denomination's correction, each converting leg's settlement.
    function balanceSyncGas() external view returns (uint256) {
        return _syncGasFor(denominations.length, _convLegs.length);
    }

    function accumulativeOf(address account, address denomination) public view returns (uint256) {
        int256 acc = (magnifiedRewardPerShare[denomination] * trackedBalance[account]).toInt256()
            + magnifiedCorrections[account][denomination];
        return acc <= 0 ? 0 : uint256(acc) / MAGNITUDE;
    }

    /// @notice Everything `account` can be paid in `denomination` now: direct bookings, settled and unsettled conversion
    /// credits, less what was already paid. Pending (unconverted) input is NOT included -- see {pendingOf}.
    function claimableOf(address account, address denomination) public view returns (uint256) {
        uint256 total = accumulativeOf(account, denomination) + credited[account][denomination];
        uint256[] storage ids = _denomLegs[denomination];
        uint256 n = ids.length;
        if (n != 0) {
            uint256 bal = trackedBalance[account];
            for (uint256 i; i < n; ++i) {
                uint256 id = ids[i];
                (, uint256 a, uint256 q) = _lazy(account, id, bal);
                total += _convLegs[id].asset == denomination ? a : q;
            }
        }
        return total - withdrawnRewards[account][denomination];
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

    /// @dev A holder's position on leg `id` brought forward to now at balance `bal`, without writing: what is still
    /// pending, and what has converted into the asset (`a`) or fallen back into the input (`q`) since the last settlement.
    function _lazy(address account, uint256 id, uint256 bal) internal view returns (uint256 pend, uint256 a, uint256 q) {
        HolderLeg memory s = _holderLeg[account][id];
        if (s.idx == 0) return (0, 0, 0);
        uint256 n = epochCount[id];
        uint256 now_ = legIdx[id];
        if (s.ep == n) return (s.pend + FullMath.mulDiv(bal, now_ - s.idx, MAGNITUDE), 0, 0);
        Epoch storage e1 = _epochs[id][s.ep + 1];
        uint256 first = s.pend + FullMath.mulDiv(bal, e1.idx - s.idx, MAGNITUDE);
        if (e1.rate & QUOTE_FLAG != 0) q = first;
        else a = FullMath.mulDiv(first, e1.rate, Q128);
        if (n > uint256(s.ep) + 1) {
            Epoch storage en = _epochs[id][n];
            a += FullMath.mulDiv(bal, en.cAsset - e1.cAsset, MAGNITUDE);
            q += FullMath.mulDiv(bal, en.cQuote - e1.cQuote, MAGNITUDE);
            pend = FullMath.mulDiv(bal, now_ - en.idx, MAGNITUDE);
        } else {
            pend = FullMath.mulDiv(bal, now_ - e1.idx, MAGNITUDE);
        }
    }

    /// @dev Writes {_lazy} for `account` on leg `id`: credits what converted, carries what is still pending.
    function _settle(address account, uint256 id, uint256 bal) internal {
        HolderLeg storage s = _holderLeg[account][id];
        uint256 now_ = legIdx[id];
        uint256 n = epochCount[id];
        if (s.idx == now_ && s.ep == n) return;
        if (s.idx != 0 && (bal != 0 || s.pend != 0)) {
            (uint256 pend, uint256 a, uint256 q) = _lazy(account, id, bal);
            ConvLeg storage l = _convLegs[id];
            if (a != 0) credited[account][l.asset] += a;
            if (q != 0) credited[account][l.input] += q;
            s.pend = pend.toUint128();
        }
        s.idx = now_;
        s.ep = uint64(n);
    }

    function _settleAll(address account, uint256 bal) internal {
        uint256 n = _convLegs.length;
        for (uint256 id; id < n; ++id) {
            _settle(account, id, bal);
        }
    }

    // ─────────────────────────── reward settings ───────────────────────────
    //
    // AUDIT ROUND 9. Every knob that prices or schedules a CONVERSION is platform-admin-only (the hook's live `admin()`,
    // the key {setRoute} already used, so it survives a creator renounce). The creator keeps only {setMinEligible}, which
    // cannot move value: it selects who is auto-pushed, never who accrues, and is capped at 1% of supply.

    /// @notice Set the band a STORED route is quoted on, in bps of the route pool's spot. 10-5000.
    /// @dev PLATFORM ADMIN ONLY, for the same reason as {setRoute}: the band and the pool together decide what a
    /// conversion is allowed to pay, so whoever picks one must be whoever picks the other.
    function setSlippageBps(uint16 newBps) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (newBps < MIN_SLIPPAGE_BPS || newBps > MAX_SLIPPAGE_BPS) revert BadSlippage();
        emit SlippageSet(slippageBps, newBps);
        slippageBps = newBps;
    }

    /// @notice Set the fast fallback clock: how long a leg's real conversion failures must persist before it resolves in
    /// the input instead. 1 hour-7 days; the slow clock ({MAX_FALLBACK_DELAY}) is fixed.
    /// @dev PLATFORM ADMIN ONLY (round 9): it is how long holders wait for the asset they were promised.
    function setFallbackDelay(uint256 newDelay) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (newDelay < MIN_FALLBACK_DELAY || newDelay > MAX_FALLBACK_DELAY) revert BadFallbackDelay();
        emit FallbackDelaySet(fallbackDelay, newDelay);
        fallbackDelay = newDelay;
    }

    /// @notice Store the route `input` converts into `asset` through: a 43-byte V3 path or an ABI-encoded V4 `PoolKey`,
    /// validated now ({RealmAnyPairsRouteLib.supplied}). Empty clears it: the leg then stops converting and pays out in
    /// the input.
    /// @dev PLATFORM ADMIN ONLY. The CREATOR chooses its legs' routes once, in the launch configuration
    /// ({InputBasket.routes}); after launch only the platform admin may change one. That split is deliberate: the route
    /// is visible before anyone buys, and it cannot be flipped to a rigged pool after holders have accrued rewards.
    /// @dev THE RISK, PLAINLY. Automatic conversion prices against the route pool's own spot, so whoever chose the pool
    /// chose the price every future conversion is measured against -- a pool the chooser owns and priced will sell
    /// holders' accrued rewards into their own hands, continuously, and nothing on-chain vets that. Realm does not
    /// approve routes. The per-holder opt-out is the protection: {claimPending} pays out in the input, and {claimAs}
    /// converts into any token the holder names under their OWN minimum.
    function setRoute(address input, address asset, bytes calldata route) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (!_isConvertingLeg(input, asset)) revert NotALeg();
        if (route.length != 0) {
            RealmAnyPairsRouteLib.supplied(route, _v3FactoryForRoutes(), poolManager, input, asset, feeder);
        }
        _routeOf[input][asset] = route;
        // A new route starts clean: a clock left by the old one must not let a single failure complete a fallback.
        for (uint256 id; id < _convLegs.length; ++id) {
            if (_convLegs[id].input == input && _convLegs[id].asset == asset) {
                failingSince[id] = 0;
                staleSince[id] = 0;
            }
        }
        emit RouteSet(input, asset, route);
    }

    /// @dev The feeder's (the tax hook's) `admin()`, the platform key that survives renounce. Unreadable or zero refuses.
    function _platformAdmin() internal view returns (address a) {
        (bool ok, bytes memory ret) = feeder.staticcall{gas: 20_000}(abi.encodeWithSignature("admin()"));
        if (!ok || ret.length < 32) revert NotPlatformAdmin();
        a = abi.decode(ret, (address));
        if (a == address(0)) revert NotPlatformAdmin();
    }

    /// @notice Set the smallest pending pool a leg on `input` converts. Unbounded.
    /// @dev PLATFORM ADMIN ONLY (round 9): raising it past a leg's whole stream stops that leg converting at all, so it
    /// is a conversion knob, not a housekeeping one.
    function setMinConvert(address input, uint256 amount) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (!isInput[input]) revert BadInputs();
        minConvertOf[input] = amount;
        emit MinConvertSet(input, amount);
    }

    /// @notice Set the smallest push {distributeFor} is paid on for `denomination`. Unbounded; default 0 (every push
    /// pays), which stays the default -- the poke fee is what makes searchers push small books, and raising the floor
    /// only ever removes that incentive.
    /// @dev PLATFORM ADMIN ONLY (round 9), with the rest of the reward knobs. Raising it never touches a holder's
    /// reward: holders are always pushed and paid in full, and {claim} / {claimPending} / {claimAs} are untouched.
    function setMinPoke(address denomination, uint256 amount) external {
        if (msg.sender != _platformAdmin()) revert NotPlatformAdmin();
        if (!isDenomination[denomination]) revert NotADenomination();
        minPokeOf[denomination] = amount;
        emit MinPokeSet(denomination, amount);
    }

    /// @notice CREATOR knob (the only one left here after round 9): the balance a holder needs to be auto-pushed.
    /// @dev Bounded to [{minEligibleFloor}, floor x {MAX_MIN_ELIGIBLE_MULTIPLE}] and to the current {eligibleSupply}.
    /// Every launcher path seeds the floor at `totalSupply / 1e4`, so the ceiling is 1e2 x 1e-4 = 1% OF TOTAL SUPPLY in
    /// every tracker (verified round 9). It never affects accrual, and {claim} is always open below it.
    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) revert NotCreator();
        if (newMinEligible < minEligibleFloor) revert MinEligibleBelowFloor();
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) revert MinEligibleTooHigh();
        if (newMinEligible > eligibleSupply) revert MinEligibleTooHigh();
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
    }

    function _isConvertingLeg(address input, address asset) internal view returns (bool) {
        if (!isInput[input] || asset == input) return false;
        uint256[] storage ids = _legIdsOf[input];
        for (uint256 i; i < ids.length; ++i) {
            if (_convLegs[ids[i]].asset == asset) return true;
        }
        return false;
    }

    /// @dev The coin's current creator as the hook records it (CTO-aware; renounced reads as none).
    function _tokenCreator() internal view returns (address c) {
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

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) {
            _noteExcluded(account, newBalance); // round 9 (F4): remember it before it is zeroed for accrual
            newBalance = 0;
        }
        _applyBalance(account, newBalance);
    }

    function _applyBalance(address account, uint256 newBalance) internal {
        uint256 old = trackedBalance[account];
        if (newBalance == old) return;
        _settleAll(account, old); // at the balance that EARNED it, before it changes
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

    function syncBalance(address account) external nonReentrant {
        _syncBalance(account);
    }

    function syncBalances(address[] calldata accounts) external nonReentrant {
        for (uint256 i; i < accounts.length; ++i) {
            _syncBalance(accounts[i]);
        }
    }

    function _syncBalance(address account) internal {
        if (excluded[account]) {
            // Round 9 (F4): repair the excluded mirror as well, so anyone can refresh the release denominator.
            (bool xok, bytes memory xret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
            if (xok && xret.length >= 32) _noteExcluded(account, abi.decode(xret, (uint256)));
            if (trackedBalance[account] != 0) _applyBalance(account, 0);
            return;
        }
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || ret.length < 32) return;
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) _applyBalance(account, real);
    }

    // ─────────────────────────── feeding ───────────────────────────

    function feedToken(uint256) external onlyFeeder nonReentrant {
        _syncAll();
    }

    /// @notice The hook's native rewards slot. Wrapped and booked at once unless this contract is already mid-operation,
    /// in which case the ETH waits for the next sync. Not `nonReentrant` on purpose: a revert here would send the hook's
    /// slice to its fallback ledger instead of to holders.
    function feed() external payable onlyFeeder {
        if (weth == address(0) || !isInput[weth]) revert NoNativeInput();
        // Wrap only, and book nothing here: the hook forwards a fixed 200k, which a full sync across many legs exceeds.
        // The WETH is booked by the next sync -- `convertStep`, which the hook calls right after, syncs this input first.
        IAutoBasketWETH(weth).deposit{value: msg.value}();
    }

    function sync() external nonReentrant {
        _syncAll();
    }


    // ─────────────────────────── admin rescue (audit round 8 scope addition) ───────────────────────────
    //
    // Both paths are platform-admin only (the hook's live `admin()`, the key {setRoute} uses, so they survive a
    // creator renounce), both are refused inside a V4 unlock, and NEITHER can touch a holder's rewards:
    // {rescueStray} refuses every denomination outright, and {sweepStranded} moves only buffers that are by
    // definition unbooked, together with their backing.

    /// @notice The platform admin's two-in-one rescue. `sweep == false` withdraws a STRAY asset -- one this
    /// tracker never pays out (not a denomination, not an input, not the coin, never native). `sweep == true`
    /// takes STRANDED buffered income for `asset` (its `pending`, then its `unattributed`), and only from a dead
    /// book: eligible supply still under {minEligibleFloor} and {RESCUE_DELAY} with no distribution and no
    /// successful payout. The two paths emit different events ({Rescued} / {StrandedSwept}) so they stay
    /// distinguishable on-chain; they share one entry point only to keep this contract's dispatcher small.
    /// @dev NEITHER path can reach a holder's rewards. The stray path refuses every denomination outright, which
    /// puts `reserve`, `buffered` and every claimable balance out of reach by construction. The sweep path moves
    /// only `pending` (backed by `reserve`) and `unattributed` (backed by `buffered`), each together with its
    /// own backing, so `reserve + buffered <= balance` still holds and booked rewards are untouched -- `pending`
    /// and `unattributed` are exactly the parts no holder has a claim on.
    function adminRescue(address asset, address to, uint256 amount, bool sweep) external nonReentrant {
        _rescueGate(to);
        if (!sweep) {
            if (asset == address(0) || isDenomination[asset] || asset == token) revert RescueForbiddenAsset(asset);
            IERC20(asset).safeTransfer(to, amount);
            emit Rescued(asset, to, amount);
            return;
        }
        if (!isDenomination[asset]) revert NotADenomination();
        if (!_strandedUnlocked()) revert NotStranded();
        uint256 p = pending[asset];
        uint256 u = unattributed[asset];
        if (amount > p + u) revert AmountExceedsStranded();
        uint256 fromPending = amount > p ? p : amount;
        if (fromPending != 0) {
            uint256 leftAfterSweep = p - fromPending;
            pending[asset] = leftAfterSweep;
            // AUDIT ROUND 15 (F-1) then ROUND 16 (F-2). Subtract, and LEAVE THE MARK ALONE. Round 15 rebased to
            // `total = left; served = 0`, which restores `pool == total - served` but discards `served`, the monotone
            // high-water mark that stops a cohort being paid twice out of the same pool. Measured on that code: an
            // attacker holding 50% of the float took its fair 50%, dropped out of the register using only the
            // mandatory debit gas, waited for an HONEST admin to sweep a dead book, re-registered and drew the same
            // share again -- halving what the other half of the float received. A one-wei sweep was enough.
            // `total - amount` equals `served + left`, so round 15's invariant holds AND the mark survives; `want`
            // can only shrink, so a served cohort still computes `want <= done` and draws nothing.
            // THE INVARIANT, BOTH HALVES -- stating only one of them is how round 15 went wrong here:
            //   (1) `pending == pendingTotal - pendingServed` at every point. A sweep writes `pending` directly, so it
            //       must adjust `pendingTotal` by the same amount; `pendingTotal - amount` does exactly that.
            //   (2) `pendingServed` is MONOTONE, except on a full drain. It is the high-water mark of what this buffer
            //       has already paid out, and it is the only thing stopping a cohort being served twice out of the same
            //       buffer (the round-8 guarantee). A sweep must therefore NOT touch it.
            // Round 15 satisfied (1) by zeroing `pendingServed`, which broke (2): an attacker took its fair share, left
            // the register, waited for an honest admin to sweep, came back and drew the same share again -- halving what
            // the rest of the float received. A one-wei sweep was enough. Both halves now hold together.
            pendingTotal[asset] -= fromPending;
            if (leftAfterSweep == 0) {
                pendingTotal[asset] = 0;
                pendingServed[asset] = 0;
            }
            _spendNoStamp(asset, fromPending);
        }
        uint256 fromUnattributed = amount - fromPending;
        if (fromUnattributed != 0) {
            uint256 leftUnattr = u - fromUnattributed;
            unattributed[asset] = leftUnattr;
            buffered[asset] -= fromUnattributed;
            // AUDIT ROUND 15 (F-1) then ROUND 16 (F-2). Subtract, and LEAVE THE MARK ALONE. Round 15 rebased to
            // `total = left; served = 0`, which restores `pool == total - served` but discards `served`, the monotone
            // high-water mark that stops a cohort being paid twice out of the same pool. Measured on that code: an
            // attacker holding 50% of the float took its fair 50%, dropped out of the register using only the
            // mandatory debit gas, waited for an HONEST admin to sweep a dead book, re-registered and drew the same
            // share again -- halving what the other half of the float received. A one-wei sweep was enough.
            // `total - amount` equals `served + left`, so round 15's invariant holds AND the mark survives; `want`
            // can only shrink, so a served cohort still computes `want <= done` and draws nothing.
            // THE INVARIANT, BOTH HALVES -- stating only one of them is how round 15 went wrong here:
            //   (1) `pending == pendingTotal - pendingServed` at every point. A sweep writes `pending` directly, so it
            //       must adjust `pendingTotal` by the same amount; `pendingTotal - amount` does exactly that.
            //   (2) `pendingServed` is MONOTONE, except on a full drain. It is the high-water mark of what this buffer
            //       has already paid out, and it is the only thing stopping a cohort being served twice out of the same
            //       buffer (the round-8 guarantee). A sweep must therefore NOT touch it.
            // Round 15 satisfied (1) by zeroing `pendingServed`, which broke (2): an attacker took its fair share, left
            // the register, waited for an honest admin to sweep, came back and drew the same share again -- halving what
            // the rest of the float received. A one-wei sweep was enough. Both halves now hold together.
            attributedTotal[asset] -= fromUnattributed;
            if (leftUnattr == 0) {
                attributedTotal[asset] = 0;
                attributedServed[asset] = 0;
            }
        }
        // AUDIT ROUND 18 (informational, consistency). MEASURE THE SENDER'S DECREASE and report THAT -- the same rule
        // this codebase's push paths apply, and the twin of the note in {RealmAnyPairsDividendTrackerQuote-sweepStranded}.
        // The ledger legs above intentionally move by the NOMINAL `amount` and that is unchanged: against a
        // fee-on-transfer or soft-blocklist denomination the retained remainder stays here and is re-booked on the
        // next sync, so nothing is lost and no invariant breaks. Only the REPORT was wrong -- {StrandedSwept} could
        // name an amount that never left. No {ZeroDelivery}-style revert is added: the debit is of buffers no holder
        // has a claim on, and reverting would newly brick the platform admin's ability to clear a dead book against
        // an asset that has started refusing transfers.
        uint256 beforeBal = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(to, amount);
        uint256 afterBal = IERC20(asset).balanceOf(address(this));
        uint256 moved = beforeBal > afterBal ? beforeBal - afterBal : 0;
        if (moved > amount) moved = amount; // a minting asset cannot over-report
        emit StrandedSwept(asset, to, moved);
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
    ///
    /// @dev AUDIT ROUND 18 (informational, consistency). The clause used to be open-coded at {adminRescue}'s sweep
    /// branch -- the only enforced rescue clock in the codebase that was not behind a shared helper, while
    /// {RealmAnyPairsDividendTracker} and {RealmAnyPairsDividendTrackerQuote} both had one. Nothing was wrong with
    /// it, but clause drift between copies of the same guard is what produced findings in rounds 11, 14, 15 and 16,
    /// and this file's own doc already cited `{_strandedUnlocked}` as though it existed here. One definition now.
    function _strandedUnlocked() internal view returns (bool) {
        return eligibleSupply < minEligibleFloor && block.timestamp >= uint256(lastActivityAt) + RESCUE_DELAY;
    }

    function pokePending() external nonReentrant {
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            _releasePending(d);
        }
        for (uint256 i; i < inputs.length; ++i) {
            _attribute(inputs[i]);
        }
    }

    function _syncAll() internal {
        address w = weth;
        if (w != address(0)) {
            uint256 native = address(this).balance;
            if (native != 0) IAutoBasketWETH(w).deposit{value: native}();
        }
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) {
            _syncOne(denominations[i]);
        }
    }

    function _syncOne(address d) internal {
        uint256 bal = IERC20(d).balanceOf(address(this));
        uint256 held = reserve[d] + buffered[d];
        if (bal <= held) {
            if (bal < held) emit RewardShortfall(d, held, bal);
            return;
        }
        uint256 delta = bal - held;
        if (isInput[d]) {
            _split(d, delta);
        } else {
            reserve[d] += delta;
            _receive(d, delta);
        }
    }

    function _split(address input, uint256 delta) internal {
        uint256 r0 = receivedOf[input];
        uint256 r1 = r0 + delta;
        receivedOf[input] = r1;
        uint256 s = swapBpsOf[input];
        uint256 toConvert = (r1 * s) / BPS - (r0 * s) / BPS;
        uint256 direct = delta - toConvert;
        if (toConvert != 0) {
            buffered[input] += toConvert;
            // Round 9 (F3): the same shape as {_receive} below. Under the floor this is BACKLOG, released
            // proportionally later; above it, fresh income is credited to the holders of the moment IN FULL, and
            // only the backlog goes through {_attribute}'s proportional path.
            if (eligibleSupply < minEligibleFloor) {
                // Round 14: count the addition; the target rises with the pool.
                attributedTotal[input] += toConvert;
                unattributed[input] += toConvert;
            } else {
                _attribute(input);
                // AUDIT ROUND 17: a carry-back re-enters the pool, so it must also be COUNTED, exactly as the
                // under-floor branch above counts its addition. Without the `attributedTotal` bump the pool would
                // grow while the counters did not, and `unattributed == attributedTotal - attributedServed` would
                // stop holding -- today only in a state the supply cap makes unreachable, which is precisely the
                // kind of "safe elsewhere" this file has been narrowing since round 12. `carried` is always zero in
                // this product, so nothing observable changes.
                uint256 carried = _creditLegs(input, toConvert, eligibleSupply);
                if (carried != 0) {
                    attributedTotal[input] += carried;
                    unattributed[input] += carried;
                }
            }
        }
        if (direct != 0) {
            reserve[input] += direct;
            _receive(input, direct);
        }
    }

    /// @notice High-water `eligibleSupply` already served out of {unattributed}, per input.
    /// @notice How much of this input's unattributed pool has already been credited, as a fraction of the ORIGINAL
    /// pool scaled by {RELEASE_ONE}. MONOTONE. See the round-12 note in
    /// {RealmAnyPairsDividendTrackerQuote.pendingTotal}: the round-11 downward mark made the round-8 capture
    /// repeatable (cycle eligible supply, collect the same band again); a live-denominator fraction is
    /// path-independent and cannot be sterilised by one spike.
    /// @notice Everything ever added to this input's current unattributed pool. Reset with the pool.
    /// @dev AUDIT ROUND 14 (F-1): absolute counters replace `attributedFrac`, for the reasons in
    /// {RealmAnyPairsDividendTrackerQuote.pendingTotal}. Note the auditor also proved that `_creditLegs`' dust
    /// carry-back is UNREACHABLE in this product (it needs `eligibleSupply > 2^128` while every launch path caps
    /// supply below 2^127), so the residue the old form left behind was never dust -- it was the arithmetic floor of
    /// the proportional branch, i.e. the common case.
    mapping(address => uint256) public attributedTotal;
    /// @notice How much of {attributedTotal} has already been credited. Monotone within a pool.
    mapping(address => uint256) public attributedServed;


    /// @dev Credit `input`'s not-yet-attributed converting share to holders as PENDING, split across its converting legs.
    ///
    /// AUDIT ROUND 9 (F3, High). This used to zero the whole buffer and hand it to whoever was registered at that
    /// instant -- the converting-leg twin of the bug round 8 fixed for the DIRECT share ({_releasePending}), and it
    /// was missed then. An attacker holding exactly {minEligibleFloor} (0.01% of supply) could call the
    /// permissionless {pokePending} and take the lot; measured 99.999999999999999999e18 of a 100e18 buffer, with a
    /// whale registering one block later getting nothing. It now has exactly the shape of {_releasePending}: a
    /// per-input high-water mark, a share proportional to the ATTRIBUTABLE supply, and the same settle path for the
    /// remainder -- so the aggregate credited is path-independent and grinding {pokePending} buys nothing. (As with
    /// {_releasePending}, that is a statement about the total, not about how it is split; see the round-17 note there.)
    /// @dev Release the accumulated BACKLOG of `input`'s converting share -- what arrived while the eligible book
    /// was under its floor -- proportionally, and credit it to holders as pending. Fresh income does NOT come
    /// through here: {_split} credits that in full through {_creditLegs}, exactly as {_receive} books the direct
    /// share in full and leaves only {pending} to {_releasePending}.
    ///
    /// AUDIT ROUND 9 (F3, High). The backlog used to be zeroed and handed in full to whoever happened to be
    /// registered at that instant -- the converting-leg twin of the bug round 8 fixed for the DIRECT share, and it
    /// was missed then. An attacker holding exactly {minEligibleFloor} (0.01% of supply) could call the
    /// permissionless {pokePending} and take the lot; measured 99.999999999999999999e18 of a 100e18 buffer, with a
    /// whale registering one block later getting nothing. It now has exactly the shape of {_releasePending}: a
    /// per-input high-water mark, a share proportional to the ATTRIBUTABLE supply, and the same settle path for
    /// the remainder -- so the aggregate credited is path-independent and grinding {pokePending} buys nothing. (As
    /// with {_releasePending}, that is about the total, not about how it is split; see the round-17 note there.)
    /// @dev The converting-leg twin of {_releasePending}, on exactly the same rule. See the round-14 redesign note
    /// there: absolute counters, no settle clock, and no branch that can hand a whole pool to one instant's register.
    function _attribute(address input) internal {
        uint256 u = unattributed[input];
        if (u == 0 || eligibleSupply < minEligibleFloor) return;
        uint256 elig = eligibleSupply;
        uint256 supply = _attributableSupply();
        if (supply == 0) return;
        uint256 done = attributedServed[input];
        uint256 want = FullMath.mulDiv(attributedTotal[input], elig, supply);
        if (want <= done) return;
        uint256 credit = want - done;
        if (credit > u) credit = u;
        // NOTE THE ORDER: `_creditLegs` can carry a remainder back into the pool, so `left` is read from what is
        // ACTUALLY stored rather than from `u - credit`. (Round 13; the round-14 auditor additionally proved the
        // carry-back is unreachable in this product -- it needs `eligibleSupply > 2^128` while every launch path
        // caps supply below 2^127 -- so in practice it is always zero, but the ordering stays correct either way.)
        //
        // AUDIT ROUND 17: the ratchet is stamped with what was ACTUALLY CREDITED, `credit - carried`, not with the
        // whole `credit`. That is what makes `unattributed == attributedTotal - attributedServed` hold
        // UNCONDITIONALLY, instead of holding only because the carry-back is unreachable -- an invariant that leans
        // on a bound proved in another file is one edit away from being false with nothing to catch it. It is still
        // monotone: `carried <= credit`, so the mark never moves backwards. Behaviour today is identical, because
        // `carried` is always zero.
        uint256 carried = _creditLegs(input, credit, elig);
        attributedServed[input] = done + credit - carried;
        uint256 left = u - credit + carried;
        unattributed[input] = left;
        if (left == 0) {
            attributedTotal[input] = 0;
            attributedServed[input] = 0;
        }
    }

    /// @dev Split `amount` of `input` across its converting legs and bump each leg's pending-per-share index.
    /// @return carried What the indexes could not represent, to be left buffered for a later, larger credit.
    /// @dev AUDIT ROUND 9 (L4): the per-share index is floored, so the part of `amount` the floor dropped used to
    /// be added to `legIn` -- and backed in `buffered` -- while backing no claim at all, permanently. Only what
    /// the index really represents is credited now; the remainder is carried by the caller.
    function _creditLegs(address input, uint256 amount, uint256 elig) internal returns (uint256 carried) {
        uint256[] storage ids = _legIdsOf[input];
        uint256 n = ids.length;
        uint256 s = swapBpsOf[input];
        uint256 given;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            uint256 part = i + 1 == n ? amount - given : (amount * _convLegs[id].bps) / s;
            given += part;
            if (part == 0) continue;
            uint256 add = (part * MAGNITUDE) / elig;
            // The defect: when `part` is too small to move the per-share index AT ALL, `legIn` -- and its backing in
            // `buffered` -- still took the whole of it, and it then backed no claim, permanently. Carry it instead.
            // (Above that threshold the index floor loses strictly sub-wei per credit, the same rounding every
            // magnified-per-share accumulator in this codebase carries, and `part` is credited in full as before.)
            if (add == 0) {
                carried += part;
                continue;
            }
            legIn[id] += part;
            legIdx[id] += add;
        }
        if (amount != carried) emit PendingCredited(input, amount - carried);
    }

    function _spend(address d, uint256 amount) internal {
        lastActivityAt = uint64(block.timestamp); // a payout is activity: it pushes {sweepStranded} out
        _spendNoStamp(d, amount);
    }

    /// @dev {_spend} without the activity stamp, so a sweep of a dead book cannot postpone its own timeout.
    function _spendNoStamp(address d, uint256 amount) internal {
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
        if (eligibleSupply < minEligibleFloor) {
            // Round 14 (F-1): additions are COUNTED, so the proportional target rises with the buffer instead of
            // treating new money as already partly served; and a material ADD pushes the settle clock, so a buffer
            // topped up shortly before an inherited deadline is not dumped in full moments later.
            pendingTotal[d] += amount;
            pending[d] += amount;
            return;
        }
        _releasePending(d);
        _book(d, amount);
    }


    // ── proportional release of buffered income (audit round 8, F3) ──
    /// @notice Everything ever added to the current pending buffer, per denomination. Reset with the buffer.
    /// @dev AUDIT ROUND 14 (F-1): absolute counters replace `pendingReleasedFrac`. See the full note in
    /// {RealmAnyPairsDividendTrackerQuote.pendingTotal} -- a fraction of a MUTABLE pool could never reset after a
    /// proportional release, and treated money added later as already partly served.
    mapping(address => uint256) public pendingTotal;
    /// @notice How much of {pendingTotal} has already been released, per denomination. Monotone within a buffer.
    mapping(address => uint256) public pendingServed;


    /// @dev Per-denomination form of {RealmAnyPairsDividendTracker._releasePending}. AUDIT ROUND 8 (F3, High):
    /// releasing a denomination's whole buffer to whoever happened to be registered let a holder with a sliver
    /// of the float take nearly all of it. Release is proportional to the coin's TOTAL supply and driven by a
    /// per-denomination high-water mark, so the AGGREGATE released is path-independent and repeated calls buy
    /// nothing. The SPLIT between holders is not; see the round-17 note below.
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
    function _releasePending(address d) internal {
        uint256 p = pending[d];
        if (p == 0 || eligibleSupply < minEligibleFloor) return;
        uint256 elig = eligibleSupply;
        uint256 supply = _attributableSupply();
        if (supply == 0) return; // nothing attributable: wait for registration, or for the sweep
        uint256 done = pendingServed[d];
        uint256 want = FullMath.mulDiv(pendingTotal[d], elig, supply);
        if (want <= done) return; // no new registration since the last release: no write at all
        uint256 r = want - done;
        if (r > p) r = p; // never pay out more than is actually held
        pendingServed[d] = done + r;
        uint256 left = p - r;
        pending[d] = left;
        // The counters describe ONE buffer and are cleared with it.
        if (left == 0) {
            pendingTotal[d] = 0;
            pendingServed[d] = 0;
        }
        _book(d, r);
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

    function _book(address d, uint256 amount) internal {
        lastActivityAt = uint64(block.timestamp);
        magnifiedRewardPerShare[d] += (amount * MAGNITUDE) / eligibleSupply;
        totalDistributed[d] += amount;
        emit RewardsDistributed(d, amount, magnifiedRewardPerShare[d]);
    }

    // ─────────────────────────── conversion ───────────────────────────

    /// @notice Convert (or fall back) at most one leg's pending pool; with nothing to convert, push rewards to holders
    /// instead. Permissionless; the tax hook calls it after every swap on this coin's pools.
    function convertStep() external nonReentrant returns (bool worked) {
        if (_convertStep()) return true;
        return _process(CONVERT_PUSH_BUDGET) != 0;
    }

    /// @notice Permissionless PAID poke: convert one leg (or fall it back) AND push rewards to holders in the
    /// same call, and pay the caller {POKE_FEE_BPS} of the rewards actually delivered, in the reward tokens
    /// themselves, skimmed from the delivery. Delivery therefore never depends on a trade carrying spare gas,
    /// and Realm runs no keeper.
    /// @dev Refused inside a V4 unlock: it must not touch an in-flight swap. Reverts {NothingDelivered} when
    /// neither a conversion/fallback nor a push happened, so a searcher's losing attempt costs them gas only.
    /// A conversion is real work and never reverts the call, but it delivers nothing, so on its own it pays
    /// nothing; the pushes that follow it in the same call are what pays. `gasBudget` is advisory -- the ring
    /// is bounded by `gasleft()` and by one pass over the holder set, so an absurd budget buys nothing.
    /// @return pushed how many (holder, denomination) payouts landed.
    /// @return worked whether a conversion or fallback also completed.
    function distributeFor(uint256 gasBudget) external nonReentrant returns (uint256 pushed, bool worked) {
        return _distributeFor(gasBudget);
    }

    /// @notice {distributeFor}, with a list of addresses to repair FIRST. Since audit round 8 an ordinary
    /// transfer's optional credit usually does not run (it reserves the heaviest coin's debit floor), so a fresh
    /// buyer is not in the ring yet; `toSync` puts them in it and pays them in the SAME call.
    /// @dev Each repair is capped at this tracker's own {balanceSyncGas} and isolated, so one hostile or
    /// codeless entry cannot fail the poke; the gas they spend is charged against `gasBudget`. Repairing alone
    /// earns nothing -- the fee is still only a share of rewards actually delivered. All repairs finish BEFORE
    /// the ring starts walking, so it sees one stable holder set, and the cursor is re-clamped in {_process}.
    function distributeFor(uint256 gasBudget, address[] calldata toSync)
        external
        nonReentrant
        returns (uint256 pushed, bool worked)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        uint256 n = toSync.length;
        if (n > MAX_POKE_SYNC) revert TooManyToSync();
        uint256 cap = _syncGasFor(denominations.length, _convLegs.length);
        uint256 g0 = gasleft();
        for (uint256 i; i < n; ++i) {
            // Stop rather than start a repair that cannot get its full stipend (EIP-150's 63/64 plus the frame).
            if (gasleft() < cap + cap / 63 + 10_000) break;
            try this.syncBalanceSelf{gas: cap}(toSync[i]) {} catch {}
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

    function _distributeFor(uint256 gasBudget) internal returns (uint256 pushed, bool worked) {
        if (_v4LockHeld()) revert NotDuringSwap();
        worked = _convertStep();
        _poker = msg.sender;
        pushed = _process(gasBudget);
        _poker = address(0);
        // A poke that converts nothing and delivers nothing simply pays nothing; it does NOT revert, or
        // anyone could front-run a searcher with the free `convertStep()` / `process()` and burn their gas
        // at will (audit round 8). Paying on a zero delivery is guarded per push by {ZeroDelivery}.
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            uint256 fee = _pokeAccTake(d);
            if (fee == 0) continue;
            // A reward token that refuses this transfer reverts the whole poke: the searcher pays gas, holders
            // keep everything, and the free paths (the hook's in-swap push, `claim`) are unaffected.
            IERC20(d).safeTransfer(msg.sender, fee);
            emit PokePaid(msg.sender, d, fee);
        }
    }

    /// @dev Transient poke accrual for one denomination; {_pokeAccTake} also clears it.
    function _pokeAccAdd(address d, uint256 v) private {
        bytes32 s = keccak256(abi.encode(_POKE_ACC_NS, d));
        assembly ("memory-safe") {
            tstore(s, add(tload(s), v))
        }
    }

    function _pokeAccTake(address d) private returns (uint256 v) {
        bytes32 s = keccak256(abi.encode(_POKE_ACC_NS, d));
        assembly ("memory-safe") {
            v := tload(s)
            tstore(s, 0)
        }
    }

    /// @notice The manual way: up to `steps` conversions in one call.
    function convert(uint256 steps) external nonReentrant returns (uint256 done) {
        for (uint256 i; i < steps; ++i) {
            if (!_convertStep()) break;
            unchecked {
                ++done;
            }
        }
    }

    function _convertStep() internal returns (bool) {
        // `feed` only wraps native fees. Book them here -- even when nothing converts (an all-WETH basket) or the step
        // returns early -- so they are credited to the holders of the moment, not to whoever syncs later.
        address w = weth;
        if (w != address(0) && isInput[w]) _syncOne(w);
        uint256 total = _convLegs.length;
        if (total == 0) return false;
        bool locked = _v4LockHeld();
        if (locked && IAutoBasketExttload(poolManager).exttload(V4_SYNCED_CURRENCY_SLOT) != bytes32(0)) return false;
        uint256 cur = _convertCursor;
        uint256 scan = total < CONVERT_SCAN ? total : CONVERT_SCAN;
        for (uint256 k; k < scan; ++k) {
            uint256 id = (cur + k) % total;
            address input = _convLegs[id].input;
            // A leg with NO STORED ROUTE cannot convert at all (round 11: nothing is discovered): while its fallback
            // clock runs, don't spend every step failing on it.
            uint64 since = failingSince[id];
            // Round 14 (F-2): split so neither condition spans multiple lines. The route SLOAD stays BELOW the
            // clock guard, so the common path does not pay for it -- same short-circuit as the original.
            if (since != 0 && block.timestamp < since + fallbackDelay) {
                if (_routeOf[input][_convLegs[id].asset].length == 0) continue;
            }
            _syncOne(input);
            _attribute(input);
            uint256 pool = legIn[id] - legOut[id];
            if (pool == 0 || pool < minConvertOf[input]) continue;
            uint256 next = (id + 1) % total;
            if (next != cur) _convertCursor = next;
            return _attempt(id, pool, locked);
        }
        // Nothing convertible in this window: move past it, or legs beyond it would never be scanned.
        uint256 skipTo = (cur + scan) % total;
        if (skipTo != cur) _convertCursor = skipTo;
        return false;
    }

    function _attempt(uint256 id, uint256 amt, bool locked) internal returns (bool) {
        ConvLeg memory l = _convLegs[id];
        if (IERC20(l.input).balanceOf(address(this)) < reserve[l.input] + buffered[l.input]) return false;

        uint256 left = gasleft();
        if (left < (CONVERT_GAS_MIN * 64) / 63 + CONVERT_TAIL_GAS) return false;
        uint256 forward = ((left - CONVERT_TAIL_GAS) * 63) / 64;
        if (forward > CONVERT_GAS_MAX) forward = CONVERT_GAS_MAX;
        try this.convertSelf{gas: forward}(l.input, l.asset, amt, locked) returns (uint256 out) {
            _closeEpoch(id, amt, out, false);
            buffered[l.input] -= amt;
            reserve[l.asset] += out;
            if (failingSince[id] != 0) failingSince[id] = 0;
            if (staleSince[id] != 0) staleSince[id] = 0;
            emit Converted(id, l.input, l.asset, amt, out);
            return true;
        } catch (bytes memory reason) {
            emit ConversionFailed(id, l.input, l.asset, amt);
            return _onFailure(id, l, amt, reason, locked, forward, left - gasleft());
        }
    }

    /// @dev The clocks, for one failed attempt. `forward` / `used` are the convert frame's budget and burn.
    function _onFailure(
        uint256 id,
        ConvLeg memory l,
        uint256 amt,
        bytes memory reason,
        bool locked,
        uint256 forward,
        uint256 used
    ) internal returns (bool) {
        // Fast clock ({fallbackDelay}): real failures only -- a known route refusal, or the FULL budget actually burnt
        // (the route needs more than any call can give; nested frames hand back their 1/64 reserves, so at least 7/8
        // of it). A price refusal inside someone else's unlock does not count: V4 swaps there are only deltas, so a
        // caller can move the route pool, fail the conversion and move it back for rounding on a fee-0 pool. Any
        // other revert and any short-budget failure never count either.
        //
        // AUDIT ROUND 9 (Medium): the GAS arm is gated on `!locked` as well. It used to fire unconditionally, and a
        // conversion that exhausts its budget reverts with EMPTY returndata -- which no classifier can call a price
        // refusal -- so the `locked` carve-out never covered it. Inside their own unlock an attacker added 12 dust tick
        // positions per side, called the free permissionless {convertStep}, and removed them again: the attempt burnt
        // 441,617 of a 350,000 budget (over the 7/8 line), started the fast clock, and left the pool's `liquidity` and
        // `sqrtPriceX96` byte-identical. Repeated past {fallbackDelay} that resolved a good leg into the input for the LP
        // fee on nothing. Out of lock the arm still resolves a genuinely heavy route; the slow clock still catches a
        // route that is only ever attempted in-swap.
        uint64 since = failingSince[id];
        bool real = (!locked && forward == CONVERT_GAS_MAX && used >= forward - forward / 8)
            || (_isRouteRefusal(reason) && !(locked && _isPriceRefusal(reason)));
        if (real) {
            if (since == 0) {
                failingSince[id] = uint64(block.timestamp);
            } else if (block.timestamp >= since + fallbackDelay) {
                _fallback(id, l, amt);
                return true;
            }
        }
        // Slow clock ({MAX_FALLBACK_DELAY}): any failure, cleared only by a success. A route that is broken in a way
        // the fast clock cannot tell from griefing (a paused asset, a halted hook) still resolves; an attacker cannot
        // stop honest conversions from clearing it, so it only ever completes on a leg nothing converted for a week.
        uint64 stale = staleSince[id];
        if (stale == 0) {
            staleSince[id] = uint64(block.timestamp);
        } else if (block.timestamp >= stale + MAX_FALLBACK_DELAY) {
            _fallback(id, l, amt);
            return true;
        }
        // Nothing completed: the caller may still push rewards with what is left.
        return false;
    }

    /// @dev A conversion revert that is a property of the route or the price, never of the gas a call happened to have:
    /// this contract's own route/price/settlement errors and RouteLib's. Router strings (a locked V3 pool's "LOK" can be
    /// provoked from a flash callback), wrapped and empty reverts (a hook, a token, out-of-gas) are not; conversions pass
    /// no router floor, so a price shortfall always surfaces as {BelowMinOut}.
    function _isRouteRefusal(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 sel = bytes4(reason);
        return sel == NoRouteFound.selector || sel == NoPrice.selector || sel == BelowMinOut.selector
            || sel == OpenDelta.selector || sel == InSwapDenied.selector || sel == RealmAnyPairsRouteLib.PartialFill.selector
            || sel == RealmAnyPairsRouteLib.BadRoute.selector;
    }

    /// @dev A refusal that depends on the route pool's current price or liquidity.
    function _isPriceRefusal(bytes memory reason) internal pure returns (bool) {
        if (reason.length < 4) return false;
        bytes4 sel = bytes4(reason);
        // Every selector here depends on the route pool's live price or fill, which anyone can move inside their own
        // unlock -- exactly the manipulation this classifier exists to discount.
        return sel == BelowMinOut.selector || sel == NoPrice.selector || sel == RealmAnyPairsRouteLib.PartialFill.selector;
    }

    /// @dev Still failing after the whole delay, tried once more: resolve the leg's pool in the input.
    function _fallback(uint256 id, ConvLeg memory l, uint256 amt) internal {
        _closeEpoch(id, amt, 0, true);
        buffered[l.input] -= amt;
        reserve[l.input] += amt;
        failingSince[id] = 0;
        staleSince[id] = 0;
        emit ConversionFallback(id, l.input, l.asset, amt);
    }

    /// @dev Resolve leg `id`'s whole pending pool (`amt`) into `out` of the asset, or into the input when `toQuote`.
    function _closeEpoch(uint256 id, uint256 amt, uint256 out, bool toQuote) internal {
        legOut[id] += amt;
        uint256 n = epochCount[id];
        uint256 now_ = legIdx[id];
        uint256 prevIdx = 1;
        uint256 cA;
        uint256 cQ;
        if (n != 0) {
            Epoch storage p = _epochs[id][n];
            (prevIdx, cA, cQ) = (p.idx, p.cAsset, p.cQuote);
        }
        uint256 grown = now_ - prevIdx;
        uint256 rate;
        if (toQuote) {
            rate = QUOTE_FLAG;
            cQ += grown;
        } else {
            rate = FullMath.mulDiv(out, Q128, amt);
            cA += FullMath.mulDiv(rate, grown, Q128);
        }
        _epochs[id][n + 1] = Epoch(now_, cA, cQ, rate);
        epochCount[id] = n + 1;
    }

    /// @dev Self-only: route, quote, swap and measure inside a gas-capped frame. The output lands on this contract.
    function convertSelf(address input, address asset, uint256 amount, bool locked) external returns (uint256 out) {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes memory stored = _routeOf[input][asset];
        // A leg converts through the route stored for it and nothing else. With no route it does not convert at all
        // and resolves in the INPUT on the usual clocks -- see {setRoute} and the round-11 note above
        // {MIN_FALLBACK_DELAY}.
        if (stored.length == 0) revert NoRouteFound();
        RealmAnyPairsRouteLib.Route memory r = _routeFor(input, asset, stored);
        uint16 band = slippageBps;
        uint256 minOut = (_spotOut(r, input, asset, amount) * (BPS - band)) / BPS;
        if (minOut == 0) revert NoPrice();
        uint256 before = IERC20(asset).balanceOf(address(this));
        uint256 reported;
        if (locked) {
            // Inside someone else's unlock, on any venue. Only where the hook allows in-swap payouts for this input, and
            // never leaving a delta or a `sync` open: either reverts or mis-credits the TRADER's settlement, not this frame.
            if (!_inSwapAllowed(input)) revert InSwapDenied();
            IPoolManager pm = IPoolManager(poolManager);
            uint256 openBefore = pm.getNonzeroDeltaCount();
            if (r.venue == RealmAnyPairsRouteLib.VENUE_V4) {
                PoolKey memory key = RealmAnyPairsRouteLib.poolKey(input, asset, r.fee, r.tickSpacing, r.hooks);
                reported = RealmAnyPairsRouteLib.swapExactIn(pm, key, input, amount);
                RealmAnyPairsRouteLib.settleAndTake(pm, input, amount, asset, address(this), reported);
                // Round 14 (F-2): two single-line checks rather than one multi-line condition; `||` short-circuits
                // in exactly the same order.
                if (pm.currencyDelta(address(this), Currency.wrap(input)) != 0) revert OpenDelta();
                if (pm.currencyDelta(address(this), Currency.wrap(asset)) != 0) revert OpenDelta();
            } else {
                reported = _swap(r, input, asset, amount, 0, address(this));
            }
            // Round 14 (F-2): two single-line checks; same order, same short-circuit.
            if (pm.getNonzeroDeltaCount() != openBefore) revert OpenDelta();
            if (IAutoBasketExttload(poolManager).exttload(V4_SYNCED_CURRENCY_SLOT) != bytes32(0)) revert OpenDelta();
        } else {
            // No router floor: the check below is the floor, and it reverts with a classifiable error.
            reported = _swap(r, input, asset, amount, 0, address(this));
        }
        uint256 aft = IERC20(asset).balanceOf(address(this));
        // NOT a delivery, so the uniform sender-side rule does NOT apply here: this measures a swap's OUTPUT
        // ARRIVING from a router, not value leaving this contract. The recipient's increase is the correct side,
        // and it is additionally clamped to the router's own reported output below. (Audit round 16.)
        out = aft > before ? aft - before : 0;
        // Only what the swap itself produced: anything that reached this contract meanwhile is booked by the next sync.
        if (out > reported) out = reported;
        if (out < minOut) revert BelowMinOut();
        if (FullMath.mulDiv(out, Q128, amount) >= QUOTE_FLAG) revert NoPrice();
    }

    function _routeFor(address tokenIn, address tokenOut, bytes memory route)
        internal
        view
        returns (RealmAnyPairsRouteLib.Route memory r)
    {
        address f = _v3FactoryForRoutes();
        r = route.length == 0
            ? RealmAnyPairsRouteLib.best(f, poolManager, tokenIn, tokenOut)
            : RealmAnyPairsRouteLib.supplied(route, f, poolManager, tokenIn, tokenOut, feeder);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_NONE) revert NoRouteFound();
    }

    /// @dev Out-of-lock swap of `amount` `tokenIn` to `recipient` through `r` (V3 router or a V4 unlock).
    function _swap(
        RealmAnyPairsRouteLib.Route memory r,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) internal returns (uint256 reported) {
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).forceApprove(swapRouter, amount);
            reported = IAutoBasketSwapRouter02(swapRouter).exactInput(
                IAutoBasketSwapRouter02.ExactInputParams({
                    path: RealmAnyPairsRouteLib.v3Path(r, tokenOut),
                    recipient: recipient,
                    amountIn: amount,
                    amountOutMinimum: minOut
                })
            );
            IERC20(tokenIn).forceApprove(swapRouter, 0);
            // SwapRouter02 does not require the whole input to be spent; an unspent remainder would be booked as converted.
            if (IERC20(tokenIn).balanceOf(address(this)) + amount > inBefore) revert RealmAnyPairsRouteLib.PartialFill();
        } else {
            PoolKey memory key = RealmAnyPairsRouteLib.poolKey(tokenIn, tokenOut, r.fee, r.tickSpacing, r.hooks);
            _v4Swapping = true;
            reported = abi.decode(
                IPoolManager(poolManager).unlock(abi.encode(key, tokenIn, tokenOut, amount, recipient)), (uint256)
            );
            _v4Swapping = false;
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager || !_v4Swapping) revert OnlySelf();
        (PoolKey memory key, address tokenIn, address tokenOut, uint256 amount, address recipient) =
            abi.decode(data, (PoolKey, address, address, uint256, address));
        IPoolManager pm = IPoolManager(poolManager);
        uint256 got = RealmAnyPairsRouteLib.swapExactIn(pm, key, tokenIn, amount);
        RealmAnyPairsRouteLib.settleAndTake(pm, tokenIn, amount, tokenOut, recipient, got);
        return abi.encode(got);
    }

    /// @dev The route pool's current sqrt price and LP fee in pips.
    function _sqrtAndFee(RealmAnyPairsRouteLib.Route memory r, address input, address asset)
        internal
        view
        returns (uint160 sqrtP, uint256 feePips)
    {
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            address pool = IAutoBasketV3Factory(v3Factory).getPool(input, asset, r.fee);
            (bool ok, bytes memory d) = pool.staticcall(abi.encodeWithSignature("slot0()"));
            if (!ok || d.length < 32) revert NoPrice();
            sqrtP = uint160(abi.decode(d, (uint256)));
            feePips = r.fee;
        } else {
            PoolKey memory key = RealmAnyPairsRouteLib.poolKey(input, asset, r.fee, r.tickSpacing, r.hooks);
            uint24 lpFee;
            (sqrtP,,, lpFee) = IPoolManager(poolManager).getSlot0(key.toId());
            feePips = lpFee;
        }
        if (sqrtP == 0 || feePips >= 1_000_000) revert NoPrice();
    }

    /// @dev What `amount` of `input` buys at the route pool's current price, net of its LP fee.
    function _spotOut(RealmAnyPairsRouteLib.Route memory r, address input, address asset, uint256 amount)
        internal
        view
        returns (uint256 out)
    {
        (uint160 sqrtP, uint256 feePips) = _sqrtAndFee(r, input, asset);
        bool zeroForOne = input < asset;
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP;
            out = zeroForOne ? FullMath.mulDiv(ratioX192, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
            out = zeroForOne ? FullMath.mulDiv(ratioX128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratioX128);
        }
        out = (out * (1_000_000 - feePips)) / 1_000_000;
    }

    function _v3FactoryForRoutes() internal view returns (address) {
        return swapRouter == address(0) ? address(0) : v3Factory;
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) return false;
        return IAutoBasketExttload(pm).exttload(V4_IS_UNLOCKED_SLOT) != bytes32(0);
    }

    // ─────────────────────────── auto-push ───────────────────────────

    /// @notice Round-robin push of every denomination to holders. The multi-basket tracker's loop, with one change: the
    /// gas for {claimableOf} (which settles conversions lazily) is reserved per denomination BEFORE it runs, so a push is
    /// only started with its full {PUSH_GAS} and the cursor writes still in hand.
    function process(uint256 gasBudget) external nonReentrant returns (uint256 pushed) {
        return _process(gasBudget);
    }

    function _process(uint256 gasBudget) internal returns (uint256 pushed) {
        uint256 n = _holders.length;
        if (n == 0) return 0;
        uint256 dCount = denominations.length;
        bool locked = _v4LockHeld();
        uint256 floor_ = PUSH_GAS + PUSH_TAIL_GAS + VIEW_BASE_GAS + (locked ? GATE_GAS : 0);
        if (gasleft() < floor_) return 0;
        uint8[] memory allowedCache = locked ? new uint8[](dCount) : new uint8[](0);
        // The coin's own transfer needs its `minDebit` floor, far above {PUSH_GAS}: read once per call, only when the coin
        // is a denomination at all.
        uint256 coinPushGas = isDenomination[token] ? _coinPushGas() : PUSH_GAS;
        uint256 gasStart = gasleft();
        uint256 idx = lastProcessedIndex;
        // The set may have changed since the cursor was saved (a {distributeFor} pre-sync appends new holders or
        // swap-and-pops emptied ones): resume in range, so the walk steps to idx+1 or wraps and never reads OOB.
        // The per-holder denomination resume below is already keyed on `lastProcessedHolder`, so a holder that
        // moved simply restarts at denomination 0 -- paid denominations then claim zero and cost one view.
        if (idx >= n) idx = n - 1;
        uint256 resumeDenom = _lastProcessedDenom;
        uint256 newDenomCursor = resumeDenom;
        uint256 iterations;
        while (iterations < n) {
            if (gasleft() < floor_) break;
            uint256 len = _holders.length;
            if (len == 0) break;
            uint256 nextIdx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[nextIdx];
            uint256 di = (resumeDenom != 0 && resumeDenom < dCount && h == lastProcessedHolder) ? resumeDenom : 0;
            resumeDenom = 0;
            uint256 startDi = di;
            bool finishedHolder = true;
            for (; di < dCount; ++di) {
                address d = denominations[di];
                uint256 pushGas = d == token ? coinPushGas : PUSH_GAS;
                uint256 need = pushGas + PUSH_TAIL_GAS + VIEW_BASE_GAS + VIEW_PER_LEG_GAS * _denomLegs[d].length
                    + ((locked && allowedCache[di] == 0) ? GATE_GAS : 0);
                // More than this whole call ever had (e.g. the coin's fixed transfer stipend): skip it rather than park
                // on it forever; a call with more gas (the hook's post-swap step, a claim) pays it.
                if (need > gasStart) continue;
                if (gasleft() < need) {
                    finishedHolder = false;
                    break;
                }
                if (di != startDi && gasStart - gasleft() > gasBudget) {
                    finishedHolder = false;
                    break;
                }
                if (locked) {
                    uint8 a = allowedCache[di];
                    if (a == 0) {
                        a = _inSwapAllowed(d) ? 2 : 1;
                        allowedCache[di] = a;
                    }
                    if (a == 1) continue;
                }
                uint256 amt = claimableOf(h, d);
                if (amt != 0) {
                    try this.pushReward{gas: pushGas}(h, d, amt) {
                        unchecked {
                            ++pushed;
                        }
                    } catch {
                        emit LegPaymentFailed(h, d, amt);
                    }
                }
            }
            if (!finishedHolder) {
                newDenomCursor = di < dCount ? di : 0;
                if (newDenomCursor != 0 && lastProcessedHolder != h) lastProcessedHolder = h;
                break;
            }
            idx = nextIdx;
            newDenomCursor = 0;
            unchecked {
                ++iterations;
            }
            if (gasStart - gasleft() > gasBudget) break;
        }
        lastProcessedIndex = idx;
        if (newDenomCursor != _lastProcessedDenom) _lastProcessedDenom = uint96(newDenomCursor);
    }

    /// @dev Push stipend for the coin as a denomination: `minDebit + minDebit/63 +` {COIN_PUSH_OVERHEAD}, never below
    /// {PUSH_GAS}. `minDebit` is fixed after `initTracker` (zero on a `TokenPlain` before `attachTracker`: no floor then).
    function _coinPushGas() internal view returns (uint256 g) {
        g = PUSH_GAS;
        (bool ok, bytes memory ret) = token.staticcall{gas: 30_000}(abi.encodeWithSignature("syncGasParams()"));
        if (!ok || ret.length < 96) return g;
        (, uint256 minDebit,) = abi.decode(ret, (uint256, uint256, uint256));
        uint256 c = minDebit + minDebit / 63 + COIN_PUSH_OVERHEAD;
        if (c > g) g = c;
    }

    /// @dev Inside a {distributeFor} this skims {POKE_FEE_BPS} of `amount` for the poker and holds it here until
    /// {distributeFor} forwards it. THE LEDGER IS UNCHANGED BY THE SKIM: `withdrawnRewards` and `reserve` both
    /// move by the full nominal `amount`, so `balance >= reserve` and the sum of claimable stay exact, and a
    /// reverted push rolls the accrual back with it (transient storage reverts too). {RewardClaimed} reports the
    /// NET amount the holder received; gross is that plus {PokePaid}.
    function pushReward(address account, address denomination, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        withdrawnRewards[account][denomination] += amount;
        _spend(denomination, amount);
        uint256 net = amount;
        uint256 f;
        if (_poker != address(0) && amount >= minPokeOf[denomination]) {
            f = (amount * POKE_FEE_BPS) / BPS;
            net = amount - f;
        }
        // Inside someone else's unlock a reward token's transfer must not leave a PoolManager delta open: it would revert
        // the trader's whole transaction (any creator-chosen leg token could halt trading). Revert this push instead.
        bool locked = _v4LockHeld();
        uint256 openBefore = locked ? IPoolManager(poolManager).getNonzeroDeltaCount() : 0;
        // (A) sender side -- see the note below. (B) recipient side, for the fee.
        uint256 before = IERC20(denomination).balanceOf(address(this));
        uint256 toBefore = IERC20(denomination).balanceOf(account);
        IERC20(denomination).safeTransfer(account, net);
        // Round 14 (F-2): nested rather than one multi-line condition, so the two reads still happen ONLY when
        // `locked` -- identical semantics and identical gas on the unlocked path.
        if (locked) {
            if (IPoolManager(poolManager).getNonzeroDeltaCount() != openBefore) revert OpenDelta();
            // nor leave a `sync` pending that the trader's settlement would then mis-credit
            if (IAutoBasketExttload(poolManager).exttload(V4_SYNCED_CURRENCY_SLOT) != bytes32(0)) revert OpenDelta();
        }
        // TWO INVARIANTS MEET AT THIS SITE, AND THEY ARE NOT THE SAME QUESTION. See the fuller note at the matching
        // site in {RealmAnyPairsDividendTrackerQuote._pushReward}.
        //   (A) ROUND 15 -- "did the value actually move?" A LEDGER question: only the SENDER's decrease can answer
        //       it, and a recipient that shuffles its own balance mid-transfer must not be able to forge it. That is
        //       `moved`, and it is what {ZeroDelivery} tests.
        //   (B) ROUND 8/9 (L2) -- "how much did the holder receive?" A PRICING question: the poke fee is what a third
        //       party earns for the work done, and the work delivered is what LANDED. That is `delivered`.
        // They are equal on a well-behaved token and diverge on a fee-on-transfer one. Using the recipient side for
        // (B) is strictly conservative: `earned` is bounded by `f`, which was already carved out of the holder's
        // `amount`, so a smaller `landed` only makes the poker earn less and the remainder returns to holders.
        uint256 aft = IERC20(denomination).balanceOf(address(this));
        uint256 moved = before > aft ? before - aft : 0;
        if (moved > net) moved = net;
        uint256 toAft = IERC20(denomination).balanceOf(account);
        uint256 delivered = toAft > toBefore ? toAft - toBefore : 0;
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
            uint256 earned = delivered >= net ? f : FullMath.mulDiv(f, delivered, net);
            if (earned != 0) _pokeAccAdd(denomination, earned);
        }
        // A coin-denominated payout IS a coin transfer, so the recipient's tracked balance has just gone stale.
        // Repair it here instead of relying on the coin's optional credit: since audit round 8 that credit
        // reserves the heaviest coin's debit floor and so never runs inside a gas-capped push frame.
        if (denomination == token) _syncBalance(account);
        emit RewardClaimed(account, denomination, delivered);
    }

    function _inSwapAllowed(address denomination) internal view returns (bool) {
        (bool ok, bytes memory d) =
            feeder.staticcall{gas: 60_000}(abi.encodeWithSignature("inSwapAllowed(address)", denomination));
        return ok && d.length == 32 && abi.decode(d, (uint256)) != 0;
    }

    function processHolders(address[] calldata holders, uint256 gasBudget)
        external
        nonReentrant
        returns (uint256 processed)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        uint256 cap = PROCESS_HOLDER_BASE_GAS + PROCESS_HOLDER_PER_DENOM_GAS * denominations.length
            + VIEW_PER_LEG_GAS * 2 * _convLegs.length;
        uint256 gasStart = gasleft();
        for (uint256 i; i < holders.length; ++i) {
            if (gasStart - gasleft() > gasBudget) break;
            try this._processHolder{gas: cap}(holders[i]) {
                unchecked {
                    ++processed;
                }
            } catch {
                emit HolderPayoutFailed(holders[i]);
            }
        }
    }

    function _processHolder(address holder) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _syncBalance(holder);
        if (_payAll(holder, holder, denominations) == 0) revert NothingToClaim();
    }

    // ─────────────────────────── claim ───────────────────────────

    /// @notice Pull everything owed, each reward in its own token. No swaps.
    function claim() external nonReentrant returns (uint256 denomsPaid) {
        return _claim(msg.sender, msg.sender, denominations);
    }

    function claimTo(address to) external nonReentrant returns (uint256 denomsPaid) {
        _checkRecipient(to);
        return _claim(msg.sender, to, denominations);
    }

    function claimDenominations(address to, address[] calldata denoms) external nonReentrant returns (uint256 denomsPaid) {
        _checkRecipient(to);
        if (denoms.length == 0) revert NothingToClaim();
        for (uint256 i; i < denoms.length; ++i) {
            if (!isDenomination[denoms[i]]) revert NotADenomination();
        }
        return _claim(msg.sender, to, denoms);
    }

    /// @notice Take your pending share of every not-yet-converted leg NOW, in its input token, together with everything
    /// else you are owed. Your share leaves the conversion pool; nobody else's changes.
    function claimPending(address to) external nonReentrant returns (uint256 denomsPaid) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        _pullPending(msg.sender);
        return _claim(msg.sender, to, denominations);
    }

    /// @notice Take everything as ONE token: `tokenOut` (address(0) = native ETH, via WETH). Each denomination you are
    /// owed is converted through `routes[i]` (empty = discover; a V3 path or a V4 `PoolKey` otherwise) under your own
    /// `minOuts[i]`, both indexed like {denominations}. A denomination that fails to convert reverts the claim if its
    /// minimum is non-zero, and is paid in its own token if the minimum is zero. `withPending` first pulls your pending
    /// shares ({claimPending}) so they are converted too.
    function claimAs(address to, address tokenOut, bytes[] calldata routes, uint256[] calldata minOuts, bool withPending)
        external
        nonReentrant
        returns (uint256 denomsPaid)
    {
        if (_v4LockHeld()) revert NotDuringSwap();
        _checkRecipient(to);
        uint256 dCount = denominations.length;
        if (routes.length != dCount) revert BadRoutes();
        if (minOuts.length != dCount) revert BadMinOuts();
        if (tokenOut == address(0) && weth == address(0)) revert NoNativeInput();
        if (withPending) _pullPending(msg.sender);
        _syncBalance(msg.sender);
        bool owed;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            uint256 amt = claimableOf(msg.sender, d);
            if (amt == 0) continue;
            owed = true;
            withdrawnRewards[msg.sender][d] += amt;
            if (d == tokenOut) {
                if (_payDirect(msg.sender, to, d, amt)) ++denomsPaid;
                continue;
            }
            if (gasleft() < (LEG_GAS_CAP * 64) / 63 + 30_000) revert InsufficientGasForLeg();
            try this.claimSwapSelf{gas: LEG_GAS_CAP}(d, tokenOut, amt, minOuts[i], routes[i], to) returns (uint256 out) {
                emit RewardClaimed(msg.sender, tokenOut, out);
                ++denomsPaid;
            } catch {
                if (minOuts[i] != 0) revert LegMinOutUnmet();
                emit LegSwapFailed(msg.sender, d, tokenOut, amt);
                if (_payDirect(msg.sender, to, d, amt)) ++denomsPaid;
            }
        }
        if (!owed) revert NothingToClaim();
        if (denomsPaid == 0) revert NothingDelivered();
    }

    /// @dev Self-only leg of {claimAs}: convert `amt` of `d` into `tokenOut` for `to`, measured at the recipient.
    function claimSwapSelf(address d, address tokenOut, uint256 amt, uint256 minOut, bytes calldata route, address to)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        bool native = tokenOut == address(0);
        address target = native ? weth : tokenOut;
        _spend(d, amt);
        if (d == target) {
            out = amt; // WETH owed, ETH wanted: no swap
        } else {
            // No discovery at any price: a discovered pool can be planted at any price, so an empty route needs a floor.
            if (route.length == 0 && minOut == 0) revert NoRouteFound();
            RealmAnyPairsRouteLib.Route memory r = _routeFor(d, target, route);
            address recipient = native ? address(this) : to;
            uint256 before = IERC20(target).balanceOf(recipient);
            uint256 reported = _swap(r, d, target, amt, minOut, recipient);
            uint256 aft = IERC20(target).balanceOf(recipient);
            // NOT a delivery, so the uniform sender-side rule does NOT apply here: this measures a swap's OUTPUT
            // ARRIVING from a router, not value leaving this contract. The recipient's increase is the correct side,
            // and it is additionally clamped to the router's own reported output below. (Audit round 16.)
            out = aft > before ? aft - before : 0;
            // Capped at the swap's own output: WETH pushed to this contract during the swap (e.g. by a hook on the
            // claimer's route triggering a rewards delivery) is not the claimer's.
            if (out > reported) out = reported;
        }
        if (out < minOut) revert BelowMinOut();
        if (native) {
            IAutoBasketWETH(weth).withdraw(out);
            (bool ok,) = to.call{value: out}("");
            if (!ok) revert EthSendFailed();
        }
    }

    function _pullPending(address account) internal {
        _syncBalance(account);
        uint256 bal = trackedBalance[account];
        uint256 n = _convLegs.length;
        for (uint256 id; id < n; ++id) {
            _settle(account, id, bal);
            HolderLeg storage s = _holderLeg[account][id];
            uint256 p = s.pend;
            if (p == 0) continue;
            s.pend = 0;
            address input = _convLegs[id].input;
            legOut[id] += p;
            buffered[input] -= p;
            reserve[input] += p;
            credited[account][input] += p;
            emit PendingPulled(account, id, p);
        }
    }

    function _claim(address account, address to, address[] memory denoms) internal returns (uint256 denomsPaid) {
        if (_v4LockHeld()) revert NotDuringSwap();
        _syncBalance(account);
        bool owed;
        for (uint256 i; i < denoms.length; ++i) {
            if (claimableOf(account, denoms[i]) != 0) {
                owed = true;
                break;
            }
        }
        if (!owed) revert NothingToClaim();
        denomsPaid = _payAll(account, to, denoms);
        if (denomsPaid == 0) revert NothingDelivered();
    }

    function _payAll(address account, address to, address[] memory denoms) internal returns (uint256 paid) {
        for (uint256 i; i < denoms.length; ++i) {
            address d = denoms[i];
            uint256 amt = claimableOf(account, d);
            if (amt == 0) continue;
            withdrawnRewards[account][d] += amt;
            if (_payDirect(account, to, d, amt)) {
                unchecked {
                    ++paid;
                }
            }
        }
    }

    function _checkRecipient(address to) internal view {
        // Round 14 (F-2): single-line conditions only -- see the note on the other rewritten spans in this file.
        if (to == address(0) || to == address(this) || to == token || isDenomination[to]) revert ZeroRecipient();
        if (to == swapRouter || to == feeder || to == poolManager) revert ZeroRecipient();
    }

    /// @dev A reverting transfer re-credits the account and reports false; the debit is nominal, the report measured.
    function _payDirect(address account, address to, address denomination, uint256 amt) internal returns (bool) {
        try this._transferDirect(to, denomination, amt) returns (uint256 delivered) {
            emit RewardClaimed(account, denomination, delivered);
            return true;
        } catch {
            withdrawnRewards[account][denomination] -= amt;
            emit LegPaymentFailed(account, denomination, amt);
            return false;
        }
    }

    function _transferDirect(address to, address denomination, uint256 amt) external returns (uint256 delivered) {
        if (msg.sender != address(this)) revert OnlySelf();
        _spend(denomination, amt);
        uint256 before = IERC20(denomination).balanceOf(address(this));
        IERC20(denomination).safeTransfer(to, amt);
        uint256 aft = IERC20(denomination).balanceOf(address(this));
        delivered = before > aft ? before - aft : 0;
        if (delivered > amt) delivered = amt;
        // Same guard as {pushReward}: a transfer that reports success but moves nothing must not consume
        // the holder's entitlement. {_payDirect}'s try/catch re-credits and reports the failure.
        if (delivered == 0) revert ZeroDelivery();
        // See {pushReward}: a coin-denominated payout moves the coin, so repair the recipient's tracked balance
        // here rather than leaning on the coin's optional credit.
        if (denomination == token) _syncBalance(to);
    }
}
