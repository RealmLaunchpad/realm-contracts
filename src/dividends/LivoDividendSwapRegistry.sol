// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {ILivoDividendSwapRegistry, SwapRejection, Hop} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
// Aliased so the `chain-arc-*` recipe can import-swap it: on ARC the "native" leg is 18-dec native USDC
// and the V2 quote token is its 6-dec ERC-20 alias, so the depth check needs a scale factor.
import {UniswapV2Venue as UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
// The pool-key types come from the ROOT v4-core checkout, which is a different compilation unit from
// the one v4-periphery pins for `PathKey` above — so `Currency` and `IHooks` exist twice and are not
// interchangeable. Aliased rather than deduplicated: the swap path must keep speaking the router's
// dialect, and the validation path must keep speaking the pool manager's.
import {Currency as CoreCurrency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks as ICoreHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

/// @title LivoDividendSwapRegistry
/// @notice Performs the native -> asset conversion behind every dividend payout, through the route the
///         paying token's creator chose at creation.
///
/// @dev NO WHITELIST, NO REVIEW. Livo does not vet payout assets. A creator names the pools, this
///      contract checks they exist and hold liquidity, and the token converts through them forever
///      after. The one admin lever left is the blacklist, for an asset that turns out to be hostile
///      after the fact — it can only ever REFUSE, never admit.
///
/// @dev ROUTES ARE PER (TOKEN, ASSET) AND WRITE-ONCE. Two tokens naming the same asset each carry their
///      own route, so one creator's bad choice cannot reach another creator's holders, and nobody can
///      grief a popular asset by registering a rotten route for it globally.
///
/// @dev CUSTODIES NOTHING. `swapNativeToAsset` receives, swaps and forwards inside one call, and holds
///      no balance between calls. There is deliberately no `receive()`, so the only native that can
///      reach it is native someone is actively converting. The one exception is ARC, where the venue
///      floors the 18-dec native amount to 6-dec USDC and leaves sub-1e-6 dust behind; it is unreachable
///      rather than owed to anyone, and a sweep for it would buy less than it costs to review.
contract LivoDividendSwapRegistry is ILivoDividendSwapRegistry, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Router every V2 conversion goes through, and the source of the canonical quote token.
    address public constant SWAP_ROUTER = DeploymentAddresses.UNIV2_ROUTER;

    /// @notice Factory the quote/asset pair is resolved through.
    address public constant UNIV2_FACTORY = DeploymentAddresses.UNIV2_FACTORY;

    /// @notice Router a V4 or V3 route is executed on. One router, two commands.
    /// @dev ETH-family chains only: the route pays the router in the native coin. On a chain whose
    ///      native currency is an ERC20 (ARC) no route can convert, so none is ever registered there and
    ///      every asset goes through the V2 path.
    address public constant UNIV4_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice The V4 singleton, read (never written) to prove a route's pools are real.
    /// @dev `StateLibrary` reaches into it with `extsload`, so this needs no separate StateView
    ///      deployment and no interface beyond the one v4-core already ships.
    address public constant UNIV4_POOL_MANAGER = DeploymentAddresses.UNIV4_POOL_MANAGER;

    /// @notice Longest V4 route accepted.
    /// @dev Bounds the loop the swap path walks. Two hops already covers the case this exists for
    ///      (native -> USDG -> xStock); the headroom is for an intermediate that needs one more.
    uint256 public constant MAX_ROUTE_HOPS = 4;

    /// @notice Longest V3 route accepted, in hops.
    /// @dev TWO, not four. Every extra hop is another pool that can be drained and another price that
    ///      can be wrong, and the second hop is only worth having because its FIRST leg is a pool that
    ///      cannot realistically degrade — the intermediate allowlist is what makes that true.
    uint256 public constant MAX_V3_ROUTE_HOPS = 2;

    /// @dev Byte widths of Uniswap V3's path encoding: `token | fee | token | fee | token…`.
    uint256 private constant V3_ADDR_BYTES = 20;
    uint256 private constant V3_FEE_BYTES = 3;

    /// @notice Flat amount of native each conversion pays the keeper wallet as gas money, clipped by
    ///         `MAX_KEEPER_CUT_BPS`. Paid only while `keeper` is set.
    /// @dev Per-chain and compile-time, like every other number in `DeploymentAddresses`: repricing it is
    ///      a proxy upgrade, which is the right cadence for a value that tracks gas regimes rather than
    ///      the market. See that library for how it is sized.
    uint256 public constant KEEPER_FEE = DeploymentAddresses.KEEPER_FEE;

    /// @notice Ceiling on what one conversion can pay the keeper, as bps of the native sent in.
    /// @dev NOT the fee — the fee is flat (`KEEPER_FEE`) and this only clips it. Gas is an absolute cost,
    ///      so a percentage would under-fund the keeper on a small conversion and overcharge holders on a
    ///      large one; a flat fee is what actually tracks the expense. It still needs a relative ceiling
    ///      for the one case where "flat" breaks down: a conversion smaller than the fee itself, which
    ///      the staleness bypass can produce. Without the clip that swap would be handed nothing and
    ///      revert; with it the keeper simply eats the difference on a conversion it chose to trigger.
    uint16 public constant MAX_KEEPER_CUT_BPS = 2_000;

    uint256 private constant BPS_TOTAL = 10_000;

    //////////////////////// storage //////////////////////

    /// @notice Addresses allowed to manage entries (thresholds, the blacklist, the quote allowlist).
    ///         The owner manages THIS set and the upgrade; admins manage everything else.
    /// @dev Two tiers because the entry-level operations are frequent and operational (blacklisting an
    ///      asset that just turned hostile) while the owner is a cold multisig that should not be in
    ///      that loop.
    mapping(address => bool) public isAdmin;

    /// @notice Quote tokens a conversion may start from, and the currencies a multi-hop V3 path may
    ///         route THROUGH. Always enforced.
    /// @dev Today this holds exactly one entry — the router's WETH — because every Livo token's
    ///      earnings are denominated in the chain's native currency. It is a mapping rather than a
    ///      constant so a future non-ETH-quoted token needs a transaction here, not a new token
    ///      implementation.
    mapping(address => bool) public isAllowedQuoteToken;

    /// @notice Per-quote-token depth override, in native 18-dec units. 0 means "use `defaultThreshold`".
    mapping(address => uint256) public quoteTokenThreshold;

    /// @notice Assets no token may convert into, whatever route it registered. The only veto left.
    /// @dev Applies retroactively: a token that registered a route for an asset blacklisted later stops
    ///      converting it, and its buffer reaches the treasury through the staleness sweep. That is the
    ///      intended severity — the blacklist exists for an asset that is actively hurting holders.
    mapping(address => bool) public isBlacklisted;

    /// @notice Quote-side depth an asset's V2 pair must hold, in native 18-dec units, when its quote
    ///         token has no override. Applies to the empty (V2) route only — a route names its pools,
    ///         and those are measured for existence and liquidity instead.
    uint256 public defaultThreshold;

    /// @notice The route each token converts each of its payout assets through, keyed
    ///         `token => asset => route`, in the `DividendRouteLib` wire format.
    /// @dev Empty is a REAL ANSWER, not a missing one: it selects the permissionless V2 pair. Which is
    ///      why `registerRoute` is write-once by (token, asset) rather than by emptiness.
    mapping(address => mapping(address => bytes)) internal _routes;

    /// @notice Whether `token` has already registered a route for `asset`. Separate from `_routes`
    ///         because the empty route is a legitimate registration.
    mapping(address => mapping(address => bool)) public routeRegistered;

    /// @notice Hot wallet that pays the gas for the out-of-band conversions, funded by `KEEPER_FEE` out
    ///          of every conversion it triggers. `address(0)` — the default — disables the fee entirely,
    ///          so a registry that has not been configured yet converts exactly as it did before.
    /// @dev NOT the keeper allowlist — that is `LivoKeepersRegistry`, a different contract with a
    ///      different question. This is only where the gas money goes, and it is deliberately a single
    ///      address: splitting a cut across several would need a schedule nobody has asked for.
    address public keeper;

    /// @dev Reserved for future storage. Appending past this on an upgrade is safe; reordering anything
    ///      above it is not.
    uint256[41] private __gap;

    //////////////////////// events //////////////////////

    event AdminSet(address indexed account, bool allowed);
    event QuoteTokenAllowed(address indexed quote, bool allowed);
    event QuoteTokenThresholdSet(address indexed quote, uint256 threshold);
    event DefaultThresholdSet(uint256 threshold);
    event BlacklistSet(address indexed asset, bool blacklisted);
    /// @notice A token registered the route it will convert `asset` through. Emitted once per (token,
    ///         asset), at the token's creation. Replaying these is how an indexer learns which pools a
    ///         token's dividends actually cross — there is no other mechanism, and no hardcoded list
    ///         should stand in for it.
    event DividendRouteRegistered(address indexed token, address indexed asset, bytes route);
    event DividendAssetPurchased(address indexed asset, address indexed recipient, uint256 nativeIn, uint256 assetOut);
    /// @notice The wallet the per-conversion `KEEPER_FEE` is paid to changed. `address(0)` turns the fee
    ///          off. Named for the funding, not for the keeper set — the allowlist lives in
    ///          `LivoKeepersRegistry` and emits its own `KeeperSet`.
    event KeeperFundingSet(address indexed keeper);
    /// @notice A conversion paid the keeper its fee. Reported per conversion because the clip makes it
    ///          less than `KEEPER_FEE` on a small one. `DividendAssetPurchased.nativeIn` for the same
    ///          conversion is the FULL amount the token sent, this included, not the amount swapped.
    event KeeperFunded(address indexed keeper, uint256 amount);

    //////////////////////// errors //////////////////////

    error NotAdmin();
    error ZeroThreshold();
    error SwapNotSupported(SwapRejection rejection);
    error RouteRejected(SwapRejection rejection);
    /// @notice A token tried to register a second route for the same asset. Creation runs once, so this
    ///         can only be a token implementation calling twice — or a rewrite attempt, which would be a
    ///         rug lever the creator is not meant to have.
    error RouteAlreadyRegistered();
    error NothingToSwap();
    /// @notice The venue call reverted: a drained pool, a missed floor, a token that refuses the swap.
    ///         Reported as a revert because the caller (a dividend freeze) must keep its native.
    error SwapFailed();
    error InsufficientOutput();
    /// @notice The keeper wallet refused its cut. Reverting is deliberate: the alternative is a keeper
    ///          that silently stops being funded while conversions keep spending its gas.
    error KeeperFundingFailed();

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), NotAdmin());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: manages admins and upgrades, nothing else
    /// @param initialThreshold quote-side depth, native 18-dec, an asset's V2 pair must hold by default
    function initialize(address initialOwner, uint256 initialThreshold) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        require(initialThreshold != 0, ZeroThreshold());
        defaultThreshold = initialThreshold;
        emit DefaultThresholdSet(initialThreshold);

        // The chain's canonical quote token is the one every token's earnings already arrive in, so it
        // is allowed from the start: a registry that had to be configured before the first token could
        // name an asset would be a deployment-order footgun for no benefit.
        address quote = UniswapV2Venue.pairToken(IUniswapV2Router(SWAP_ROUTER));
        isAllowedQuoteToken[quote] = true;
        emit QuoteTokenAllowed(quote, true);
    }

    //////////////////////// views //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev `pure` because Uniswap's router declares `WETH()` that way; it is a STATICCALL either way.
    function nativeQuoteToken() public pure returns (address) {
        return UniswapV2Venue.pairToken(IUniswapV2Router(SWAP_ROUTER));
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function routeOf(address token, address asset) external view returns (bytes memory) {
        return _routes[token][asset];
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function checkSwapSupported(address token, address asset)
        public
        view
        returns (bool supported, SwapRejection rejection)
    {
        rejection = _validate(asset, _routes[token][asset]);
        supported = rejection == SwapRejection.OK;
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function validateRoute(address asset, bytes calldata route) external view returns (SwapRejection) {
        return _validate(asset, route);
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev Reads the pair's own reserves rather than a `balanceOf`, so a donation that has not been
    ///      `sync`ed cannot inflate the depth a swap will actually cross.
    function pairFor(address quote, address asset) public view returns (address pair, uint256 quoteDepth) {
        pair = IUniswapV2Factory(UNIV2_FACTORY).getPair(quote, asset);
        if (pair == address(0)) return (address(0), 0);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        uint256 reserve = IUniswapV2Pair(pair).token0() == quote ? reserve0 : reserve1;
        // `QUOTE_TO_NATIVE_SCALE` lifts the pool's quote units to native 18-dec, which is what every
        // threshold here is denominated in. 1 on ETH-family chains, 1e12 on ARC.
        quoteDepth = reserve * UniswapV2Venue.QUOTE_TO_NATIVE_SCALE;
    }

    //////////////////////// route registration //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    function registerRoute(address asset, bytes calldata route) external {
        require(!routeRegistered[msg.sender][asset], RouteAlreadyRegistered());

        SwapRejection rejection = _validate(asset, route);
        require(rejection == SwapRejection.OK, RouteRejected(rejection));

        routeRegistered[msg.sender][asset] = true;
        _routes[msg.sender][asset] = route;
        emit DividendRouteRegistered(msg.sender, asset, route);
    }

    /// @dev The one gate, shared by registration and by every conversion. Ordered cheapest-first, and
    ///      the venue branch mirrors `_venueSwap` exactly — an asset judged eligible on one venue and
    ///      then swapped on another would convert through a pool nobody chose.
    function _validate(address asset, bytes memory route) internal view returns (SwapRejection) {
        address quote = nativeQuoteToken();
        if (!isAllowedQuoteToken[quote]) return SwapRejection.QuoteNotAllowed;
        if (isBlacklisted[asset]) return SwapRejection.Blacklisted;

        uint8 venue = DividendRouteLib.venue(route);
        if (venue == DividendRouteLib.VENUE_V4) return _validateV4(asset, DividendRouteLib.toV4Hops(route));
        if (venue == DividendRouteLib.VENUE_V3) return _validateV3(asset, quote, DividendRouteLib.toV3Path(route));
        // Not a tag we know: refuse rather than fall through to V2, which would silently convert through
        // a pool the creator did not pick.
        if (venue != 0) return SwapRejection.MalformedRoute;

        (address pair, uint256 quoteDepth) = pairFor(quote, asset);
        if (pair == address(0)) return SwapRejection.NoPair;

        uint256 threshold = quoteTokenThreshold[quote];
        if (threshold == 0) threshold = defaultThreshold;
        if (quoteDepth < threshold) return SwapRejection.InsufficientLiquidity;

        return SwapRejection.OK;
    }

    /// @dev Walks the V4 route from the native coin and proves every pool it names is real.
    ///      `sqrtPriceX96 != 0` is the typo gate: a fee/tickSpacing/hooks combination nobody ever
    ///      initialized reads as an all-zero slot, and is indistinguishable from the right pool until
    ///      this checks. The liquidity read is the depth gate.
    /// @dev KNOWN LIMIT: `getLiquidity` is IN-RANGE liquidity at the current tick. A pool whose entire
    ///      position sits outside the current price reads zero and is refused here, even though a swap
    ///      could in principle push into range. Accepted — that pool is not one a token should be
    ///      committing its dividends to for life, and the frontend ranks candidates by what they
    ///      actually deliver, so it would not offer one.
    function _validateV4(address asset, Hop[] memory hops) internal view returns (SwapRejection) {
        uint256 n = hops.length;
        if (n == 0 || n > MAX_ROUTE_HOPS) return SwapRejection.MalformedRoute;
        if (hops[n - 1].currency != asset) return SwapRejection.MalformedRoute;

        IPoolManager manager = IPoolManager(UNIV4_POOL_MANAGER);
        // Every V4 route starts at the native coin, because that is what `swapNativeToAssetV4Path`
        // settles. See `UniversalRouterVenue`.
        address from = address(0);
        for (uint256 i; i < n; ++i) {
            address to = hops[i].currency;
            if (to == from) return SwapRejection.MalformedRoute;

            (address currency0, address currency1) = from < to ? (from, to) : (to, from);
            PoolId id = PoolKey({
                    currency0: CoreCurrency.wrap(currency0),
                    currency1: CoreCurrency.wrap(currency1),
                    fee: hops[i].fee,
                    tickSpacing: hops[i].tickSpacing,
                    hooks: ICoreHooks(hops[i].hooks)
                }).toId();

            (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
            if (sqrtPriceX96 == 0) return SwapRejection.DeadPool;
            if (manager.getLiquidity(id) == 0) return SwapRejection.DeadPool;

            from = to;
        }
        return SwapRejection.OK;
    }

    /// @dev Checks only what makes a V3 path executable at all: it spans quote -> asset, it is a whole
    ///      number of hops, it is at most `MAX_V3_ROUTE_HOPS`, and any middle token is one the protocol
    ///      routes through. There is no pool-liquidity read here to match the V4 one — a V3 pool address
    ///      is derived from a factory this contract does not hold, and no chain the dividends feature
    ///      ships on has a V3 deployment worth wiring one in for. A V3 route is therefore accepted on
    ///      shape alone; if it names a dead pool the token's conversions for that asset simply fail.
    function _validateV3(address asset, address quote, bytes memory path) internal view returns (SwapRejection) {
        uint256 len = path.length;
        if (
            len < V3_ADDR_BYTES + V3_FEE_BYTES + V3_ADDR_BYTES
                || (len - V3_ADDR_BYTES) % (V3_FEE_BYTES + V3_ADDR_BYTES) != 0
                || (len - V3_ADDR_BYTES) / (V3_FEE_BYTES + V3_ADDR_BYTES) > MAX_V3_ROUTE_HOPS
        ) return SwapRejection.MalformedRoute;

        if (_v3PathToken(path, 0) != quote || _v3PathToken(path, len - V3_ADDR_BYTES) != asset) {
            return SwapRejection.MalformedRoute;
        }

        // Middle tokens only: the ends are already pinned above.
        for (uint256 o = V3_ADDR_BYTES + V3_FEE_BYTES; o + V3_ADDR_BYTES < len; o += V3_FEE_BYTES + V3_ADDR_BYTES) {
            if (!isAllowedQuoteToken[_v3PathToken(path, o)]) return SwapRejection.IntermediateNotAllowed;
        }
        return SwapRejection.OK;
    }

    /// @dev The 20-byte address starting at `offset` in a V3 encoded path.
    function _v3PathToken(bytes memory path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, mload(add(add(path, 0x20), offset)))
        }
    }

    //////////////////////// the swap //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev Re-validates on every conversion rather than trusting the creation-time proof. A pool can be
    ///      drained, and an asset can be blacklisted, long after a token was configured for it; without
    ///      this the blacklist would only ever apply to tokens created after it was set.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        require(msg.value != 0, NothingToSwap());

        bytes memory route = _routes[msg.sender][asset];
        SwapRejection rejection = _validate(asset, route);
        require(rejection == SwapRejection.OK, SwapNotSupported(rejection));

        // The keeper's fee comes off the top, so what follows only ever spends what is left. `minOut` is
        // therefore a floor on the SWAPPED amount, not on `msg.value` — the keeper computes it off-chain
        // and has to quote the net.
        address keeperWallet = keeper;
        uint256 cut;
        if (keeperWallet != address(0)) {
            uint256 maxCut = (MAX_KEEPER_CUT_BPS * msg.value) / BPS_TOTAL;
            cut = KEEPER_FEE < maxCut ? KEEPER_FEE : maxCut;
        }
        uint256 nativeIn = msg.value - cut;

        // Buy to THIS contract, not straight to `recipient`: the amount forwarded has to be a balance
        // delta measured here, because a fee-on-transfer asset delivers less than the router reports.
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        bool swapped = _venueSwap(asset, route, nativeIn, minOut);
        require(swapped, SwapFailed());
        out = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        // The router enforces `minOut` against what IT received; a fee-on-transfer asset can take a cut
        // on the transfer to us afterwards, so the floor is re-checked against what actually landed.
        // Zero is refused even when `minOut` is 0: the caller reads "0 out" as "the conversion never
        // happened" and keeps its native buffer, so a swap that DID spend the native and delivered
        // nothing would strand that buffer forever. Reverting leaves the caller the state it assumes.
        require(out != 0 && out >= minOut, InsufficientOutput());

        IERC20(asset).safeTransfer(recipient, out);
        emit DividendAssetPurchased(asset, recipient, msg.value, out);

        // Paid LAST, and only on a conversion that worked: a reverted swap keeps the caller's native
        // whole, so the keeper must not have been paid out of it on the way. Still custodies nothing —
        // the cut only rests here for the length of this call.
        if (cut != 0) {
            (bool sent,) = keeperWallet.call{value: cut}("");
            require(sent, KeeperFundingFailed());
            emit KeeperFunded(keeperWallet, cut);
        }
    }

    /// @dev Spends `nativeIn` on the venue `route` names. Mirrors `_validate`'s branch order exactly.
    /// @return ok false if the venue reverted; the caller turns that into `SwapFailed` and keeps the
    ///         native it was sent.
    function _venueSwap(address asset, bytes memory route, uint256 nativeIn, uint256 minOut) private returns (bool ok) {
        uint8 venue = DividendRouteLib.venue(route);

        if (venue == DividendRouteLib.VENUE_V4) {
            Hop[] memory hops = DividendRouteLib.toV4Hops(route);
            PathKey[] memory path = new PathKey[](hops.length);
            for (uint256 i; i < hops.length; ++i) {
                path[i] = PathKey({
                    intermediateCurrency: Currency.wrap(hops[i].currency),
                    fee: hops[i].fee,
                    tickSpacing: hops[i].tickSpacing,
                    hooks: IHooks(hops[i].hooks),
                    // Never populated: a route is configuration, not a channel for handing arbitrary
                    // calldata to somebody else's hook.
                    hookData: ""
                });
            }
            return UniversalRouterVenue.swapNativeToAssetV4Path(UNIV4_UNIVERSAL_ROUTER, path, nativeIn, minOut);
        }

        address quote = nativeQuoteToken();
        if (venue == DividendRouteLib.VENUE_V3) {
            return UniversalRouterVenue.swapNativeToAssetV3Path(
                UNIV4_UNIVERSAL_ROUTER, quote, DividendRouteLib.toV3Path(route), nativeIn, minOut
            );
        }

        address[] memory v2Path = new address[](2);
        v2Path[0] = quote;
        v2Path[1] = asset;
        // Through the venue lib, not the router directly: the `chain-arc-*` recipe import-swaps it,
        // and ARC has no WETH — its native USDC shares a balance with the 6-dec ERC-20 the pair is
        // quoted in, so the same `msg.value` becomes a two-ERC20 swap there rather than an ETH-in one.
        return UniswapV2Venue.trySwapNativeToAsset(IUniswapV2Router(SWAP_ROUTER), quote, v2Path, nativeIn, minOut);
    }

    //////////////////////// admin //////////////////////

    /// @notice Owner-only: manage the admin set.
    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Allow or disallow a currency as a conversion's starting point and as a V3 intermediate.
    function setAllowedQuoteToken(address quote, bool allowed) external onlyAdmin {
        isAllowedQuoteToken[quote] = allowed;
        emit QuoteTokenAllowed(quote, allowed);
    }

    /// @notice Override the V2 depth threshold for one quote token. 0 restores `defaultThreshold`.
    function setQuoteTokenThreshold(address quote, uint256 threshold) external onlyAdmin {
        quoteTokenThreshold[quote] = threshold;
        emit QuoteTokenThresholdSet(quote, threshold);
    }

    /// @notice The V2 depth threshold used when a quote token has no override.
    function setDefaultThreshold(uint256 threshold) external onlyAdmin {
        require(threshold != 0, ZeroThreshold());
        defaultThreshold = threshold;
        emit DefaultThresholdSet(threshold);
    }

    /// @notice THE ONLY VETO. Stops every token — existing and future — from converting into `asset`.
    /// @dev Deliberately blunt and deliberately retroactive. It is the answer to an asset that turns
    ///      out to be hostile after tokens have already committed to it, which is the failure mode of
    ///      not reviewing assets up front. It cannot admit anything: a blacklisted asset's tokens stop
    ///      converting, their buffers go stale, and the staleness sweep sends those to the treasury.
    function setBlacklisted(address asset, bool blacklisted) external onlyAdmin {
        isBlacklisted[asset] = blacklisted;
        emit BlacklistSet(asset, blacklisted);
    }

    /// @notice The wallet each conversion's `KEEPER_FEE` funds. `address(0)` turns the fee off.
    /// @dev The wallet is storage while the fee is a constant, and the split is on purpose: a hot key
    ///      rotates on operational timescales, a gas-regime reprice does not.
    function setKeeperFunding(address newKeeper) external onlyAdmin {
        keeper = newKeeper;
        emit KeeperFundingSet(newKeeper);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
