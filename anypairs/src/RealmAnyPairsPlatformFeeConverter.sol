// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {RealmAnyPairsV3TwapOracle} from "./RealmAnyPairsV3TwapOracle.sol";

interface ILpfcV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ILpfcV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function liquidity() external view returns (uint128);
}

interface ILpfcSwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface ILpfcWeth {
    function withdraw(uint256) external;
}

interface ILpfcFeeHook {
    function owed(address payee, address token) external view returns (uint256);
    function pushOwed(address who, address token) external returns (uint256);
}

/// @title RealmAnyPairsPlatformFeeConverter
/// @notice The platform wallet the tax hook pushes its cut to. Receives the platform slot's in-swap quote pushes and turns them into ETH for {treasury}:
///   * `convert(quote)` is PERMISSIONLESS. It swaps up to {maxInPerCall} of the held quote along the admin-set route
///     to WETH or native ETH, unwraps if needed, and sends the ETH to {treasury}. A quote has EITHER a V3 route
///     ({setRoute}) or a V4 route ({setV4Route}); setting one clears the other.
///   * PRICE FLOOR, V3. `amountOutMinimum` is derived ON-CHAIN from each hop's V3 TWAP over {TWAP_SECONDS}, composed
///     across hops, less each hop's pool fee, less {MAX_SLIPPAGE_BPS}. A same-block spot manipulation does not move a
///     30-minute TWAP, so a sandwich makes the router revert and the call SKIPS (no swap, nothing lost). A hop without
///     enough observation history, with zero in-range liquidity, or with no pool, also SKIPS.
///   * PRICE FLOOR, V4. V4 core keeps NO price history -- there is no `observe` to call -- so this contract records its
///     own: see "V4 PRICE SAMPLES" below. The floor per hop is the MEDIAN tick of the pool's live samples, less the
///     pool's current LP fee, composed across hops, less {MAX_SLIPPAGE_BPS}. Too little history, or a spot price that
///     has left the median's band, SKIPS -- the same direction as V3: never swap on a price nobody has vouched for.
///   * SELF-FUNDING GAS. The caller is reimbursed `(gasUsed + GAS_OVERHEAD) * min(tx.gasprice, maxGasPrice) + tip` out of
///     the conversion's ETH, capped at {MAX_REIMBURSE_BPS} of it. If the floor cannot cover an estimated reimbursement
///     the call SKIPS before swapping (a keeper never pays to convert dust, and dust never burns fees).
///   * NATIVE. A native pool's platform push to this CONTRACT fails the hook's codeless rule and is credited to
///     `owed[converter][address(0)]`. `convert(address(0))` pulls it with the hook's permissionless `pushOwed` and
///     forwards the ETH (same reimbursement rule). The same pull runs for an ERC20 quote whose push fell back to
///     `owed[]` (quote denied in-swap, transfer reverted).
///
/// @dev V4 PRICE SAMPLES. For every pool on a V4 route this contract keeps a ring of up to {MAX_SAMPLES} (time, tick)
/// readings of that pool's slot0.
///   * WRITTEN BY `poke(quote)` (permissionless, no reimbursement) and automatically at the top of every
///     `convert(quote)`. At most one sample per {MIN_SAMPLE_SPACING} per pool, so a caller cannot fill the ring in
///     one block. Only pools on an admin-set route are ever sampled, so nobody can grow this contract's storage.
///   * USABLE when at least {MIN_SAMPLES} samples are no older than {MAX_SAMPLE_AGE} AND they span at least
///     {MIN_SAMPLE_SPAN}. The median, not the mean, is used: one reading taken at a pushed price cannot move it.
///   * SELF-GUARDING. Once a pool has {MIN_SAMPLES} live samples, a new reading more than {MAX_TICK_DEVIATION} ticks
///     from their median is REFUSED (`SampleRefused`), so a manipulated price cannot be written into an established
///     history. A genuine move that large pauses conversions until the old samples age out ({MAX_SAMPLE_AGE}), after
///     which the ring accepts the new level and rebuilds -- self-healing, no admin action.
///   * RESIDUAL RISK, STATED. While a pool has fewer than {MIN_SAMPLES} live samples (first use, or after a pause),
///     readings are accepted unfiltered, so an attacker who holds a pushed price at each of {MIN_SAMPLES} spaced
///     moments could seed a biased median. That costs them the round-trip swap fees on a pushed pool several times
///     over at least {MIN_SAMPLE_SPAN}, and what it buys is bounded twice: the conversion still EXECUTES at the real
///     pool price (the floor only decides whether to swap), and one call converts at most {maxInPerCall}.
///   * A KEEPER IS OPTIONAL. Pokes only make conversions possible sooner; `convert` samples on its own, and a pool
///     with no history simply skips until it has one.
///
/// @dev NOT FEE-ON-TRANSFER SAFE BY DESIGN: a V3 pool checks it received `amountIn`, and a V4 settle of an FoT quote
/// leaves the delta unpaid, so such a swap reverts and the call skips; the quote stays here. There is no sweep of foreign
/// tokens (nothing to steal, nothing to strand beyond that FoT case, which the admin can re-route to a token the pool
/// accepts).
contract RealmAnyPairsPlatformFeeConverter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    uint256 internal constant BPS = 10_000;
    /// @notice TWAP window per hop (V3), and the window V4 samples must cover.
    uint32 public constant TWAP_SECONDS = 1800;
    /// @notice Price-impact + drift tolerance below the fee-adjusted TWAP output.
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    /// @notice Most of a conversion's ETH a caller can be reimbursed.
    uint256 public constant MAX_REIMBURSE_BPS = 200;
    /// @notice Gas not visible to the in-frame meter: 21,000 intrinsic, calldata, the frame around `convert`, and the two
    /// ETH sends after the measurement (a cold new-account treasury send is the worst of it).
    uint256 public constant GAS_OVERHEAD = 60_000;
    /// @notice Gas assumed for the pre-swap dust check only (a 2-hop stock route measured well inside it).
    uint256 public constant CONVERT_GAS_ESTIMATE = 450_000;
    /// @notice Hard ceilings on the admin-settable reimbursement knobs, so a compromised admin cannot drain via the tip.
    uint256 public constant HARD_MAX_GAS_PRICE = 100 gwei;
    uint256 public constant HARD_MAX_TIP = 0.001 ether;

    /// @notice Most hops a V4 route may have.
    uint256 public constant MAX_V4_HOPS = 3;
    /// @notice Ring size per V4 pool.
    uint8 public constant MAX_SAMPLES = 8;
    /// @notice Live samples a V4 pool needs before it prices anything.
    uint8 public constant MIN_SAMPLES = 4;
    /// @notice Least time between two samples of one pool: {MIN_SAMPLES} of them cannot land inside {TWAP_SECONDS}.
    uint32 public constant MIN_SAMPLE_SPACING = TWAP_SECONDS / MIN_SAMPLES;
    /// @notice Least time the live samples must span, oldest to newest.
    uint32 public constant MIN_SAMPLE_SPAN = TWAP_SECONDS - MIN_SAMPLE_SPACING;
    /// @notice A sample older than this no longer counts.
    uint32 public constant MAX_SAMPLE_AGE = 2 * TWAP_SECONDS;
    /// @notice Band around the live median, in ticks (~3%): a new sample outside it is refused, and a spot price outside
    /// it skips the conversion.
    int24 public constant MAX_TICK_DEVIATION = 300;

    uint8 public constant SKIP_NO_ROUTE = 1;
    uint8 public constant SKIP_NOTHING = 2;
    uint8 public constant SKIP_NO_TWAP = 3;
    uint8 public constant SKIP_DUST = 4;
    uint8 public constant SKIP_SWAP_FAILED = 5;
    /// @notice V4 only: spot has left the band around the samples' median, so the price is moving or being pushed now.
    uint8 public constant SKIP_PRICE_MOVING = 6;

    address public immutable weth;
    address public immutable router;
    address public immutable v3Factory;
    address public immutable hook;
    /// @notice The V4 singleton. Zero disables V4 routes.
    IPoolManager public immutable poolManager;

    struct Sample {
        uint32 time;
        int24 tick;
    }

    address public admin;
    address public treasury;
    uint256 public maxGasPrice;
    uint256 public tip;
    mapping(address => bytes) public routeOf;
    mapping(address => uint256) public maxInPerCall;

    mapping(address => PoolKey[]) internal _v4Route;
    mapping(PoolId => Sample[MAX_SAMPLES]) internal _samples;
    /// @dev Samples written so far, capped at {MAX_SAMPLES}. The ring fills indices 0..MAX_SAMPLES-1 before it wraps, so
    /// the first `count` slots are always the valid ones.
    mapping(PoolId => uint8) internal _sampleCount;
    /// @dev Ring index the next sample is written to.
    mapping(PoolId => uint8) internal _sampleNext;

    uint256 private _lock = 1;
    /// @dev Set only across this contract's own `poolManager.unlock`, so {unlockCallback} runs only on data encoded here.
    bool private transient _v4Swapping;

    event Converted(
        address indexed quote, uint256 amountIn, uint256 ethOut, uint256 reimbursed, address indexed caller
    );
    event ConvertSkipped(address indexed quote, uint8 reason);
    event TreasurySendFailed(address indexed treasury, uint256 amount);
    event CallerPayFailed(address indexed caller, uint256 amount);
    event RouteSet(address indexed quote, bytes path, uint256 maxInPerCall);
    event V4RouteSet(address indexed quote, PoolKey[] hops, uint256 maxInPerCall);
    event SampleRecorded(PoolId indexed poolId, int24 tick, uint32 time);
    event SampleRefused(PoolId indexed poolId, int24 tick, int24 medianTick);
    event TreasurySet(address indexed treasury);
    event AdminSet(address indexed admin);
    event GasParamsSet(uint256 maxGasPrice, uint256 tip);

    error NotAdmin();
    error ZeroAddress();
    error BadRoute();
    error BadGasParams();
    error Reentrancy();
    error FloorBreached(uint256 got, uint256 floorOut);
    error V4Disabled();
    error NotPoolManager();
    error UnexpectedUnlock();
    error PartialFill();

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert NotAdmin();
        }
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) {
            revert Reentrancy();
        }
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address weth_,
        address router_,
        address v3Factory_,
        address hook_,
        address admin_,
        address treasury_,
        uint256 maxGasPrice_,
        uint256 tip_,
        address poolManager_
    ) {
        if (
            weth_ == address(0) || router_ == address(0) || v3Factory_ == address(0) || admin_ == address(0)
                || treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (maxGasPrice_ > HARD_MAX_GAS_PRICE || tip_ > HARD_MAX_TIP) {
            revert BadGasParams();
        }
        weth = weth_;
        router = router_;
        v3Factory = v3Factory_;
        hook = hook_; // may be zero: then nothing is pulled from a hook ledger
        admin = admin_;
        treasury = treasury_;
        maxGasPrice = maxGasPrice_;
        tip = tip_;
        poolManager = IPoolManager(poolManager_); // may be zero: then V4 routes are refused
    }

    /// @notice ETH arrives from WETH (unwrap), from the PoolManager (a V4 route ending in native ETH) and from the hook
    /// (`pushOwed` native). Anything else is a donation to the treasury, forwarded by the next `convert(address(0))`.
    receive() external payable {}

    // ───────────────────────────── admin ─────────────────────────────

    function setAdmin(address a) external onlyAdmin {
        if (a == address(0)) {
            revert ZeroAddress();
        }
        admin = a;
        emit AdminSet(a);
    }

    function setTreasury(address t) external onlyAdmin {
        if (t == address(0)) {
            revert ZeroAddress();
        }
        treasury = t;
        emit TreasurySet(t);
    }

    function setGasParams(uint256 maxGasPrice_, uint256 tip_) external onlyAdmin {
        if (maxGasPrice_ > HARD_MAX_GAS_PRICE || tip_ > HARD_MAX_TIP) {
            revert BadGasParams();
        }
        maxGasPrice = maxGasPrice_;
        tip = tip_;
        emit GasParamsSet(maxGasPrice_, tip_);
    }

    /// @notice V3 path `quote (fee WETH)` or `quote fee mid fee WETH`, ... ending in WETH. Every hop's pool must exist on
    /// {v3Factory}. `maxIn` bounds the input per call (price impact); zero is refused. An empty path removes the route.
    /// Setting a V3 route clears any V4 route for the same quote.
    function setRoute(address quote, bytes calldata path, uint256 maxIn) external onlyAdmin {
        if (path.length == 0) {
            delete routeOf[quote];
            if (_v4Route[quote].length == 0) {
                delete maxInPerCall[quote];
            }
            emit RouteSet(quote, path, 0);
            return;
        }
        if (quote == address(0) || quote == weth || maxIn == 0) {
            revert BadRoute();
        }
        if (path.length < 43 || (path.length - 20) % 23 != 0) {
            revert BadRoute();
        }
        if (_addrAt(path, 0) != quote || _addrAt(path, path.length - 20) != weth) {
            revert BadRoute();
        }
        uint256 hops = (path.length - 20) / 23;
        for (uint256 i; i < hops; ++i) {
            uint256 o = 23 * i;
            address p = ILpfcV3Factory(v3Factory).getPool(_addrAt(path, o), _addrAt(path, o + 23), _feeAt(path, o + 20));
            if (p == address(0)) {
                revert BadRoute();
            }
        }
        routeOf[quote] = path;
        maxInPerCall[quote] = maxIn;
        if (_v4Route[quote].length != 0) {
            delete _v4Route[quote];
            emit V4RouteSet(quote, new PoolKey[](0), 0);
        }
        emit RouteSet(quote, path, maxIn);
    }

    /// @notice V4 route: 1-{MAX_V4_HOPS} pools, the first containing `quote`, each next one containing the
    /// previous hop's output, the last ending in WETH or native ETH. Every pool must be initialized on {poolManager}, and
    /// none may carry {hook} (converting through a Realm AnyPairs pool would tax the platform's own fee and re-enter the hook that
    /// pays this contract). `maxIn` bounds the input per call; zero is refused. Empty `hops` removes the route. Setting a V4
    /// route clears any V3 route for the same quote.
    /// @dev A new route starts with whatever samples its pools already have (samples are per pool, not per route), so
    /// re-adding a pool resumes its history rather than restarting it.
    function setV4Route(address quote, PoolKey[] calldata hops, uint256 maxIn) external onlyAdmin {
        if (hops.length == 0) {
            delete _v4Route[quote];
            if (routeOf[quote].length == 0) {
                delete maxInPerCall[quote];
            }
            emit V4RouteSet(quote, hops, 0);
            return;
        }
        if (address(poolManager) == address(0)) {
            revert V4Disabled();
        }
        if (quote == address(0) || quote == weth || maxIn == 0) {
            revert BadRoute();
        }
        // The first hop's input is passed to PoolManager.swap as a negative int256 and settled as an int128 delta.
        if (maxIn > uint256(uint128(type(int128).max))) {
            revert BadRoute();
        }
        if (hops.length > MAX_V4_HOPS) {
            revert BadRoute();
        }

        delete _v4Route[quote];
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < hops.length; ++i) {
            PoolKey calldata k = hops[i];
            if (hook != address(0) && address(k.hooks) == hook) {
                revert BadRoute();
            }
            bool in0 = k.currency0 == cur;
            if (!in0 && !(k.currency1 == cur)) {
                revert BadRoute();
            }
            (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
            if (sqrtP == 0) {
                revert BadRoute();
            }
            cur = in0 ? k.currency1 : k.currency0;
            _v4Route[quote].push(k);
        }
        address out = Currency.unwrap(cur);
        if (out != weth && out != address(0)) {
            revert BadRoute();
        }

        maxInPerCall[quote] = maxIn;
        if (routeOf[quote].length != 0) {
            delete routeOf[quote];
            emit RouteSet(quote, "", 0);
        }
        emit V4RouteSet(quote, hops, maxIn);
    }

    // ───────────────────────────── V4 price samples ─────────────────────────────

    /// @notice Record a price sample for every pool on `quote`'s V4 route where spacing allows. PERMISSIONLESS
    /// and unreimbursed. Returns how many samples were written (0 is not an error).
    function poke(address quote) external nonReentrant returns (uint256 recorded) {
        recorded = _pokeRoute(quote);
    }

    /// @notice The V4 route for `quote` (empty if it has none).
    function v4RouteOf(address quote) external view returns (PoolKey[] memory) {
        return _v4Route[quote];
    }

    /// @notice Raw ring for `poolId`: the samples, how many of the slots are valid, and the next write index.
    function samplesOf(PoolId poolId)
        external
        view
        returns (Sample[MAX_SAMPLES] memory samples, uint8 count, uint8 next)
    {
        return (_samples[poolId], _sampleCount[poolId], _sampleNext[poolId]);
    }

    /// @notice Whether `poolId` can price a conversion right now, and why not. `live` samples younger than
    /// {MAX_SAMPLE_AGE}, spanning `span` seconds, with `medianTick` their median (0 when there are none).
    function sampleStatus(PoolId poolId)
        external
        view
        returns (uint256 live, uint32 span, int24 medianTick, bool ready)
    {
        (int24[] memory ticks, uint256 n, uint32 oldest, uint32 newest) = _live(poolId);
        live = n;
        if (n == 0) {
            return (0, 0, 0, false);
        }
        span = newest - oldest;
        medianTick = _medianOf(ticks, n);
        ready = n >= MIN_SAMPLES && span >= MIN_SAMPLE_SPAN;
    }

    // ───────────────────────────── conversion ─────────────────────────────

    /// @notice The floor `convert` would use for `amountIn` of `quote` right now (0 = would skip: no route, no history,
    /// no liquidity, price moving, overflow). Does not record a sample.
    function quoteFloor(address quote, uint256 amountIn) external view returns (uint256) {
        if (_v4Route[quote].length != 0) {
            (uint256 f, uint8 reason) = _v4Floor(quote, amountIn);
            return reason == 0 ? f : 0;
        }
        bytes memory path = routeOf[quote];
        if (path.length == 0) {
            return 0;
        }
        return _twapFloor(path, amountIn);
    }

    /// @notice Convert this contract's `quote` (or, for `address(0)`, forward its ETH) to the treasury, reimbursing the
    /// caller's gas out of the output. Returns the ETH produced (0 when skipped). Never reverts for a skip.
    function convert(address quote) external nonReentrant returns (uint256 ethOut) {
        uint256 g0 = gasleft();
        _pullOwed(quote);
        uint256 amountIn;
        uint256 txGp = _txGasPrice();
        uint256 gp = txGp < maxGasPrice ? txGp : maxGasPrice;

        if (quote == address(0)) {
            ethOut = address(this).balance;
            if (ethOut == 0) {
                return _skip(quote, SKIP_NOTHING);
            }
            if (!_covers(ethOut, gp)) {
                return _skip(quote, SKIP_DUST);
            }
        } else {
            bool isV4 = _v4Route[quote].length != 0;
            // Sampled BEFORE any skip: a skip returns normally, so the reading persists and history builds even while
            // the pool is still too young to price.
            if (isV4) {
                _pokeRoute(quote);
            }
            if (!isV4 && routeOf[quote].length == 0) {
                return _skip(quote, SKIP_NO_ROUTE);
            }
            uint256 bal = IERC20(quote).balanceOf(address(this));
            if (bal == 0) {
                return _skip(quote, SKIP_NOTHING);
            }
            uint256 cap = maxInPerCall[quote];
            amountIn = bal < cap ? bal : cap;
            uint8 reason;
            (ethOut, reason) = isV4 ? _swapV4(quote, amountIn, gp) : _swapV3(quote, amountIn, gp);
            if (reason != 0) {
                return _skip(quote, reason);
            }
        }

        // Reimbursement: everything above is metered; GAS_OVERHEAD covers what the frame cannot see.
        uint256 reimb = (g0 - gasleft() + GAS_OVERHEAD) * gp + tip;
        uint256 maxReimb = ethOut * MAX_REIMBURSE_BPS / BPS;
        if (reimb > maxReimb) {
            reimb = maxReimb;
        }
        uint256 toTreasury = ethOut - reimb;
        emit Converted(quote, amountIn, ethOut, reimb, msg.sender);

        // Sends LAST. A failure keeps the ETH here (never reverts the conversion); the next convert(address(0)) forwards
        // it to the treasury.
        address t = treasury;
        (bool okT,) = t.call{value: toTreasury}("");
        if (!okT) {
            emit TreasurySendFailed(t, toTreasury);
        }
        if (reimb != 0) {
            (bool okC,) = msg.sender.call{value: reimb}("");
            if (!okC) {
                emit CallerPayFailed(msg.sender, reimb);
            }
        }
    }

    /// @notice PoolManager callback for a V4 conversion. Swaps every hop exact-in, requires each hop to fill completely,
    /// enforces the floor on the final output, then pays the input and takes the output.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) {
            revert NotPoolManager();
        }
        if (!_v4Swapping) {
            revert UnexpectedUnlock();
        }
        (address quote, uint256 amountIn, uint256 floorOut) = abi.decode(data, (address, uint256, uint256));

        PoolKey[] storage r = _v4Route[quote];
        Currency cur = Currency.wrap(quote);
        uint256 amt = amountIn;
        for (uint256 i; i < r.length; ++i) {
            PoolKey memory k = r[i];
            bool zeroForOne = k.currency0 == cur;
            BalanceDelta d = poolManager.swap(
                k,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amt),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
            int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
            // A partial fill (price limit reached, or a hook returning a delta) would leave an intermediate currency
            // unsettled; refuse it and let the caller skip.
            if (inDelta >= 0 || outDelta <= 0 || uint256(uint128(-inDelta)) != amt) {
                revert PartialFill();
            }
            amt = uint256(uint128(outDelta));
            cur = zeroForOne ? k.currency1 : k.currency0;
        }
        if (amt < floorOut) {
            revert FloorBreached(amt, floorOut);
        }

        Currency.wrap(quote).settle(poolManager, address(this), amountIn, false);
        cur.take(poolManager, address(this), amt, false);
        return "";
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev `tx.gasprice`, behind a virtual seam so a test harness can override it. Production reads `tx.gasprice` only.
    function _txGasPrice() internal view virtual returns (uint256) {
        return tx.gasprice;
    }

    function _skip(address quote, uint8 reason) internal returns (uint256) {
        emit ConvertSkipped(quote, reason);
        return 0;
    }

    /// @dev Would the capped reimbursement cover an ESTIMATED conversion's gas? If not, converting now makes the caller
    /// pay (or the fees burn) for dust.
    function _covers(uint256 out, uint256 gp) internal view returns (bool) {
        return out * MAX_REIMBURSE_BPS / BPS >= (CONVERT_GAS_ESTIMATE + GAS_OVERHEAD) * gp + tip;
    }

    /// @dev Pull a ledger credit the hook could not push (native to a contract, denied / reverting ERC20). Best-effort.
    function _pullOwed(address quote) internal {
        address h = hook;
        if (h == address(0)) {
            return;
        }
        try ILpfcFeeHook(h).owed(address(this), quote) returns (uint256 o) {
            if (o != 0) {
                try ILpfcFeeHook(h).pushOwed(address(this), quote) {} catch {}
            }
        } catch {}
    }

    /// @dev The V3 leg. Returns a skip reason instead of emitting it.
    function _swapV3(address quote, uint256 amountIn, uint256 gp) internal returns (uint256 ethOut, uint8 reason) {
        bytes memory path = routeOf[quote];
        uint256 floorOut = _twapFloor(path, amountIn);
        if (floorOut == 0) {
            return (0, SKIP_NO_TWAP);
        }
        if (!_covers(floorOut, gp)) {
            return (0, SKIP_DUST);
        }

        uint256 wBefore = IERC20(weth).balanceOf(address(this));
        IERC20(quote).forceApprove(router, amountIn); // exact, reset below on BOTH outcomes
        try ILpfcSwapRouter02(router)
            .exactInput(
                ILpfcSwapRouter02.ExactInputParams({
                    path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: floorOut
                })
            ) returns (
            uint256
        ) {
            IERC20(quote).forceApprove(router, 0);
        } catch {
            IERC20(quote).forceApprove(router, 0);
            return (0, SKIP_SWAP_FAILED);
        }
        uint256 wAfter = IERC20(weth).balanceOf(address(this));
        ethOut = wAfter > wBefore ? wAfter - wBefore : 0;
        // Measured, not the router's report: the floor must hold on what ARRIVED.
        if (ethOut < floorOut) {
            revert FloorBreached(ethOut, floorOut);
        }
        ILpfcWeth(weth).withdraw(ethOut);
    }

    /// @dev The V4 leg. The swap runs inside this contract's own unlock; any revert in there (partial fill, floor, a hook
    /// refusing, a quote that will not transfer) is caught and becomes a skip, exactly like the V3 router revert.
    function _swapV4(address quote, uint256 amountIn, uint256 gp) internal returns (uint256 ethOut, uint8 reason) {
        uint256 floorOut;
        (floorOut, reason) = _v4Floor(quote, amountIn);
        if (reason != 0) {
            return (0, reason);
        }
        if (!_covers(floorOut, gp)) {
            return (0, SKIP_DUST);
        }

        bool native = _v4OutToken(quote) == address(0);
        uint256 before = native ? address(this).balance : IERC20(weth).balanceOf(address(this));
        _v4Swapping = true;
        try poolManager.unlock(abi.encode(quote, amountIn, floorOut)) {
            _v4Swapping = false;
        } catch {
            _v4Swapping = false;
            return (0, SKIP_SWAP_FAILED);
        }
        uint256 afterBal = native ? address(this).balance : IERC20(weth).balanceOf(address(this));
        ethOut = afterBal > before ? afterBal - before : 0;
        // Measured, not the delta: the floor must hold on what ARRIVED.
        if (ethOut < floorOut) {
            revert FloorBreached(ethOut, floorOut);
        }
        if (!native) {
            ILpfcWeth(weth).withdraw(ethOut);
        }
    }

    /// @dev What the V4 route for `quote` ends in: WETH or address(0) for native ETH (guaranteed by {setV4Route}).
    function _v4OutToken(address quote) internal view returns (address) {
        PoolKey[] storage r = _v4Route[quote];
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < r.length; ++i) {
            cur = r[i].currency0 == cur ? r[i].currency1 : r[i].currency0;
        }
        return Currency.unwrap(cur);
    }

    function _pokeRoute(address quote) internal returns (uint256 recorded) {
        PoolKey[] storage r = _v4Route[quote];
        for (uint256 i; i < r.length; ++i) {
            if (_recordSample(r[i].toId())) {
                ++recorded;
            }
        }
    }

    /// @dev One reading of slot0 into the pool's ring, subject to spacing, liquidity and -- once the pool has
    /// {MIN_SAMPLES} live samples -- the median band. See the contract header for why each rule exists.
    function _recordSample(PoolId id) internal returns (bool) {
        uint8 count = _sampleCount[id];
        uint8 next = _sampleNext[id];
        if (count != 0) {
            uint8 last = next == 0 ? MAX_SAMPLES - 1 : next - 1;
            if (block.timestamp < uint256(_samples[id][last].time) + MIN_SAMPLE_SPACING) {
                return false;
            }
        }
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        if (sqrtP == 0 || poolManager.getLiquidity(id) == 0) {
            return false;
        }

        (int24[] memory ticks, uint256 n,,) = _live(id);
        if (n >= MIN_SAMPLES) {
            int24 med = _medianOf(ticks, n);
            if (_absDiff(tick, med) > MAX_TICK_DEVIATION) {
                emit SampleRefused(id, tick, med);
                return false;
            }
        }

        _samples[id][next] = Sample({time: uint32(block.timestamp), tick: tick});
        _sampleNext[id] = next + 1 == MAX_SAMPLES ? 0 : next + 1;
        if (count < MAX_SAMPLES) {
            _sampleCount[id] = count + 1;
        }
        emit SampleRecorded(id, tick, uint32(block.timestamp));
        return true;
    }

    /// @dev The pool's samples younger than {MAX_SAMPLE_AGE}, their ticks sorted ascending in the first `n` slots, and the
    /// oldest and newest sample times among them.
    function _live(PoolId id) internal view returns (int24[] memory ticks, uint256 n, uint32 oldest, uint32 newest) {
        uint8 count = _sampleCount[id];
        ticks = new int24[](count);
        oldest = type(uint32).max;
        for (uint256 i; i < count; ++i) {
            Sample memory s = _samples[id][i];
            if (block.timestamp > uint256(s.time) + MAX_SAMPLE_AGE) {
                continue;
            }
            uint256 j = n;
            while (j != 0 && ticks[j - 1] > s.tick) {
                ticks[j] = ticks[j - 1];
                --j;
            }
            ticks[j] = s.tick;
            ++n;
            if (s.time < oldest) {
                oldest = s.time;
            }
            if (s.time > newest) {
                newest = s.time;
            }
        }
    }

    /// @dev Median of the first `n` (sorted) ticks; the mean of the two middle ones when `n` is even. Requires n > 0.
    function _medianOf(int24[] memory ticks, uint256 n) internal pure returns (int24) {
        uint256 m = n / 2;
        if (n % 2 == 1) {
            return ticks[m];
        }
        return int24((int256(ticks[m - 1]) + int256(ticks[m])) / 2);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (int24) {
        int256 d = int256(a) - int256(b);
        return int24(d < 0 ? -d : d);
    }

    /// @dev The V4 floor for `amountIn` of `quote`: per hop, the live samples' median tick, less the pool's current LP fee;
    /// then less {MAX_SLIPPAGE_BPS}. Returns a skip reason instead of a floor when any hop cannot price.
    function _v4Floor(address quote, uint256 amountIn) internal view returns (uint256 out, uint8 reason) {
        PoolKey[] storage r = _v4Route[quote];
        out = amountIn;
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < r.length; ++i) {
            if (out == 0 || out > type(uint128).max) {
                return (0, SKIP_NO_TWAP);
            }
            PoolKey memory k = r[i];
            PoolId id = k.toId();

            (int24[] memory ticks, uint256 n, uint32 oldest, uint32 newest) = _live(id);
            if (n < MIN_SAMPLES || newest - oldest < MIN_SAMPLE_SPAN) {
                return (0, SKIP_NO_TWAP);
            }
            int24 med = _medianOf(ticks, n);

            (uint160 sqrtP, int24 spot,, uint24 lpFee) = poolManager.getSlot0(id);
            if (sqrtP == 0 || poolManager.getLiquidity(id) == 0) {
                return (0, SKIP_NO_TWAP);
            }
            if (_absDiff(spot, med) > MAX_TICK_DEVIATION) {
                return (0, SKIP_PRICE_MOVING);
            }

            Currency next = k.currency0 == cur ? k.currency1 : k.currency0;
            // V4 ticks price currency1 in currency0 exactly as V3 ticks price token1 in token0, and currencies sort by
            // address with native ETH as address(0), so the V3 helper's ordering rule applies unchanged.
            out = RealmAnyPairsV3TwapOracle.quoteAtTick(med, uint128(out), Currency.unwrap(cur), Currency.unwrap(next));
            out = out * (1_000_000 - lpFee) / 1_000_000;
            cur = next;
        }
        out = out * (BPS - MAX_SLIPPAGE_BPS) / BPS;
        if (out == 0) {
            return (0, SKIP_NO_TWAP);
        }
    }

    function _twapFloor(bytes memory path, uint256 amountIn) internal view returns (uint256 out) {
        out = amountIn;
        uint256 hops = (path.length - 20) / 23;
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_SECONDS;
        for (uint256 i; i < hops; ++i) {
            if (out == 0 || out > type(uint128).max) {
                return 0;
            }
            uint256 o = 23 * i;
            address a = _addrAt(path, o);
            uint24 fee = _feeAt(path, o + 20);
            address b = _addrAt(path, o + 23);
            address pool = ILpfcV3Factory(v3Factory).getPool(a, b, fee);
            if (pool == address(0) || pool.code.length == 0) {
                return 0;
            }
            try ILpfcV3Pool(pool).liquidity() returns (uint128 l) {
                if (l == 0) {
                    return 0;
                }
            } catch {
                return 0;
            }
            int24 tick;
            try ILpfcV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
                if (tc.length != 2) {
                    return 0;
                }
                tick = RealmAnyPairsV3TwapOracle.meanTick(tc[0], tc[1], TWAP_SECONDS);
            } catch {
                return 0; // "OLD": not enough observation history for the window
            }
            out = RealmAnyPairsV3TwapOracle.quoteAtTick(tick, uint128(out), a, b);
            out = out * (1_000_000 - fee) / 1_000_000;
        }
        out = out * (BPS - MAX_SLIPPAGE_BPS) / BPS;
    }

    function _addrAt(bytes memory b, uint256 o) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(b, 32), o)))
        }
    }

    function _feeAt(bytes memory b, uint256 o) internal pure returns (uint24 f) {
        assembly {
            f := shr(232, mload(add(add(b, 32), o)))
        }
    }
}
