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
///   * `convert(quote)` is PERMISSIONLESS. It swaps up to {maxInPerCall} of the held quote PER BLOCK along the admin-set route
///     to WETH or native ETH, unwraps if needed, and sends the ETH to {treasury}. A quote has EITHER a V3 route
///     ({setRoute}) or a V4 route ({setV4Route}); setting one clears the other.
///   * PRICE FLOOR, V3. `amountOutMinimum` is derived ON-CHAIN from each hop's V3 TWAP over {TWAP_SECONDS}, composed
///     across hops, less each hop's pool fee, less {MAX_SLIPPAGE_BPS}. A same-block spot manipulation does not move a
///     30-minute TWAP, so a sandwich makes the router revert and the call SKIPS (no swap, nothing lost). A hop without
///     enough observation history, with zero in-range liquidity, or with no pool, also SKIPS.
///   * PRICE FLOOR, V4. Priced from each hop's CURRENT pool price on the admin's trusted route, less that pool's LP
///     fee, composed across hops, less {MAX_SLIPPAGE_BPS}. No price history is kept and no bot records one, so this
///     bounds price impact only: a sandwich inside the band is accepted, and {maxInPerCall} bounds one block's exposure.
///   * SELF-FUNDING GAS. The caller is reimbursed `(gasUsed + GAS_OVERHEAD) * min(tx.gasprice, maxGasPrice) + tip` out of
///     the conversion's ETH, capped at {MAX_REIMBURSE_BPS} of it. If the floor cannot cover an estimated reimbursement
///     the call SKIPS before swapping (a keeper never pays to convert dust, and dust never burns fees).
///   * NATIVE. A native pool's platform push to this CONTRACT fails the hook's codeless rule and is credited to
///     `owed[converter][address(0)]`. `convert(address(0))` pulls it with the hook's permissionless `pushOwed` and
///     forwards the ETH (same reimbursement rule). The same pull runs for an ERC20 quote whose push fell back to
///     `owed[]` (quote denied in-swap, transfer reverted).
///
/// @dev NOT FEE-ON-TRANSFER SAFE BY DESIGN: a V3 pool checks it received `amountIn`, and a V4 settle of an FoT quote
/// leaves the delta unpaid, so such a swap reverts and the call skips; the quote stays here.
///
/// AUDIT ROUND 12 (Low, fixed). This header used to claim "nothing to strand". That was wrong on two counts: a quote
/// with NO configured route can be pushed here by the hook and has no path out at all, and a V4 conversion that ends
/// in WETH leaves residual WETH behind when unwrapping is partial. Both stranded permanently, because this contract
/// had no sweep of any kind. {rescue} is that sweep -- admin-triggered but paying ONLY to {treasury}, which is where
/// every converted fee already goes, so it adds no authority the admin did not already have through {setRoute}.
contract RealmAnyPairsPlatformFeeConverter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    uint256 internal constant BPS = 10_000;
    /// @notice TWAP window per hop (V3 routes).
    uint32 public constant TWAP_SECONDS = 1800;
    /// @notice Price-impact + drift tolerance below the fee-adjusted TWAP output.
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    /// @notice Most of a conversion's ETH a caller can be reimbursed.
    uint256 public constant MAX_REIMBURSE_BPS = 200;
    /// @notice Gas not visible to the in-frame meter: 21,000 intrinsic, calldata, the frame around `convert`, and the two
    /// ETH sends after the measurement (a cold new-account treasury send is the worst of it).
    /// @dev AUDIT ROUND 13 (informational): 60,000 -> 40,000. This covers what the metered frame cannot see -- the
    /// calldata cost, the intrinsic 21,000, and the two value sends after the final `gasleft()` read. Measured at
    /// ~40k; the extra 20,000 was an unconditional subsidy of `20,000 * gp + tip` on EVERY call, paid out of platform
    /// revenue to whoever called first.
    uint256 public constant GAS_OVERHEAD = 40_000;
    /// @notice Gas assumed for the pre-swap dust check only (a 2-hop stock route measured well inside it).
    uint256 public constant CONVERT_GAS_ESTIMATE = 450_000;
    /// @notice Hard ceilings on the admin-settable reimbursement knobs, so a compromised admin cannot drain via the tip.
    uint256 public constant HARD_MAX_GAS_PRICE = 100 gwei;
    uint256 public constant HARD_MAX_TIP = 0.001 ether;

    /// @notice Most hops a V4 route may have.
    uint256 public constant MAX_V4_HOPS = 3;

    uint8 public constant SKIP_NO_ROUTE = 1;
    uint8 public constant SKIP_NOTHING = 2;
    uint8 public constant SKIP_NO_TWAP = 3;
    uint8 public constant SKIP_DUST = 4;
    uint8 public constant SKIP_SWAP_FAILED = 5;
    /// @notice The admin's out-of-band floor rate for a V4-routed quote: the minimum WETH/ETH out per 1e18 of
    /// `quote`, as a plain 1e18-scaled rate. Zero means NO floor is configured, and a V4 route without one refuses to
    /// convert ({SKIP_NO_FLOOR}).
    ///
    /// @dev AUDIT ROUND 13 (M-1). `_v4Floor` derived its entire floor from `getSlot0` on the very pool `_swapV4` was
    /// about to trade in, one instruction earlier, and then applied {MAX_SLIPPAGE_BPS} to it. That bounds price
    /// impact WITHIN the swap and nothing else: the floor was a function of a number the attacker sets, so rig the
    /// pool, call the permissionless `convert`, un-rig. The V3 twin `_twapFloor` is anchored on an 1800-second
    /// `observe()` TWAP, which made the asymmetry an oversight rather than a decision.
    ///
    /// WHY AN ADMIN RATE AND NOT AN ON-CHAIN ANCHOR. Core V4 pools keep no observations -- `observe()` is a hook
    /// feature, not a pool one -- so there is no V4 equivalent of the V3 TWAP to read. The alternatives are a V3 TWAP
    /// on the same pair (which requires a V3 pool to exist for every routed quote, and often none does) or a stored
    /// last-good price with a drift cap. This codebase has already tried the latter shape three times, for reward
    /// route discovery and for the LP locker's compound anchor, and it was broken every time by the same move: the
    /// founding observation is taken at a moment the attacker chooses, so the anchor can be established at a rigged
    /// value and then walked. See the round-11 note in {RealmAnyPairsDividendTrackerAutoBasket}.
    ///
    /// A rate a human sets out of band is the one anchor an attack transaction genuinely cannot move. It also matches
    /// what this contract already assumes: the admin picks the route, so the admin can price it. Set it conservatively
    /// (it is a FLOOR, not a target) and revisit it when the pair moves materially.
    mapping(address => uint256) public v4FloorRate;

    /// @notice When {v4FloorRate} was last set for a quote (timestamp), purely for OBSERVABILITY -- nothing on
    /// chain reads it. Paired with {v4FloorSetAtBlock} and surfaced together by {v4Floor}.
    ///
    /// @dev AUDIT ROUND 14 (F-3), then a PRODUCT DECISION. The round-14 fix expired a rate after 30 days. The user
    /// overruled that: a silent halt of fee conversion is worse operationally than a stale rate, and a recurring
    /// admin task with a quiet failure mode is not wanted. So THE RATE NEVER EXPIRES.
    ///
    /// THE TRADE, AND IT IS A REAL ONE. Because the spot term is attacker-collapsible, the admin rate is effectively
    /// the whole floor. A rate left far BELOW market is exploitable in proportion to how far the price has moved --
    /// the auditor measured ~450 WETH of a 500 WETH balance taken against a rate a 10x move had outrun. It is
    /// bounded per block by {maxInPerCall} and per conversion by the 2% reimbursement cap, but it is not bounded by
    /// time. A rate left ABOVE market is harmless: the conversion simply skips.
    ///
    /// WHAT REPLACES THE EXPIRY. Two things, both operational rather than enforced:
    ///   * {FloorBound} is emitted on every V4 conversion saying WHICH term bound. A run of `adminBound == true` is
    ///     the signal that the admin number, not the market, is setting the price -- i.e. re-price now.
    ///   * a route change CLEARS the rate ({setRoute} / {setV4Route}), which is the case where staleness is both
    ///     most likely and most dangerous, and the one place the protocol can tell on its own that the old number
    ///     no longer describes anything.
    mapping(address => uint256) public v4FloorSetAt;

    /// @notice The block {v4FloorRate} was last set in. Observability only; see {v4FloorSetAt}.
    mapping(address => uint256) public v4FloorSetAtBlock;


    /// @notice Hard ceiling on {v4FloorRate}, so an absurd rate is refused at the setter rather than reverting
    /// `convert` later.
    /// @dev AUDIT ROUND 15 (F-5): raised 1e30 -> 1e38, and the round-14 comment corrected. That comment said
    /// `amountIn * rate` was UNCHECKED and would overflow-wrap; it is plain checked arithmetic, so the real failure
    /// was a revert, and the real overflow point given `maxInPerCall <= int128.max` is about 6.8e38.
    ///
    /// The old 1e30 was ~8 orders of magnitude tighter than the bound it claimed, and that had a real consequence:
    /// the unit is wei of ETH per 1e18 BASE UNITS, so a 6-decimal quote worth more than ~1 ETH per whole token could
    /// not be given a correct floor AT ALL -- `setV4FloorRate` reverted and the admin's only option was a rate below
    /// market, which is exactly the direction already accepted as exploitable. 1e38 is still ~6.8x under the
    /// overflow point.
    uint256 public constant MAX_FLOOR_RATE = 1e38;

    /// @notice This quote already converted its `maxInPerCall` in this block.
    uint8 public constant SKIP_BLOCK_CAP = 7;
    /// @notice A V4-routed quote has no {v4FloorRate} configured, so there is no manipulation-proof floor to enforce.
    uint8 public constant SKIP_NO_FLOOR = 8;

    address public immutable weth;
    address public immutable router;
    address public immutable v3Factory;
    address public immutable hook;
    /// @notice The V4 singleton. Zero disables V4 routes.
    IPoolManager public immutable poolManager;

    address public admin;
    address public treasury;
    uint256 public maxGasPrice;
    uint256 public tip;
    mapping(address => bytes) public routeOf;
    mapping(address => uint256) public maxInPerCall;
    /// @dev Per-quote, per-block conversion budget: `maxInPerCall` bounds a BLOCK, not a call, so a sandwich cannot loop
    /// `convert` inside one transaction and multiply its take.
    mapping(address => uint256) internal _convertBlock;
    mapping(address => uint256) internal _convertedInBlock;

    mapping(address => PoolKey[]) internal _v4Route;

    uint256 private _lock = 1;
    /// @dev Set only across this contract's own `poolManager.unlock`, so {unlockCallback} runs only on data encoded here.
    bool private transient _v4Swapping;

    event Converted(address indexed quote, uint256 amountIn, uint256 ethOut, uint256 reimbursed, address indexed caller);
    event ConvertSkipped(address indexed quote, uint8 reason);
    event TreasurySendFailed(address indexed treasury, uint256 amount);
    event CallerPayFailed(address indexed caller, uint256 amount);
    event RouteSet(address indexed quote, bytes path, uint256 maxInPerCall);
    event V4RouteSet(address indexed quote, PoolKey[] hops, uint256 maxInPerCall);
    /// @notice The admin's out-of-band floor rate for a V4-routed quote changed. See {v4FloorRate}.
    event V4FloorRateSet(address indexed quote, uint256 rate);
    /// @notice Which term set the floor for one V4 conversion. `adminBound` true = the admin's {v4FloorRate} was
    /// higher than the spot-derived figure and is therefore doing the pricing. Since the rate never expires, a run
    /// of `adminBound == true` is the operational cue to re-price. (Audit round 14 + product decision.)
    event FloorBound(address indexed quote, uint256 floorOut, uint256 adminRate, bool adminBound);
    event TreasurySet(address indexed treasury);
    event AdminSet(address indexed admin);
    event GasParamsSet(uint256 maxGasPrice, uint256 tip);
    /// @notice A stranded balance was swept to the treasury. See {rescue} (audit round 12).
    event Rescued(address indexed token, address indexed to, uint256 amount);

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
    error TransferFailed();
    /// @notice {rescue} refused: this token still has a configured route, so it is convertible rather than stranded.
    /// Clear the route first if it really must be swept. (Audit round 13, L-1.)
    error HasLiveRoute();
    /// @notice {setV4FloorRate} refused: above {MAX_FLOOR_RATE}. (Audit round 14, F-3.)
    error BadFloorRate();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
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
        if (weth_ == address(0) || router_ == address(0) || v3Factory_ == address(0) || admin_ == address(0)
            || treasury_ == address(0)) revert ZeroAddress();
        if (maxGasPrice_ > HARD_MAX_GAS_PRICE || tip_ > HARD_MAX_TIP) revert BadGasParams();
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
        if (a == address(0)) revert ZeroAddress();
        admin = a;
        emit AdminSet(a);
    }

    function setTreasury(address t) external onlyAdmin {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Sweep a STRANDED balance to {treasury}: a quote with no configured route, or residual WETH/ETH.
    /// `token == address(0)` sweeps native ETH.
    ///
    /// @dev AUDIT ROUND 12 (Low, added) and ROUND 13 (L-1, bounded). Two balances could reach this contract and never
    /// leave: a quote the hook pushed for which the admin never configured a route, and WETH left over from a V4
    /// conversion. Neither is reachable by {convert}, which only spends along a configured route.
    ///
    /// ROUND 13 CORRECTED THE JUSTIFICATION AND THE SCOPE. As first written this function was unbounded, and its
    /// comment claimed it "adds no authority the admin did not already have through `setRoute`". That was false on
    /// three counts, and the auditor was right to call it out:
    ///   * route extraction PAYS A POOL, losing most of the value to other LPs; a sweep pays out at par;
    ///   * route extraction is throttled to `maxInPerCall` per block; a sweep was not throttled at all;
    ///   * on V3 route extraction is floored by the TWAP; a sweep had no floor.
    /// The comment also claimed an unlock check that this function never had (the hook's and the locker's rescues
    /// have one; this had only `nonReentrant`). `setTreasury(attacker); rescue(tok, bal); setTreasury(real)` was
    /// therefore an atomic, admin-only drain of any balance at par.
    ///
    /// SO THE SCOPE NOW MATCHES THE JUSTIFICATION: a token with a LIVE ROUTE cannot be rescued at all. If a balance
    /// is convertible, the permissionless {convert} is how it leaves, priced and throttled. Only genuinely stranded
    /// balances -- routeless quotes, residual WETH, stray ETH -- are sweepable, which is exactly the case that
    /// justified adding this. Clearing a route to unlock a sweep is possible but is a separate, visible transaction
    /// that emits {RouteSet} / {V4RouteSet}, rather than an atomic round trip inside one call.
    function rescue(address token, uint256 amount) external onlyAdmin nonReentrant {
        address t = treasury;
        if (t == address(0)) revert ZeroAddress();
        // A convertible balance is not stranded. WETH and native are always sweepable: they are the OUTPUT side, and
        // `convert` never spends them.
        if (token != address(0) && token != weth) {
            if (routeOf[token].length != 0 || _v4Route[token].length != 0) revert HasLiveRoute();
        }
        if (token == address(0)) {
            (bool ok,) = t.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(t, amount);
        }
        emit Rescued(token, t, amount);
    }

    function setGasParams(uint256 maxGasPrice_, uint256 tip_) external onlyAdmin {
        if (maxGasPrice_ > HARD_MAX_GAS_PRICE || tip_ > HARD_MAX_TIP) revert BadGasParams();
        maxGasPrice = maxGasPrice_;
        tip = tip_;
        emit GasParamsSet(maxGasPrice_, tip_);
    }

    /// @notice V3 path `quote (fee WETH)` or `quote fee mid fee WETH`, ... ending in WETH. Every hop's pool must exist on
    /// {v3Factory}. `maxIn` bounds the input per block (price impact); zero is refused. An empty path removes the route.
    /// Setting a V3 route clears any V4 route for the same quote.
    function setRoute(address quote, bytes calldata path, uint256 maxIn) external onlyAdmin {
        // AUDIT ROUND 15 (F-4): clear the floor ABOVE the early returns, so route REMOVAL clears it too. Both
        // setters only cleared it in their non-empty body, so after `setV4Route(Q, [], 0)` the rate and its
        // timestamp persisted and `v4Floor(Q)` reported a live-looking rate, with a growing age, for a quote with no
        // route. Not exploitable -- any new route clears it -- but `FloorBound` / `v4Floor` monitoring is the ENTIRE
        // replacement for the expiry that was removed, so it must not lie.
        if (v4FloorRate[quote] != 0) {
            v4FloorRate[quote] = 0;
            v4FloorSetAt[quote] = 0;
            v4FloorSetAtBlock[quote] = 0;
            emit V4FloorRateSet(quote, 0);
        }
        if (path.length == 0) {
            delete routeOf[quote];
            if (_v4Route[quote].length == 0) delete maxInPerCall[quote];
            emit RouteSet(quote, path, 0);
            return;
        }
        if (quote == address(0) || quote == weth || maxIn == 0) revert BadRoute();
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadRoute();
        if (_addrAt(path, 0) != quote || _addrAt(path, path.length - 20) != weth) revert BadRoute();
        uint256 hops = (path.length - 20) / 23;
        for (uint256 i; i < hops; ++i) {
            uint256 o = 23 * i;
            address p = ILpfcV3Factory(v3Factory).getPool(_addrAt(path, o), _addrAt(path, o + 23), _feeAt(path, o + 20));
            if (p == address(0)) revert BadRoute();
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
    /// pays this contract). `maxIn` bounds the input per block; zero is refused. Empty `hops` removes the route. Setting a V4
    /// route clears any V3 route for the same quote.
    function setV4Route(address quote, PoolKey[] calldata hops, uint256 maxIn) external onlyAdmin {
        // AUDIT ROUND 15 (F-4): clear the floor ABOVE the early returns, so route REMOVAL clears it too. Both
        // setters only cleared it in their non-empty body, so after `setV4Route(Q, [], 0)` the rate and its
        // timestamp persisted and `v4Floor(Q)` reported a live-looking rate, with a growing age, for a quote with no
        // route. Not exploitable -- any new route clears it -- but `FloorBound` / `v4Floor` monitoring is the ENTIRE
        // replacement for the expiry that was removed, so it must not lie.
        if (v4FloorRate[quote] != 0) {
            v4FloorRate[quote] = 0;
            v4FloorSetAt[quote] = 0;
            v4FloorSetAtBlock[quote] = 0;
            emit V4FloorRateSet(quote, 0);
        }
        if (hops.length == 0) {
            delete _v4Route[quote];
            if (routeOf[quote].length == 0) delete maxInPerCall[quote];
            emit V4RouteSet(quote, hops, 0);
            return;
        }
        if (address(poolManager) == address(0)) revert V4Disabled();
        if (quote == address(0) || quote == weth || maxIn == 0) revert BadRoute();
        // The first hop's input is passed to PoolManager.swap as a negative int256 and settled as an int128 delta.
        if (maxIn > uint256(uint128(type(int128).max))) revert BadRoute();
        if (hops.length > MAX_V4_HOPS) revert BadRoute();

        delete _v4Route[quote];
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < hops.length; ++i) {
            PoolKey calldata k = hops[i];
            if (hook != address(0) && address(k.hooks) == hook) revert BadRoute();
            bool in0 = k.currency0 == cur;
            if (!in0 && !(k.currency1 == cur)) revert BadRoute();
            (uint160 sqrtP,,,) = poolManager.getSlot0(k.toId());
            if (sqrtP == 0) revert BadRoute();
            // ROUND 13 (M-1): refuse 0-fee pools. With no LP fee the rig / convert / un-rig round trip costs the
            // attacker nothing but gas, which removes the only cost that made a shallow manipulation unattractive.
            // (Realm's own pools are 0-fee since round 12 and are already refused above by the `hook` check.)
            if (k.fee == 0) revert BadRoute();
            cur = in0 ? k.currency1 : k.currency0;
            _v4Route[quote].push(k);
        }
        address out = Currency.unwrap(cur);
        if (out != weth && out != address(0)) revert BadRoute();

        maxInPerCall[quote] = maxIn;
        if (routeOf[quote].length != 0) {
            delete routeOf[quote];
            emit RouteSet(quote, "", 0);
        }
        emit V4RouteSet(quote, hops, maxIn);
    }

    /// @notice Set the out-of-band floor rate for a V4-routed quote: minimum WETH/ETH out per 1e18 of `quote`.
    /// Zero clears it, which stops that quote converting rather than letting it convert unfloored. See {v4FloorRate}.
    function setV4FloorRate(address quote, uint256 rate) external onlyAdmin {
        if (quote == address(0)) revert ZeroAddress();
        if (rate > MAX_FLOOR_RATE) revert BadFloorRate();
        v4FloorRate[quote] = rate;
        v4FloorSetAt[quote] = rate == 0 ? 0 : block.timestamp;
        v4FloorSetAtBlock[quote] = rate == 0 ? 0 : block.number;
        emit V4FloorRateSet(quote, rate);
    }

    /// @notice The admin floor for `quote` and how old it is, in one read, so a dashboard can show its age without
    /// the protocol needing a rule about it. `rate == 0` means the quote cannot convert ({SKIP_NO_FLOOR}).
    /// @return rate minimum WETH/ETH out per 1e18 of `quote`.
    /// @return setAt the timestamp it was last set (0 if never / cleared).
    /// @return setAtBlock the block it was last set in.
    /// @return ageSeconds how long ago that was, 0 when unset.
    function v4Floor(address quote)
        external
        view
        returns (uint256 rate, uint256 setAt, uint256 setAtBlock, uint256 ageSeconds)
    {
        rate = v4FloorRate[quote];
        setAt = v4FloorSetAt[quote];
        setAtBlock = v4FloorSetAtBlock[quote];
        ageSeconds = setAt == 0 ? 0 : block.timestamp - setAt;
    }

    /// @notice The V4 route for `quote` (empty if it has none).
    function v4RouteOf(address quote) external view returns (PoolKey[] memory) {
        return _v4Route[quote];
    }

    // ───────────────────────────── conversion ─────────────────────────────

    /// @notice The floor `convert` would use for `amountIn` of `quote` right now (0 = would skip: no route, no price,
    /// no liquidity, overflow).
    function quoteFloor(address quote, uint256 amountIn) external view returns (uint256) {
        if (_v4Route[quote].length != 0) {
            (uint256 f, uint8 reason,) = _v4Floor(quote, amountIn);
            return reason == 0 ? f : 0;
        }
        bytes memory path = routeOf[quote];
        if (path.length == 0) return 0;
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
            if (ethOut == 0) return _skip(quote, SKIP_NOTHING);
            if (!_covers(ethOut, gp)) return _skip(quote, SKIP_DUST);
        } else {
            bool isV4 = _v4Route[quote].length != 0;
            if (!isV4 && routeOf[quote].length == 0) return _skip(quote, SKIP_NO_ROUTE);
            uint256 bal = IERC20(quote).balanceOf(address(this));
            if (bal == 0) return _skip(quote, SKIP_NOTHING);
            uint256 cap = maxInPerCall[quote];
            if (_convertBlock[quote] == block.number) {
                uint256 used = _convertedInBlock[quote];
                cap = used >= cap ? 0 : cap - used;
            } else {
                _convertBlock[quote] = block.number;
                _convertedInBlock[quote] = 0;
            }
            if (cap == 0) return _skip(quote, SKIP_BLOCK_CAP);
            amountIn = bal < cap ? bal : cap;
            uint8 reason;
            (ethOut, reason) = isV4 ? _swapV4(quote, amountIn, gp) : _swapV3(quote, amountIn, gp);
            if (reason != 0) return _skip(quote, reason);
            _convertedInBlock[quote] += amountIn;
        }

        // Reimbursement: everything above is metered; GAS_OVERHEAD covers what the frame cannot see.
        uint256 reimb = (g0 - gasleft() + GAS_OVERHEAD) * gp + tip;
        uint256 maxReimb = ethOut * MAX_REIMBURSE_BPS / BPS;
        if (reimb > maxReimb) reimb = maxReimb;
        uint256 toTreasury = ethOut - reimb;
        emit Converted(quote, amountIn, ethOut, reimb, msg.sender);

        // Sends LAST. A failure keeps the ETH here (never reverts the conversion); the next convert(address(0))
        // forwards it to the treasury.
        address t = treasury;
        (bool okT,) = t.call{value: toTreasury}("");
        if (!okT) emit TreasurySendFailed(t, toTreasury);
        // AUDIT ROUND 13 (L-2): the reimbursement is gated on the treasury send SUCCEEDING. The native branch returns
        // before the per-block cap, and a failed treasury send is deliberately non-fatal -- so with a treasury that
        // reverts on receive, anyone could loop `convert(address(0))`, even inside one transaction, collecting the
        // reimbursement every time while the payout bounced straight back into this contract. Paying the caller only
        // when the money actually left removes the loop without making a stuck treasury fatal: the ETH stays here and
        // the next call forwards it, exactly as before.
        if (reimb != 0 && okT) {
            (bool okC,) = msg.sender.call{value: reimb}("");
            if (!okC) emit CallerPayFailed(msg.sender, reimb);
        }
    }

    /// @notice PoolManager callback for a V4 conversion. Swaps every hop exact-in, requires each hop to fill completely,
    /// enforces the floor on the final output, then pays the input and takes the output.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_v4Swapping) revert UnexpectedUnlock();
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
            if (inDelta >= 0 || outDelta <= 0 || uint256(uint128(-inDelta)) != amt) revert PartialFill();
            amt = uint256(uint128(outDelta));
            cur = zeroForOne ? k.currency1 : k.currency0;
        }
        if (amt < floorOut) revert FloorBreached(amt, floorOut);

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
        if (h == address(0)) return;
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
        if (floorOut == 0) return (0, SKIP_NO_TWAP);
        if (!_covers(floorOut, gp)) return (0, SKIP_DUST);

        uint256 wBefore = IERC20(weth).balanceOf(address(this));
        IERC20(quote).forceApprove(router, amountIn); // exact, reset below on BOTH outcomes
        try ILpfcSwapRouter02(router).exactInput(
            ILpfcSwapRouter02.ExactInputParams({
                path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: floorOut
            })
        ) returns (uint256) {
            IERC20(quote).forceApprove(router, 0);
        } catch {
            IERC20(quote).forceApprove(router, 0);
            return (0, SKIP_SWAP_FAILED);
        }
        uint256 wAfter = IERC20(weth).balanceOf(address(this));
        ethOut = wAfter > wBefore ? wAfter - wBefore : 0;
        // Measured, not the router's report: the floor must hold on what ARRIVED.
        if (ethOut < floorOut) revert FloorBreached(ethOut, floorOut);
        ILpfcWeth(weth).withdraw(ethOut);
    }

    /// @dev The V4 leg. The swap runs inside this contract's own unlock; any revert in there (partial fill, floor, a hook
    /// refusing, a quote that will not transfer) is caught and becomes a skip, exactly like the V3 router revert.
    function _swapV4(address quote, uint256 amountIn, uint256 gp) internal returns (uint256 ethOut, uint8 reason) {
        uint256 floorOut;
        bool adminBound;
        (floorOut, reason, adminBound) = _v4Floor(quote, amountIn);
        if (reason != 0) return (0, reason);
        if (!_covers(floorOut, gp)) return (0, SKIP_DUST);
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
        if (ethOut < floorOut) revert FloorBreached(ethOut, floorOut);
        // AUDIT ROUND 15 (informational): emitted HERE, after the swap has actually happened. It was emitted before
        // the unlock, so it also fired on conversions that then skipped -- and since the rate never expires this
        // event is the ENTIRE replacement for the removed expiry, so a monitor built on it must not be counting
        // attempts that never converted.
        emit FloorBound(quote, floorOut, v4FloorRate[quote], adminBound);
        if (!native) ILpfcWeth(weth).withdraw(ethOut);
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

    /// @dev The V4 floor for `amountIn` of `quote`: per hop, the pool's current tick on the trusted route, less its LP fee;
    /// then less {MAX_SLIPPAGE_BPS}. Returns a skip reason instead of a floor when any hop cannot price.
    /// @return out the floor this conversion must clear.
    /// @return reason a non-zero skip code, or 0.
    /// @return adminBound true when the ADMIN RATE is the binding term rather than the spot-derived figure. The
    /// conversion path emits this ({FloorBound}) because, with no expiry on the rate, an operator watching for
    /// "the admin number is doing the work, not the market" is the only signal that a rate has drifted.
    function _v4Floor(address quote, uint256 amountIn)
        internal
        view
        returns (uint256 out, uint8 reason, bool adminBound)
    {
        PoolKey[] storage r = _v4Route[quote];
        out = amountIn;
        Currency cur = Currency.wrap(quote);
        for (uint256 i; i < r.length; ++i) {
            if (out == 0 || out > type(uint128).max) return (0, SKIP_NO_TWAP, false);
            PoolKey memory k = r[i];
            PoolId id = k.toId();

            (uint160 sqrtP, int24 spot,, uint24 lpFee) = poolManager.getSlot0(id);
            if (sqrtP == 0 || poolManager.getLiquidity(id) == 0) return (0, SKIP_NO_TWAP, false);

            Currency next = k.currency0 == cur ? k.currency1 : k.currency0;
            // V4 ticks price currency1 in currency0 exactly as V3 ticks price token1 in token0, and currencies sort by
            // address with native ETH as address(0), so the V3 helper's ordering rule applies unchanged.
            out = RealmAnyPairsV3TwapOracle.quoteAtTick(spot, uint128(out), Currency.unwrap(cur), Currency.unwrap(next));
            out = out * (1_000_000 - lpFee) / 1_000_000;
            cur = next;
        }
        out = out * (BPS - MAX_SLIPPAGE_BPS) / BPS;
        if (out == 0) return (0, SKIP_NO_TWAP, false);

        // ROUND 13 (M-1): everything above is derived from live spot on the pools we are about to trade, so on its
        // own it bounds price impact and NOTHING else. The binding floor is the admin's out-of-band rate; the spot
        // figure only ever makes the floor STRICTER, never weaker.
        uint256 rate = v4FloorRate[quote];
        if (rate == 0) return (0, SKIP_NO_FLOOR, false);
        uint256 anchored = amountIn * rate / 1e18;
        if (anchored == 0) return (0, SKIP_NO_FLOOR, false);
        // Which term BINDS is reported to the caller so the conversion path can announce it -- see {FloorBound}.
        if (anchored > out) {
            out = anchored;
            adminBound = true;
        }
    }

    function _twapFloor(bytes memory path, uint256 amountIn) internal view returns (uint256 out) {
        out = amountIn;
        uint256 hops = (path.length - 20) / 23;
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_SECONDS;
        for (uint256 i; i < hops; ++i) {
            if (out == 0 || out > type(uint128).max) return 0;
            uint256 o = 23 * i;
            address a = _addrAt(path, o);
            uint24 fee = _feeAt(path, o + 20);
            address b = _addrAt(path, o + 23);
            address pool = ILpfcV3Factory(v3Factory).getPool(a, b, fee);
            if (pool == address(0) || pool.code.length == 0) return 0;
            try ILpfcV3Pool(pool).liquidity() returns (uint128 l) {
                if (l == 0) return 0;
            } catch {
                return 0;
            }
            int24 tick;
            try ILpfcV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
                if (tc.length != 2) return 0;
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
