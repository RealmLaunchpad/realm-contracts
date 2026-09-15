// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RealmAnyPairsRouteLib} from "./RealmAnyPairsRouteLib.sol";

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
 *             converted through a route your front end passes (or discovered), under your own per-denomination minimum.
 *
 *         EXACT PER-HOLDER ACCOUNTING. Each converting leg keeps an index of pending-input-per-share and a list of EPOCHS,
 *         one per conversion (or fallback): the index at that moment, the rate, and running sums of rate x index-growth.
 *         A holder's position -- index, pending, epoch -- is settled whenever their balance changes, in O(1) per leg no
 *         matter how many conversions happened since: the pending carried in converts at the first epoch's rate, and
 *         everything accrued after it converts through the running sums. Views compute the same thing without writing.
 *         The cost is paid on every transfer of the coin, per converting leg ({SYNC_PER_LEG_GAS}); the constructor refuses
 *         a configuration whose per-transfer stipend would exceed what the coin forwards ({MAX_TRACKER_SYNC_GAS}).
 *
 *         SLIPPAGE. A conversion must return at least `spot x (1 - slippageBps)`, spot = the route pool's current price net
 *         of its LP fee. It bounds price impact; it does NOT stop a sandwich (accepted). Creator-set, 0.1%-20%.
 *
 *         ROUTES. The creator stores a leg's route with {setRoute} (a V3 path or a V4 `PoolKey` -- the only way to reach a
 *         pool behind a custom hook, i.e. every tokenized stock on Robinhood Chain); with none stored the deepest
 *         discoverable pool is used. Routes through {feeder} are refused.
 *
 *         FALLBACK. A leg whose conversion keeps failing for {fallbackDelay} (creator-set, 1 hour-7 days) is resolved in the
 *         input token instead. A failure that only ran out of the gas it was given does not start that clock.
 *
 *         IN-SWAP V4. Inside a swap the PoolManager is already unlocked, so a conversion swaps and settles directly. It never
 *         does so while another caller has a `sync` pending on the PoolManager (read from its transient slot).
 */
contract RealmAnyPairsDividendTrackerAutoBasket {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal constant Q128 = 2 ** 128;
    /// @dev Top bit of an epoch's `rate`: the epoch resolved into the INPUT (a fallback), not the asset.
    uint256 internal constant QUOTE_FLAG = 1 << 255;
    uint16 internal constant BPS = 10_000;
    uint256 internal constant MAX_LEGS = 10;
    uint256 internal constant MAX_TOTAL_LEGS = 60;
    uint256 internal constant ABSOLUTE_MAX_DENOMINATIONS = 25;
    uint256 internal constant MAX_MIN_ELIGIBLE_MULTIPLE = 1e2;

    /// @dev Same as {RealmAnyPairsTokenDividend.MAX_TRACKER_SYNC_GAS}: the most the coin ever forwards to {setBalance}.
    uint256 internal constant MAX_TRACKER_SYNC_GAS = 1_100_000;
    uint256 internal constant SYNC_BASE_GAS = 170_000;
    uint256 internal constant SYNC_PER_DENOM_GAS = 34_000;
    /// @dev Worst case to settle one holder on one converting leg (two epochs read, three slots written).
    uint256 internal constant SYNC_PER_LEG_GAS = 80_000;

    uint256 internal constant PUSH_GAS = 170_000;
    uint256 internal constant PUSH_TAIL_GAS = 40_000;
    uint256 internal constant GATE_GAS = 65_000;
    /// @dev Reserved for {claimableOf} before a push: a base plus each leg that feeds the denomination.
    uint256 internal constant VIEW_BASE_GAS = 10_000;
    uint256 internal constant VIEW_PER_LEG_GAS = 20_000;
    uint256 internal constant PROCESS_HOLDER_BASE_GAS = 140_000;
    uint256 internal constant PROCESS_HOLDER_PER_DENOM_GAS = 200_000;
    /// @dev Push budget used by {convertStep} when it has nothing to convert.
    uint256 internal constant CONVERT_PUSH_BUDGET = 400_000;

    uint256 internal constant CONVERT_GAS_MAX = 450_000;
    uint256 internal constant CONVERT_GAS_MIN = 150_000;
    uint256 internal constant CONVERT_TAIL_GAS = 200_000;
    uint256 internal constant CONVERT_SCAN = 3;
    /// @dev Gas a holder-side conversion in {claimAs} may spend per denomination.
    uint256 internal constant LEG_GAS_CAP = 450_000;

    uint16 public constant DEFAULT_SLIPPAGE_BPS = 300;
    uint16 public constant MIN_SLIPPAGE_BPS = 10;
    uint16 public constant MAX_SLIPPAGE_BPS = 2_000;
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
    mapping(address => mapping(uint256 => HolderLeg)) private _holderLeg;
    /// @notice Settled conversion credits, [account][denomination].
    mapping(address => mapping(address => uint256)) public credited;
    mapping(address => mapping(address => bytes)) private _routeOf;
    mapping(address => uint256) public minConvertOf;
    uint256 private _convertCursor;
    bool private transient _v4Swapping;

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
    event LegSwapFailed(
        address indexed account, address indexed denomination, address indexed tokenOut, uint256 amount
    );
    event HolderPayoutFailed(address indexed holder);
    event MinEligibleSet(uint256 oldValue, uint256 newValue);
    event PendingCredited(address indexed input, uint256 amount);
    event Converted(
        uint256 indexed legId, address indexed input, address indexed asset, uint256 amountIn, uint256 amountOut
    );
    event ConversionFailed(uint256 indexed legId, address indexed input, address indexed asset, uint256 amountIn);
    event ConversionFallback(uint256 indexed legId, address indexed input, address indexed asset, uint256 amount);
    event PendingPulled(address indexed account, uint256 indexed legId, uint256 amount);
    event SlippageSet(uint16 oldBps, uint16 newBps);
    event FallbackDelaySet(uint256 oldDelay, uint256 newDelay);
    event RouteSet(address indexed input, address indexed asset, bytes route);
    event MinConvertSet(address indexed input, uint256 amount);

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

    modifier onlyToken() {
        if (msg.sender != token) {
            revert OnlyToken();
        }
        _;
    }

    modifier onlyFeeder() {
        if (msg.sender != feeder) {
            revert OnlyFeeder();
        }
        _;
    }

    modifier nonReentrant() {
        if (_entered == 2) {
            revert Reentrancy();
        }
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
        if (c.swapRouter != address(0)) {
            excluded[c.swapRouter] = true;
        }
        if (c.poolManager != address(0)) {
            excluded[c.poolManager] = true;
        }

        uint256 inCount = c.inputs.length;
        if (inCount == 0) {
            revert BadInputs();
        }
        uint256 totalLegs;
        for (uint256 ii; ii < inCount; ++ii) {
            address input = c.inputs[ii].input;
            if (input == address(0) || isInput[input]) {
                revert BadInputs();
            }
            isInput[input] = true;
            inputs.push(input);
            _addDenomination(input);

            Leg[] memory legs = c.inputs[ii].legs;
            uint256 n = legs.length;
            if (n == 0 || n > MAX_LEGS) {
                revert BadBasket();
            }
            totalLegs += n;
            if (totalLegs > MAX_TOTAL_LEGS) {
                revert TooManyLegs();
            }
            uint256 sumBps;
            uint16 swapBps;
            for (uint256 i; i < n; ++i) {
                Leg memory leg = legs[i];
                if (leg.asset == address(0) || leg.bps == 0) {
                    revert BadBasket();
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
                }
            }
            if (sumBps != BPS) {
                revert BadBasket();
            }
            swapBpsOf[input] = swapBps;
        }
        if (denominations.length > ABSOLUTE_MAX_DENOMINATIONS) {
            revert AboveAbsoluteMax();
        }
        if (_syncGasFor(denominations.length, _convLegs.length) > MAX_TRACKER_SYNC_GAS) {
            revert TooHeavy();
        }
    }

    function _addDenomination(address d) private {
        if (isDenomination[d]) {
            return;
        }
        isDenomination[d] = true;
        denominations.push(d);
    }

    function _syncGasFor(uint256 dCount, uint256 legCount_) internal pure returns (uint256) {
        return SYNC_BASE_GAS + SYNC_PER_DENOM_GAS * dCount + SYNC_PER_LEG_GAS * legCount_;
    }

    receive() external payable {
        if (msg.sender != weth) {
            revert NoNativeInput();
        }
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
    /// would use (the stored one, else the discovered one; empty when there is none).
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
        route = _routeOf[input][asset];
        if (route.length == 0) {
            route = RealmAnyPairsRouteLib.encode(
                RealmAnyPairsRouteLib.best(_v3FactoryForRoutes(), poolManager, input, false, asset), asset
            );
        }
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
    function _lazy(address account, uint256 id, uint256 bal)
        internal
        view
        returns (uint256 pend, uint256 a, uint256 q)
    {
        HolderLeg memory s = _holderLeg[account][id];
        if (s.idx == 0) {
            return (0, 0, 0);
        }
        uint256 n = epochCount[id];
        uint256 now_ = legIdx[id];
        if (s.ep == n) {
            return (s.pend + FullMath.mulDiv(bal, now_ - s.idx, MAGNITUDE), 0, 0);
        }
        Epoch storage e1 = _epochs[id][s.ep + 1];
        uint256 first = s.pend + FullMath.mulDiv(bal, e1.idx - s.idx, MAGNITUDE);
        if (e1.rate & QUOTE_FLAG != 0) {
            q = first;
        } else {
            a = FullMath.mulDiv(first, e1.rate, Q128);
        }
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
        if (s.idx == now_ && s.ep == n) {
            return;
        }
        if (s.idx != 0 && (bal != 0 || s.pend != 0)) {
            (uint256 pend, uint256 a, uint256 q) = _lazy(account, id, bal);
            ConvLeg storage l = _convLegs[id];
            if (a != 0) {
                credited[account][l.asset] += a;
            }
            if (q != 0) {
                credited[account][l.input] += q;
            }
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

    // ─────────────────────────── creator settings ───────────────────────────

    function setSlippageBps(uint16 newBps) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (newBps < MIN_SLIPPAGE_BPS || newBps > MAX_SLIPPAGE_BPS) {
            revert BadSlippage();
        }
        emit SlippageSet(slippageBps, newBps);
        slippageBps = newBps;
    }

    function setFallbackDelay(uint256 newDelay) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (newDelay < MIN_FALLBACK_DELAY || newDelay > MAX_FALLBACK_DELAY) {
            revert BadFallbackDelay();
        }
        emit FallbackDelaySet(fallbackDelay, newDelay);
        fallbackDelay = newDelay;
    }

    /// @notice Store the route `input` converts into `asset` through: a 43-byte V3 path or an ABI-encoded V4 `PoolKey`,
    /// validated now ({RealmAnyPairsRouteLib.supplied}). Empty clears it back to discovery.
    function setRoute(address input, address asset, bytes calldata route) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (!_isConvertingLeg(input, asset)) {
            revert NotALeg();
        }
        if (route.length != 0) {
            RealmAnyPairsRouteLib.supplied(route, _v3FactoryForRoutes(), poolManager, input, false, asset, feeder);
        }
        _routeOf[input][asset] = route;
        emit RouteSet(input, asset, route);
    }

    function setMinConvert(address input, uint256 amount) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (!isInput[input]) {
            revert BadInputs();
        }
        minConvertOf[input] = amount;
        emit MinConvertSet(input, amount);
    }

    function setMinEligible(uint256 newMinEligible) external {
        if (msg.sender != _tokenCreator()) {
            revert NotCreator();
        }
        if (newMinEligible < minEligibleFloor) {
            revert MinEligibleBelowFloor();
        }
        if (newMinEligible > minEligibleFloor * MAX_MIN_ELIGIBLE_MULTIPLE) {
            revert MinEligibleTooHigh();
        }
        if (newMinEligible > eligibleSupply) {
            revert MinEligibleTooHigh();
        }
        emit MinEligibleSet(minEligible, newMinEligible);
        minEligible = newMinEligible;
    }

    function _isConvertingLeg(address input, address asset) internal view returns (bool) {
        if (!isInput[input] || asset == input) {
            return false;
        }
        uint256[] storage ids = _legIdsOf[input];
        for (uint256 i; i < ids.length; ++i) {
            if (_convLegs[ids[i]].asset == asset) {
                return true;
            }
        }
        return false;
    }

    /// @dev The coin's current creator as the hook records it (CTO-aware; renounced reads as none).
    function _tokenCreator() internal view returns (address c) {
        (bool hok, bytes memory hret) =
            feeder.staticcall{gas: 50_000}(abi.encodeWithSignature("creatorOfCoin(address)", token));
        if (hok && hret.length >= 32) {
            c = abi.decode(hret, (address));
            if (c == address(0)) {
                revert NotCreator();
            }
            return c;
        }
        (bool ok, bytes memory ret) = token.staticcall{gas: 20_000}(abi.encodeWithSelector(0x02d05d3f)); // creator()
        if (!ok || ret.length < 32) {
            revert NotCreator();
        }
        c = abi.decode(ret, (address));
        if (c == address(0)) {
            revert NotCreator();
        }
    }

    // ─────────────────────────── balance mirror (token-driven) ───────────────────────────

    function setBalance(address account, uint256 newBalance) external onlyToken {
        if (excluded[account]) {
            newBalance = 0;
        }
        _applyBalance(account, newBalance);
    }

    function _applyBalance(address account, uint256 newBalance) internal {
        uint256 old = trackedBalance[account];
        if (newBalance == old) {
            return;
        }
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
            if (idx1 != 0) {
                _removeHolder(account, idx1);
            }
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
            if (trackedBalance[account] != 0) {
                _applyBalance(account, 0);
            }
            return;
        }
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || ret.length < 32) {
            return;
        }
        uint256 real = abi.decode(ret, (uint256));
        if (real != trackedBalance[account]) {
            _applyBalance(account, real);
        }
    }

    // ─────────────────────────── feeding ───────────────────────────

    function feedToken(uint256) external onlyFeeder nonReentrant {
        _syncAll();
    }

    /// @notice The hook's native rewards slot. Wrapped and booked at once unless this contract is already mid-operation,
    /// in which case the ETH waits for the next sync. Not `nonReentrant` on purpose: a revert here would send the hook's
    /// slice to its fallback ledger instead of to holders.
    function feed() external payable onlyFeeder {
        if (weth == address(0) || !isInput[weth]) {
            revert NoNativeInput();
        }
        if (_entered == 2) {
            return;
        }
        _entered = 2;
        _syncAll();
        _entered = 1;
    }

    function sync() external nonReentrant {
        _syncAll();
    }

    function pokePending() external nonReentrant {
        uint256 dCount = denominations.length;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            if (pending[d] != 0 && eligibleSupply >= minEligibleFloor) {
                uint256 p = pending[d];
                pending[d] = 0;
                _book(d, p);
            }
        }
        for (uint256 i; i < inputs.length; ++i) {
            _attribute(inputs[i]);
        }
    }

    function _syncAll() internal {
        address w = weth;
        if (w != address(0)) {
            uint256 native = address(this).balance;
            if (native != 0) {
                IAutoBasketWETH(w).deposit{value: native}();
            }
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
            if (bal < held) {
                emit RewardShortfall(d, held, bal);
            }
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
            unattributed[input] += toConvert;
            _attribute(input);
        }
        if (direct != 0) {
            reserve[input] += direct;
            _receive(input, direct);
        }
    }

    /// @dev Credit `input`'s not-yet-attributed converting share to holders as PENDING, split across its converting legs.
    function _attribute(address input) internal {
        uint256 u = unattributed[input];
        if (u == 0 || eligibleSupply < minEligibleFloor) {
            return;
        }
        unattributed[input] = 0;
        uint256[] storage ids = _legIdsOf[input];
        uint256 n = ids.length;
        uint256 s = swapBpsOf[input];
        uint256 given;
        uint256 supply = eligibleSupply;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            uint256 part = i + 1 == n ? u - given : (u * _convLegs[id].bps) / s;
            given += part;
            if (part == 0) {
                continue;
            }
            legIn[id] += part;
            legIdx[id] += (part * MAGNITUDE) / supply;
        }
        emit PendingCredited(input, u);
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
        if (amount == 0) {
            return;
        }
        if (eligibleSupply < minEligibleFloor) {
            pending[d] += amount;
            return;
        }
        if (pending[d] != 0) {
            uint256 p = pending[d];
            pending[d] = 0;
            _book(d, p);
        }
        _book(d, amount);
    }

    function _book(address d, uint256 amount) internal {
        magnifiedRewardPerShare[d] += (amount * MAGNITUDE) / eligibleSupply;
        totalDistributed[d] += amount;
        emit RewardsDistributed(d, amount, magnifiedRewardPerShare[d]);
    }

    // ─────────────────────────── conversion ───────────────────────────

    /// @notice Convert (or fall back) at most one leg's pending pool; with nothing to convert, push rewards to holders
    /// instead. Permissionless; the tax hook calls it after every swap on this coin's pools.
    function convertStep() external nonReentrant returns (bool worked) {
        if (_convertStep()) {
            return true;
        }
        return _process(CONVERT_PUSH_BUDGET) != 0;
    }

    /// @notice The manual way: up to `steps` conversions in one call.
    function convert(uint256 steps) external nonReentrant returns (uint256 done) {
        for (uint256 i; i < steps; ++i) {
            if (!_convertStep()) {
                break;
            }
            unchecked {
                ++done;
            }
        }
    }

    function _convertStep() internal returns (bool) {
        uint256 total = _convLegs.length;
        if (total == 0) {
            return false;
        }
        bool locked = _v4LockHeld();
        if (locked && IAutoBasketExttload(poolManager).exttload(V4_SYNCED_CURRENCY_SLOT) != bytes32(0)) {
            return false;
        }
        uint256 cur = _convertCursor;
        uint256 scan = total < CONVERT_SCAN ? total : CONVERT_SCAN;
        for (uint256 k; k < scan; ++k) {
            uint256 id = (cur + k) % total;
            address input = _convLegs[id].input;
            _syncOne(input);
            _attribute(input);
            uint256 pool = legIn[id] - legOut[id];
            if (pool == 0 || pool < minConvertOf[input]) {
                continue;
            }
            uint256 next = (id + 1) % total;
            if (next != cur) {
                _convertCursor = next;
            }
            return _attempt(id, pool, locked);
        }
        return false;
    }

    function _attempt(uint256 id, uint256 amt, bool locked) internal returns (bool) {
        ConvLeg memory l = _convLegs[id];
        if (IERC20(l.input).balanceOf(address(this)) < reserve[l.input] + buffered[l.input]) {
            return false;
        }

        uint64 since = failingSince[id];
        if (since != 0 && block.timestamp >= since + fallbackDelay) {
            _closeEpoch(id, amt, 0, true);
            buffered[l.input] -= amt;
            reserve[l.input] += amt;
            failingSince[id] = 0;
            emit ConversionFallback(id, l.input, l.asset, amt);
            return true;
        }

        uint256 left = gasleft();
        if (left < (CONVERT_GAS_MIN * 64) / 63 + CONVERT_TAIL_GAS) {
            return false;
        }
        uint256 forward = ((left - CONVERT_TAIL_GAS) * 63) / 64;
        if (forward > CONVERT_GAS_MAX) {
            forward = CONVERT_GAS_MAX;
        }
        uint256 g0 = gasleft();
        try this.convertSelf{gas: forward}(l.input, l.asset, amt, locked) returns (uint256 out) {
            _closeEpoch(id, amt, out, false);
            buffered[l.input] -= amt;
            reserve[l.asset] += out;
            if (since != 0) {
                failingSince[id] = 0;
            }
            emit Converted(id, l.input, l.asset, amt, out);
        } catch {
            // Only a failure that did NOT exhaust its budget starts the fallback clock.
            if (since == 0 && g0 - gasleft() < forward - forward / 32) {
                failingSince[id] = uint64(block.timestamp);
            }
            emit ConversionFailed(id, l.input, l.asset, amt);
        }
        return true;
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
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        RealmAnyPairsRouteLib.Route memory r = _routeFor(input, asset, _routeOf[input][asset]);
        uint256 minOut = (_spotOut(r, input, asset, amount) * (BPS - slippageBps)) / BPS;
        if (minOut == 0) {
            revert NoPrice();
        }
        uint256 before = IERC20(asset).balanceOf(address(this));
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V4 && locked) {
            IPoolManager pm = IPoolManager(poolManager);
            PoolKey memory key = RealmAnyPairsRouteLib.poolKey(input, asset, r.fee, r.tickSpacing, r.hooks);
            uint256 got = RealmAnyPairsRouteLib.swapExactIn(pm, key, input, amount);
            RealmAnyPairsRouteLib.settleAndTake(pm, input, amount, asset, address(this), got);
        } else {
            _swap(r, input, asset, amount, minOut, address(this));
        }
        uint256 aft = IERC20(asset).balanceOf(address(this));
        out = aft > before ? aft - before : 0;
        if (out < minOut) {
            revert BelowMinOut();
        }
        if (FullMath.mulDiv(out, Q128, amount) >= QUOTE_FLAG) {
            revert NoPrice();
        }
    }

    function _routeFor(address tokenIn, address tokenOut, bytes memory route)
        internal
        view
        returns (RealmAnyPairsRouteLib.Route memory r)
    {
        address f = _v3FactoryForRoutes();
        r = route.length == 0
            ? RealmAnyPairsRouteLib.best(f, poolManager, tokenIn, false, tokenOut)
            : RealmAnyPairsRouteLib.supplied(route, f, poolManager, tokenIn, false, tokenOut, feeder);
        if (r.venue == RealmAnyPairsRouteLib.VENUE_NONE) {
            revert NoRouteFound();
        }
    }

    /// @dev Out-of-lock swap of `amount` `tokenIn` to `recipient` through `r` (V3 router or a V4 unlock).
    function _swap(
        RealmAnyPairsRouteLib.Route memory r,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) internal {
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            IERC20(tokenIn).forceApprove(swapRouter, amount);
            IAutoBasketSwapRouter02(swapRouter)
                .exactInput(
                    IAutoBasketSwapRouter02.ExactInputParams({
                        path: RealmAnyPairsRouteLib.v3Path(r, tokenOut),
                        recipient: recipient,
                        amountIn: amount,
                        amountOutMinimum: minOut
                    })
                );
            IERC20(tokenIn).forceApprove(swapRouter, 0);
        } else {
            PoolKey memory key = RealmAnyPairsRouteLib.poolKey(tokenIn, tokenOut, r.fee, r.tickSpacing, r.hooks);
            _v4Swapping = true;
            IPoolManager(poolManager).unlock(abi.encode(key, tokenIn, tokenOut, amount, recipient));
            _v4Swapping = false;
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager || !_v4Swapping) {
            revert OnlySelf();
        }
        (PoolKey memory key, address tokenIn, address tokenOut, uint256 amount, address recipient) =
            abi.decode(data, (PoolKey, address, address, uint256, address));
        IPoolManager pm = IPoolManager(poolManager);
        uint256 got = RealmAnyPairsRouteLib.swapExactIn(pm, key, tokenIn, amount);
        RealmAnyPairsRouteLib.settleAndTake(pm, tokenIn, amount, tokenOut, recipient, got);
        return "";
    }

    /// @dev What `amount` of `input` buys at the route pool's current price, net of its LP fee.
    function _spotOut(RealmAnyPairsRouteLib.Route memory r, address input, address asset, uint256 amount)
        internal
        view
        returns (uint256 out)
    {
        uint160 sqrtP;
        uint256 feePips;
        if (r.venue == RealmAnyPairsRouteLib.VENUE_V3) {
            address pool = IAutoBasketV3Factory(v3Factory).getPool(input, asset, r.fee);
            (bool ok, bytes memory d) = pool.staticcall(abi.encodeWithSignature("slot0()"));
            if (!ok || d.length < 32) {
                revert NoPrice();
            }
            sqrtP = uint160(abi.decode(d, (uint256)));
            feePips = r.fee;
        } else {
            PoolKey memory key = RealmAnyPairsRouteLib.poolKey(input, asset, r.fee, r.tickSpacing, r.hooks);
            uint24 lpFee;
            (sqrtP,,, lpFee) = IPoolManager(poolManager).getSlot0(key.toId());
            feePips = lpFee;
        }
        if (sqrtP == 0 || feePips >= 1_000_000) {
            revert NoPrice();
        }
        bool zeroForOne = input < asset;
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP;
            out = zeroForOne
                ? FullMath.mulDiv(ratioX192, amount, 1 << 192)
                : FullMath.mulDiv(1 << 192, amount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
            out = zeroForOne
                ? FullMath.mulDiv(ratioX128, amount, 1 << 128)
                : FullMath.mulDiv(1 << 128, amount, ratioX128);
        }
        out = (out * (1_000_000 - feePips)) / 1_000_000;
    }

    function _v3FactoryForRoutes() internal view returns (address) {
        return swapRouter == address(0) ? address(0) : v3Factory;
    }

    function _v4LockHeld() internal view returns (bool) {
        address pm = poolManager;
        if (pm == address(0)) {
            return false;
        }
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
        if (n == 0) {
            return 0;
        }
        uint256 dCount = denominations.length;
        bool locked = _v4LockHeld();
        uint256 floor_ = PUSH_GAS + PUSH_TAIL_GAS + VIEW_BASE_GAS + (locked ? GATE_GAS : 0);
        if (gasleft() < floor_) {
            return 0;
        }
        uint8[] memory allowedCache = locked ? new uint8[](dCount) : new uint8[](0);
        uint256 gasStart = gasleft();
        uint256 idx = lastProcessedIndex;
        uint256 resumeDenom = _lastProcessedDenom;
        uint256 newDenomCursor = resumeDenom;
        uint256 iterations;
        while (iterations < n) {
            if (gasleft() < floor_) {
                break;
            }
            uint256 len = _holders.length;
            if (len == 0) {
                break;
            }
            uint256 nextIdx = idx + 1 < len ? idx + 1 : 0;
            address h = _holders[nextIdx];
            uint256 di = (resumeDenom != 0 && resumeDenom < dCount && h == lastProcessedHolder) ? resumeDenom : 0;
            resumeDenom = 0;
            uint256 startDi = di;
            bool finishedHolder = true;
            for (; di < dCount; ++di) {
                address d = denominations[di];
                uint256 need = PUSH_GAS + PUSH_TAIL_GAS + VIEW_BASE_GAS + VIEW_PER_LEG_GAS * _denomLegs[d].length
                    + ((locked && allowedCache[di] == 0) ? GATE_GAS : 0);
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
                    if (a == 1) {
                        continue;
                    }
                }
                uint256 amt = claimableOf(h, d);
                if (amt != 0) {
                    try this.pushReward{gas: PUSH_GAS}(h, d, amt) {
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
                if (newDenomCursor != 0 && lastProcessedHolder != h) {
                    lastProcessedHolder = h;
                }
                break;
            }
            idx = nextIdx;
            newDenomCursor = 0;
            unchecked {
                ++iterations;
            }
            if (gasStart - gasleft() > gasBudget) {
                break;
            }
        }
        lastProcessedIndex = idx;
        if (newDenomCursor != _lastProcessedDenom) {
            _lastProcessedDenom = uint96(newDenomCursor);
        }
    }

    function pushReward(address account, address denomination, uint256 amount) external {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        withdrawnRewards[account][denomination] += amount;
        _spend(denomination, amount);
        uint256 before = IERC20(denomination).balanceOf(account);
        IERC20(denomination).safeTransfer(account, amount);
        uint256 aft = IERC20(denomination).balanceOf(account);
        uint256 delivered = aft > before ? aft - before : 0;
        if (delivered > amount) {
            delivered = amount;
        }
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
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        uint256 cap = PROCESS_HOLDER_BASE_GAS + PROCESS_HOLDER_PER_DENOM_GAS * denominations.length + VIEW_PER_LEG_GAS
            * 2 * _convLegs.length;
        uint256 gasStart = gasleft();
        for (uint256 i; i < holders.length; ++i) {
            if (gasStart - gasleft() > gasBudget) {
                break;
            }
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
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _syncBalance(holder);
        if (_payAll(holder, holder, denominations) == 0) {
            revert NothingToClaim();
        }
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

    function claimDenominations(address to, address[] calldata denoms)
        external
        nonReentrant
        returns (uint256 denomsPaid)
    {
        _checkRecipient(to);
        if (denoms.length == 0) {
            revert NothingToClaim();
        }
        for (uint256 i; i < denoms.length; ++i) {
            if (!isDenomination[denoms[i]]) {
                revert NotADenomination();
            }
        }
        return _claim(msg.sender, to, denoms);
    }

    /// @notice Take your pending share of every not-yet-converted leg NOW, in its input token, together with everything
    /// else you are owed. Your share leaves the conversion pool; nobody else's changes.
    function claimPending(address to) external nonReentrant returns (uint256 denomsPaid) {
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        _checkRecipient(to);
        _pullPending(msg.sender);
        return _claim(msg.sender, to, denominations);
    }

    /// @notice Take everything as ONE token: `tokenOut` (address(0) = native ETH, via WETH). Each denomination you are
    /// owed is converted through `routes[i]` (empty = discover; a V3 path or a V4 `PoolKey` otherwise) under your own
    /// `minOuts[i]`, both indexed like {denominations}. A denomination that fails to convert reverts the claim if its
    /// minimum is non-zero, and is paid in its own token if the minimum is zero. `withPending` first pulls your pending
    /// shares ({claimPending}) so they are converted too.
    function claimAs(
        address to,
        address tokenOut,
        bytes[] calldata routes,
        uint256[] calldata minOuts,
        bool withPending
    ) external nonReentrant returns (uint256 denomsPaid) {
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        _checkRecipient(to);
        uint256 dCount = denominations.length;
        if (routes.length != dCount) {
            revert BadRoutes();
        }
        if (minOuts.length != dCount) {
            revert BadMinOuts();
        }
        if (tokenOut == address(0) && weth == address(0)) {
            revert NoNativeInput();
        }
        if (withPending) {
            _pullPending(msg.sender);
        }
        _syncBalance(msg.sender);
        bool owed;
        for (uint256 i; i < dCount; ++i) {
            address d = denominations[i];
            uint256 amt = claimableOf(msg.sender, d);
            if (amt == 0) {
                continue;
            }
            owed = true;
            withdrawnRewards[msg.sender][d] += amt;
            if (d == tokenOut) {
                if (_payDirect(msg.sender, to, d, amt)) {
                    ++denomsPaid;
                }
                continue;
            }
            if (gasleft() < (LEG_GAS_CAP * 64) / 63 + 30_000) {
                revert InsufficientGasForLeg();
            }
            try this.claimSwapSelf{gas: LEG_GAS_CAP}(d, tokenOut, amt, minOuts[i], routes[i], to) returns (
                uint256 out
            ) {
                emit RewardClaimed(msg.sender, tokenOut, out);
                ++denomsPaid;
            } catch {
                if (minOuts[i] != 0) {
                    revert LegMinOutUnmet();
                }
                emit LegSwapFailed(msg.sender, d, tokenOut, amt);
                if (_payDirect(msg.sender, to, d, amt)) {
                    ++denomsPaid;
                }
            }
        }
        if (!owed) {
            revert NothingToClaim();
        }
        if (denomsPaid == 0) {
            revert NothingDelivered();
        }
    }

    /// @dev Self-only leg of {claimAs}: convert `amt` of `d` into `tokenOut` for `to`, measured at the recipient.
    function claimSwapSelf(address d, address tokenOut, uint256 amt, uint256 minOut, bytes calldata route, address to)
        external
        returns (uint256 out)
    {
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        bool native = tokenOut == address(0);
        address target = native ? weth : tokenOut;
        _spend(d, amt);
        if (d == target) {
            out = amt; // WETH owed, ETH wanted: no swap
        } else {
            RealmAnyPairsRouteLib.Route memory r = _routeFor(d, target, route);
            address recipient = native ? address(this) : to;
            uint256 before = IERC20(target).balanceOf(recipient);
            _swap(r, d, target, amt, minOut, recipient);
            uint256 aft = IERC20(target).balanceOf(recipient);
            out = aft > before ? aft - before : 0;
        }
        if (out < minOut) {
            revert BelowMinOut();
        }
        if (native) {
            IAutoBasketWETH(weth).withdraw(out);
            (bool ok,) = to.call{value: out}("");
            if (!ok) {
                revert EthSendFailed();
            }
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
            if (p == 0) {
                continue;
            }
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
        if (_v4LockHeld()) {
            revert NotDuringSwap();
        }
        _syncBalance(account);
        bool owed;
        for (uint256 i; i < denoms.length; ++i) {
            if (claimableOf(account, denoms[i]) != 0) {
                owed = true;
                break;
            }
        }
        if (!owed) {
            revert NothingToClaim();
        }
        denomsPaid = _payAll(account, to, denoms);
        if (denomsPaid == 0) {
            revert NothingDelivered();
        }
    }

    function _payAll(address account, address to, address[] memory denoms) internal returns (uint256 paid) {
        for (uint256 i; i < denoms.length; ++i) {
            address d = denoms[i];
            uint256 amt = claimableOf(account, d);
            if (amt == 0) {
                continue;
            }
            withdrawnRewards[account][d] += amt;
            if (_payDirect(account, to, d, amt)) {
                unchecked {
                    ++paid;
                }
            }
        }
    }

    function _checkRecipient(address to) internal view {
        if (
            to == address(0) || to == address(this) || to == token || isDenomination[to] || to == swapRouter
                || to == feeder || to == poolManager
        ) {
            revert ZeroRecipient();
        }
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
        if (msg.sender != address(this)) {
            revert OnlySelf();
        }
        _spend(denomination, amt);
        uint256 before = IERC20(denomination).balanceOf(to);
        IERC20(denomination).safeTransfer(to, amt);
        uint256 aft = IERC20(denomination).balanceOf(to);
        delivered = aft > before ? aft - before : 0;
        if (delivered > amt) {
            delivered = amt;
        }
    }
}
