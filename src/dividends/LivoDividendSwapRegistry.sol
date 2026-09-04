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

/// @title LivoDividendSwapRegistry
/// @notice Decides which ERC20s a token may pay dividends in, and performs the native -> asset
///         conversion when it does. Uniswap V2 for anything with a native pair, and admin-curated
///         Uniswap V4 routes for the assets that only exist there.
///
/// @dev WHY IT EXISTS AT ALL. Taxable tokens are clones of an implementation that can never be patched.
///      Both halves of the third-asset payout — "is this asset reachable" and "buy it" — used to be
///      compiled into that implementation, which meant a threshold that turned out wrong, an asset that
///      turned out malicious, or a venue that had to change, could only ever apply to tokens minted
///      AFTERWARDS. Behind a proxy at an address the token holds as a constant, a fix reaches every
///      token that already exists. Nothing else here would justify a separate contract.
///
/// @dev ELIGIBILITY IS PERMISSIONLESS BY DEFAULT. `isSwapSupported` is a liquidity test, not a list: any
///      ERC20 with a Uniswap V2 pair against the quote token holding at least the configured depth
///      passes, with no admin action of any kind. Admins can only ever REFUSE on that path — the veto is
///      the blacklist, plus the quote-token allowlist (the `from` side, protocol configuration rather
///      than a creator's choice) and the thresholds. `whitelisted` is a UI badge and gates nothing — it
///      deliberately has no effect on `isSwapSupported`, so it can never quietly become a gate. A V4
///      route (below) is the one lever that points the other way, and it can only ADD an asset that
///      would otherwise be refused; it can never take one away.
///
/// @dev TWO WAYS IN, AND THEY ARE NOT SYMMETRIC. The V2 test above is permissionless because a V2 pair
///      is a contract holding its own reserves: the address is derivable from the two tokens and the
///      depth is a `getReserves` away, so the registry can measure an asset nobody told it about. V4
///      gives it neither. A pair there can have any number of pools, distinguished only by a
///      `(fee, tickSpacing, hooks)` tuple that cannot be derived from the currencies, and the reserves
///      live in a singleton where "is there depth" is a much weaker question. Whole token universes
///      exist only on V4 — Robinhood Chain's ~190 xStocks, quoted in USDG rather than in the native coin
///      — so refusing them was refusing the chain. They get in through `setRoute`: an admin names the
///      exact pools, one hop at a time, and THAT naming is the curation. No depth threshold is applied
///      to a routed asset, because a threshold would be pretending to measure something the admin has
///      already asserted.
///
/// @dev CUSTODIES NOTHING. `swapNativeToAsset` receives, swaps and forwards inside one call, and holds
///      no balance between calls. There is deliberately no `receive()`, so the only native that can
///      reach it is native someone is actively converting. The one exception is ARC, where the venue
///      floors the 18-dec native amount to 6-dec USDC and leaves sub-1e-6 dust behind; it is unreachable
///      rather than owed to anyone, and a sweep for it would buy less than it costs to review.
contract LivoDividendSwapRegistry is ILivoDividendSwapRegistry, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Trust status values. Advisory: read by frontends, never by `isSwapSupported`, except
    ///         `BLACKLISTED`, which is the one veto.
    uint8 public constant TRUST_UNKNOWN = 0;
    uint8 public constant TRUST_WHITELISTED = 1;
    uint8 public constant TRUST_BLACKLISTED = 2;

    /// @notice Router every conversion goes through, and the source of the canonical quote token.
    address public constant SWAP_ROUTER = DeploymentAddresses.UNIV2_ROUTER;

    /// @notice Factory the quote/asset pair is resolved through.
    address public constant UNIV2_FACTORY = DeploymentAddresses.UNIV2_FACTORY;

    /// @notice Router a curated V4 route is executed on.
    /// @dev ETH-family chains only: the route pays the router in the native coin. On a chain whose
    ///      native currency is an ERC20 (ARC) no route can convert, so none is ever set there and every
    ///      asset goes through the V2 path.
    address public constant UNIV4_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Longest route `setRoute` accepts.
    /// @dev Bounds the loop the swap path walks. Two hops already covers the case this exists for
    ///      (native -> USDG -> xStock); the headroom is for an intermediate that needs one more.
    uint256 public constant MAX_ROUTE_HOPS = 4;

    /// @notice Router a curated V3 route is executed on. The same universal router the V4 venue uses;
    ///         only the command it is handed differs.
    address public constant UNIV3_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Longest V3 route `setV3Route` accepts, in hops.
    /// @dev TWO, not four. Every extra hop is another pool that can be drained and another price that
    ///      can be wrong, and the second hop is only worth having because its FIRST leg is a pool that
    ///      cannot realistically degrade — see `setV3Route`. A third hop would put a fragile pool in the
    ///      middle of the path, which is the thing the intermediate allowlist exists to prevent.
    uint256 public constant MAX_V3_ROUTE_HOPS = 2;

    /// @dev Byte widths of Uniswap V3's path encoding: `token | fee | token | fee | token…`.
    uint256 private constant V3_ADDR_BYTES = 20;
    uint256 private constant V3_FEE_BYTES = 3;

    //////////////////////// storage //////////////////////

    /// @notice Addresses allowed to manage entries (thresholds, trust status, the quote allowlist).
    ///         The owner manages THIS set and the upgrade; admins manage everything else.
    /// @dev Two tiers because the entry-level operations are frequent and operational (blacklisting an
    ///      asset that just turned hostile) while the owner is a cold multisig that should not be in
    ///      that loop. See [[feedback_two_tier_admin_for_whitelists]].
    mapping(address => bool) public isAdmin;

    /// @notice Quote tokens a conversion may start from. Always enforced: an asset is only eligible
    ///         against a quote token on this list.
    /// @dev Today this holds exactly one entry — the router's WETH — because every Livo token's
    ///      earnings are denominated in the chain's native currency. It is a mapping rather than a
    ///      constant so a future non-ETH-quoted token needs a transaction here, not a new token
    ///      implementation.
    mapping(address => bool) public isAllowedQuoteToken;

    /// @notice Per-quote-token depth override, in native 18-dec units. 0 means "use `defaultThreshold`".
    mapping(address => uint256) public quoteTokenThreshold;

    /// @notice Advisory trust status per asset. Only `TRUST_BLACKLISTED` changes any decision.
    mapping(address => uint8) public trustStatus;

    /// @notice Quote-side depth an asset's pair must hold, in native 18-dec units, when its quote token
    ///         has no override.
    uint256 public defaultThreshold;

    /// @notice Per-asset Uniswap V4 route, from the native coin to the asset. Empty = no route, which
    ///         sends the asset through the permissionless V2 test instead.
    /// @dev The one admin lever that ADMITS an asset rather than refusing one, and the only stored
    ///      eligibility state in this contract. Read through `routeOf`.
    mapping(address => Hop[]) internal _routes;

    /// @notice Per-asset Uniswap V3 route, as V3's own encoded path from the quote token to the asset.
    ///         Empty = no route.
    /// @dev A SEPARATE store from `_routes`, deliberately. A V3 pool is keyed by a fee tier alone, so it
    ///      would leave `Hop.tickSpacing` and `Hop.hooks` permanently dead, and the two venues are
    ///      maintained independently. Stored as the router's own path encoding rather than a decoded
    ///      struct because both the router and any off-chain quoter consume exactly these bytes — there
    ///      is no translation step at either call site, and one and two hops are the same shape.
    mapping(address => bytes) internal _v3Routes;

    /// @dev Reserved for future storage. Appending past this on an upgrade is safe; reordering anything
    ///      above it is not.
    uint256[43] private __gap;

    //////////////////////// events //////////////////////

    event AdminSet(address indexed account, bool allowed);
    event QuoteTokenAllowed(address indexed quote, bool allowed);
    event QuoteTokenThresholdSet(address indexed quote, uint256 threshold);
    event DefaultThresholdSet(uint256 threshold);
    event TrustStatusSet(address indexed asset, uint8 status);
    event RouteSet(address indexed asset, Hop[] route);
    /// @notice A curated V3 route was registered, changed, or (with an empty `path`) removed. Replaying
    ///         this event is how a frontend discovers which assets are selectable on this venue; there
    ///         is no other mechanism, and no hardcoded list should stand in for it.
    event V3RouteSet(address indexed asset, bytes path);
    event DividendAssetPurchased(address indexed asset, address indexed recipient, uint256 nativeIn, uint256 assetOut);

    //////////////////////// errors //////////////////////

    error NotAdmin();
    error InvalidTrustStatus();
    error ZeroThreshold();
    error SwapNotSupported(SwapRejection rejection);
    error NothingToSwap();
    /// @notice The venue call reverted: a drained pair, a missed floor, a token that refuses the swap.
    ///         Reported as a revert because the caller (a dividend freeze) must keep its native.
    error SwapFailed();
    error InsufficientOutput();
    error RouteTooLong();
    /// @notice The last hop buys something other than the asset the route is filed under. A route that
    ///         landed elsewhere would leave the swap unable to take what it was told to take.
    error RouteMustEndAtAsset();
    /// @notice The path is not a whole number of V3 hops, or is longer than `MAX_V3_ROUTE_HOPS`.
    error InvalidV3Path();
    /// @notice The path does not start at the quote token the router will fund itself with, or does not
    ///         end at the asset it is filed under. Either one sends the swap somewhere nobody chose.
    error V3RouteMustSpanQuoteToAsset();
    /// @notice A middle token on a multi-hop path is not on the quote-token allowlist. The allowlist is
    ///         reused here as the set of currencies the protocol trusts to route THROUGH.
    error V3IntermediateNotAllowed(address token);

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), NotAdmin());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @param initialOwner cold multisig: manages admins and upgrades, nothing else
    /// @param initialThreshold quote-side depth, native 18-dec, an asset's pair must hold by default
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
    function isSwapSupported(address quote, address asset) public view returns (bool supported) {
        (supported,,) = checkSwapSupported(quote, asset);
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function checkSwapSupported(address quote, address asset)
        public
        view
        returns (bool supported, uint8 trust, SwapRejection rejection)
    {
        trust = trustStatus[asset];

        if (!isAllowedQuoteToken[quote]) return (false, trust, SwapRejection.QuoteNotAllowed);
        if (trust == TRUST_BLACKLISTED) return (false, trust, SwapRejection.Blacklisted);

        // A curated route short-circuits the liquidity test, and comes FIRST so an asset an admin has
        // vouched for is never refused for lacking the V2 pair it was admitted for lacking. Same
        // resolution order as `_venueSwap`, and the two must never diverge: an asset judged eligible on
        // one venue and then swapped on another would convert through a pool nobody vetted.
        // Scoped to the NATIVE quote, because that is the only quote a route can start at: `_venueSwap`
        // builds every V4 hop from the native currency and pins every V3 path to `nativeQuoteToken()`.
        // A second allowed quote — which `setV3Route` needs for its intermediates, since
        // `V3IntermediateNotAllowed` reads this same mapping — must fall through to the V2 pair test
        // below, which resolves per-quote, rather than inherit a route it cannot use.
        if (_routes[asset].length != 0 || _v3Routes[asset].length != 0) {
            if (quote == nativeQuoteToken()) return (true, trust, SwapRejection.OK);
        }

        (address pair, uint256 quoteDepth) = pairFor(quote, asset);
        if (pair == address(0)) return (false, trust, SwapRejection.NoPair);

        uint256 threshold = quoteTokenThreshold[quote];
        if (threshold == 0) threshold = defaultThreshold;
        if (quoteDepth < threshold) return (false, trust, SwapRejection.InsufficientLiquidity);

        return (true, trust, SwapRejection.OK);
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

    /// @inheritdoc ILivoDividendSwapRegistry
    function isTrusted(address asset) public view returns (bool) {
        uint8 trust = trustStatus[asset];
        if (trust == TRUST_BLACKLISTED) return false;
        // A curated route counts as a vouch: an admin only files one after checking the pool's depth and
        // its price against the real market, which is the same judgement the whitelist badge records.
        return trust == TRUST_WHITELISTED || _routes[asset].length != 0 || _v3Routes[asset].length != 0;
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function routeOf(address asset) external view returns (Hop[] memory) {
        return _routes[asset];
    }

    /// @inheritdoc ILivoDividendSwapRegistry
    function v3RouteOf(address asset) external view returns (bytes memory) {
        return _v3Routes[asset];
    }

    //////////////////////// the swap //////////////////////

    /// @inheritdoc ILivoDividendSwapRegistry
    /// @dev Re-checks eligibility on every conversion rather than trusting the creation-time proof. A
    ///      pair can be drained, and an asset can be blacklisted, long after a token was configured for
    ///      it; without this the blacklist would only ever apply to tokens created after it was set.
    function swapNativeToAsset(address asset, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        require(msg.value != 0, NothingToSwap());

        address quote = nativeQuoteToken();
        (bool supported,, SwapRejection rejection) = checkSwapSupported(quote, asset);
        require(supported, SwapNotSupported(rejection));

        // Buy to THIS contract, not straight to `recipient`: the amount forwarded has to be a balance
        // delta measured here, because a fee-on-transfer asset delivers less than the router reports.
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        bool swapped = _venueSwap(quote, asset, minOut);
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
    }

    /// @dev Picks the venue for `asset` and spends `msg.value` on it. A curated route wins when there is
    ///      one — an asset only has a route BECAUSE it could not be reached on V2.
    /// @return ok false if the venue reverted; the caller turns that into `SwapFailed` and keeps the
    ///         native it was sent.
    function _venueSwap(address quote, address asset, uint256 minOut) private returns (bool ok) {
        Hop[] storage route = _routes[asset];
        if (route.length == 0) {
            // V3 before V2, matching `checkSwapSupported`. An asset only carries a V3 route because an
            // admin found its V3 pool better than whatever V2 offers, so the route wins where both exist.
            bytes memory v3Path = _v3Routes[asset];
            if (v3Path.length != 0) {
                return
                    UniversalRouterVenue.swapNativeToAssetV3Path(
                        UNIV3_UNIVERSAL_ROUTER, quote, v3Path, msg.value, minOut
                    );
            }
            address[] memory path = new address[](2);
            path[0] = quote;
            path[1] = asset;
            // Through the venue lib, not the router directly: the `chain-arc-*` recipe import-swaps it,
            // and ARC has no WETH — its native USDC shares a balance with the 6-dec ERC-20 the pair is
            // quoted in, so the same `msg.value` becomes a two-ERC20 swap there rather than an ETH-in one.
            return UniswapV2Venue.trySwapNativeToAsset(IUniswapV2Router(SWAP_ROUTER), quote, path, msg.value, minOut);
        }

        PathKey[] memory hops = new PathKey[](route.length);
        for (uint256 i; i < route.length; ++i) {
            Hop storage hop = route[i];
            hops[i] = PathKey({
                intermediateCurrency: Currency.wrap(hop.currency),
                fee: hop.fee,
                tickSpacing: hop.tickSpacing,
                hooks: IHooks(hop.hooks),
                // Never populated: a route is protocol configuration, not a channel for handing
                // arbitrary calldata to somebody else's hook.
                hookData: ""
            });
        }
        return UniversalRouterVenue.swapNativeToAssetV4Path(UNIV4_UNIVERSAL_ROUTER, hops, msg.value, minOut);
    }

    //////////////////////// admin //////////////////////

    /// @notice Owner-only: manage the admin set.
    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Allow or refuse a quote token as the `from` side of a conversion.
    function setAllowedQuoteToken(address quote, bool allowed) external onlyAdmin {
        isAllowedQuoteToken[quote] = allowed;
        emit QuoteTokenAllowed(quote, allowed);
    }

    /// @notice Override the depth threshold for one quote token. 0 clears the override.
    function setQuoteTokenThreshold(address quote, uint256 threshold) external onlyAdmin {
        quoteTokenThreshold[quote] = threshold;
        emit QuoteTokenThresholdSet(quote, threshold);
    }

    /// @notice Set the fallback depth threshold, in native 18-dec units.
    function setDefaultThreshold(uint256 threshold) external onlyAdmin {
        require(threshold != 0, ZeroThreshold());
        defaultThreshold = threshold;
        emit DefaultThresholdSet(threshold);
    }

    /// @notice Set an asset's trust status. `TRUST_BLACKLISTED` is the only value that changes a
    ///         decision; `TRUST_WHITELISTED` is a badge for the UI.
    function setTrustStatus(address asset, uint8 status) external onlyAdmin {
        require(status <= TRUST_BLACKLISTED, InvalidTrustStatus());
        trustStatus[asset] = status;
        emit TrustStatusSet(asset, status);
    }

    /// @notice Name the Uniswap V4 pools a conversion into `asset` crosses, starting from the native
    ///         coin. An empty `hops` clears the route and sends the asset back to the V2 test.
    /// @dev THE ONE LEVER THAT ADMITS. Every other admin function here can only refuse; this one lets an
    ///      admin vouch for an asset the permissionless test cannot see, because V4 pools are not
    ///      discoverable from their currencies. What is being asserted is that these specific pools are
    ///      the liquid ones — the registry cannot check that, and does not pretend to.
    /// @dev Setting a route on an asset that already passes the V2 test REDIRECTS it: the route wins.
    ///      Clearing one on an asset a live token is configured for does not brick that token if the
    ///      asset still has a deep V2 pair, and does brick its conversions if it does not — the same
    ///      exposure the blacklist already has, and the reason routes are removed only to fix them.
    /// @param hops each pool on the way, in order. The last hop must buy `asset` itself.
    function setRoute(address asset, Hop[] calldata hops) external onlyAdmin {
        require(hops.length <= MAX_ROUTE_HOPS, RouteTooLong());
        require(hops.length == 0 || hops[hops.length - 1].currency == asset, RouteMustEndAtAsset());

        delete _routes[asset];
        for (uint256 i; i < hops.length; ++i) {
            _routes[asset].push(hops[i]);
        }
        emit RouteSet(asset, hops);
    }

    /// @notice Name the Uniswap V3 pools a conversion into `asset` crosses, as V3's own encoded path.
    ///         An empty `path` clears the route and sends the asset back to the V2 test.
    ///
    /// @dev THE ADMISSION BAR IS OFF-CHAIN, AND THIS FUNCTION IS WHERE IT IS ASSERTED. A contract can
    ///      see that a pool exists; it cannot see whether the pool is DEEP enough to keep converting, and
    ///      it cannot see whether the pool's price tracks the asset's real market. Both have to be
    ///      checked by whoever registers the route:
    ///        - depth: quote the path at `MAX_DIVIDEND_PER_CONVERSION` and at ten times that, and refuse a
    ///          pool whose output stops growing with the input — an exhausted pool can carry a large
    ///          reported TVL and still fill nothing.
    ///        - price: compare the quoted price against a real market reference for the underlying, over
    ///          a full trading session rather than a single sample, and refuse a persistent premium
    ///          however deep the pool looks. Nothing on-chain catches this: the swap succeeds, and the
    ///          keeper's `minOut` comes from the same pool, so holders simply receive less value than the
    ///          earnings that bought it.
    ///      Neither gate can be enforced here, which is exactly why registering a route is an admin act.
    ///
    /// @dev WHAT IS VALIDATED HERE is only what makes a path executable at all: it spans quote -> asset,
    ///      it is a whole number of hops, it is at most `MAX_V3_ROUTE_HOPS`, and any middle token is one
    ///      the protocol already trusts as a routing currency. The intermediate allowlist is the reason a
    ///      two-hop route is safe to allow: the first leg is then always a major pool that will not
    ///      quietly die, so all the durability risk stays in the final hop — exactly where a one-hop
    ///      route already puts it.
    ///
    /// @param path `token | fee | token [| fee | token]`, 20 and 3 bytes alternating, starting at
    ///        `nativeQuoteToken()` and ending at `asset`.
    function setV3Route(address asset, bytes calldata path) external onlyAdmin {
        if (path.length != 0) {
            // A valid path is 20 + n*(3 + 20) bytes. Reject anything else before indexing into it.
            require(
                path.length >= V3_ADDR_BYTES + V3_FEE_BYTES + V3_ADDR_BYTES
                    && (path.length - V3_ADDR_BYTES) % (V3_FEE_BYTES + V3_ADDR_BYTES) == 0
                    && (path.length - V3_ADDR_BYTES) / (V3_FEE_BYTES + V3_ADDR_BYTES) <= MAX_V3_ROUTE_HOPS,
                InvalidV3Path()
            );
            require(
                _v3PathToken(path, 0) == nativeQuoteToken() && _v3PathToken(path, path.length - V3_ADDR_BYTES) == asset,
                V3RouteMustSpanQuoteToAsset()
            );
            // Middle tokens only: the ends are already pinned above.
            for (
                uint256 o = V3_ADDR_BYTES + V3_FEE_BYTES;
                o + V3_ADDR_BYTES < path.length;
                o += V3_FEE_BYTES + V3_ADDR_BYTES
            ) {
                address mid = _v3PathToken(path, o);
                require(isAllowedQuoteToken[mid], V3IntermediateNotAllowed(mid));
            }
        }

        _v3Routes[asset] = path;
        emit V3RouteSet(asset, path);
    }

    /// @dev The 20-byte address starting at `offset` in a V3 encoded path.
    function _v3PathToken(bytes calldata path, uint256 offset) private pure returns (address token) {
        return address(bytes20(path[offset:offset + V3_ADDR_BYTES]));
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
