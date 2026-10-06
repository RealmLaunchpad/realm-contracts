// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IRealmSwapper, Hop} from "src/interfaces/IRealmSwapper.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesRobinhood{Mainnet,Testnet}.
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {UniswapV2Venue} from "src/libraries/UniswapV2Venue.sol";
import {UniversalRouterVenue} from "src/libraries/UniversalRouterVenue.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IRealmPoolFee} from "src/interfaces/IRealmPoolFee.sol";

/// @notice What `sellToken` reads off a Realm token and its graduator to key the token's pool.
interface IRealmSwapperToken {
    function graduator() external view returns (address);
}

interface IRealmSwapperGraduator {
    function hookFor(address quote) external view returns (address);
}

/// @title RealmSwapper
/// @notice The protocol's one swapper. Performs the native -> asset conversion behind every dividend
///         payout, through the route the paying token registered for that asset (or the one an admin put
///         in its place), and sells LP fees collected in a Realm token for its pool's quote (`sellToken`).
///
/// @dev KEEPER CUT. `KEEPER_FEE` is taken only where native flows: every dividend conversion, and a
///      `sellToken` into the native quote. A `sellToken` into an ERC20 quote touches no native, so it pays
///      no cut rather than inventing a quote-denominated one.
///
/// @dev CREATOR-PICKED, ADMIN-REPOINTABLE. Each token registers its routes here at creation, keyed
///      `token => asset`, so one creator's route never touches another token paying the same asset.
///      Tokens are immutable clones; this proxy is not. So a route that was set wrong, or whose pool
///      drained or migrated, is fixed here by an admin: for one token (`setRoute(token, …)`) or, through
///      the `ALL_TOKENS` override, for every token paying that asset in one transaction. Any ERC20 may be
///      configured as a payout asset — one without a route just does not convert until it gets one. No
///      liquidity gate runs at registration or conversion: the swap itself, and the keeper's `minOut`,
///      are the truth about whether a pool can deliver.
///
/// @dev TWO ROUTE KINDS. A BUY route (native -> asset, any venue) buys a payout asset. A QUOTE route
///      (V4 only) is walked backwards to SELL an ERC20 quote into native when a dividends leg is bought
///      out of it; only V4 names its pools outright, so only V4 can be reversed. Kept apart so a quote
///      that is also a payout asset can be bought on V2/V3 and still be sold on V4. With no quote route,
///      the sell falls back to the quote's buy route, which then has to be V4.
///
/// @dev CUSTODIES NOTHING. `swapNativeToAsset` receives, swaps and forwards inside one call, and holds
///      no balance between calls. Its `receive()` exists only for the native a reverse V4 leg takes out
///      of the pool manager mid-`swapAssetToAsset`, which moves on in the same call; anything else sent
///      there is a donation nobody can recover.
contract RealmSwapper is IRealmSwapper, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Contract version.
    uint256 public constant VERSION = 1;

    using SafeERC20 for IERC20;

    /// @notice Router every V2 conversion goes through, and the source of the canonical quote token.
    address public constant SWAP_ROUTER = DeploymentAddresses.UNIV2_ROUTER;

    /// @notice Router a V4 or V3 route is executed on. One router, two commands.
    /// @dev The route pays the router in the native coin.
    address public constant UNIV4_UNIVERSAL_ROUTER = DeploymentAddresses.UNIV4_UNIVERSAL_ROUTER;

    /// @notice Permit2, through which the universal router pulls an ERC20 the registry sells.
    address public constant PERMIT2 = DeploymentAddresses.PERMIT2;

    /// @notice Longest V4 route accepted.
    /// @dev Bounds the loop the swap path walks. Two hops already covers the case this exists for
    ///      (native -> USDG -> rStock); the headroom is for an intermediate that needs one more.
    uint256 public constant MAX_ROUTE_HOPS = 4;

    /// @notice Longest V3 route accepted, in hops.
    /// @dev TWO, not four: every extra hop is another pool that can be drained and another price that
    ///      can be wrong.
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
    ///      for the one case where "flat" breaks down: a conversion smaller than the fee itself, which a
    ///      keeper slicing a thin pool can produce. Without the clip that swap would be handed nothing and
    ///      revert; with it the keeper simply eats the difference on a conversion it chose to trigger.
    uint16 public constant MAX_KEEPER_CUT_BPS = 2_000;

    uint256 private constant BPS_TOTAL = 10_000;

    /// @notice The `token` key an admin writes to repoint an asset for EVERY token paying it. A route
    ///         stored here wins over each token's own until it is cleared (set empty).
    /// @dev No token can register under it: `registerRoute` keys on `msg.sender`, never zero.
    address public constant ALL_TOKENS = address(0);

    //////////////////////// storage //////////////////////

    /// @notice Addresses allowed to set routes and the keeper wallet. The owner manages THIS set and
    ///         the upgrade; admins manage everything else.
    /// @dev Two tiers because route maintenance is frequent and operational while the owner is a cold
    ///      multisig that should not be in that loop.
    mapping(address => bool) public isAdmin;

    /// @notice Buy routes, `token => asset => route`, in the `DividendRouteLib` wire format. The
    ///         `ALL_TOKENS` row is the admin override. Empty: no route, so that conversion fails until
    ///         one is set.
    mapping(address => mapping(address => bytes)) internal _routes;

    /// @notice Quote (sell) routes, `token => quote => route`, V4 only, same wire format and same
    ///         `ALL_TOKENS` override. Empty: fall back to the quote's buy route.
    mapping(address => mapping(address => bytes)) internal _quoteRoutes;

    /// @notice Hot wallet that pays the gas for the out-of-band conversions, funded by `KEEPER_FEE` out
    ///          of every conversion it triggers. `address(0)` — the default — disables the fee entirely,
    ///          so a registry that has not been configured yet converts exactly as it did before.
    /// @dev NOT the keeper allowlist — that is `RealmKeepersRegistry`, a different contract with a
    ///      different question. This is only where the gas money goes, and it is deliberately a single
    ///      address: splitting a cut across several would need a schedule nobody has asked for.
    address public keeper;

    /// @notice Assets an admin has declared dead as a dividend payout or a quote: a pool gone for good, a
    ///         token that stopped transferring. Tokens read it at every funding and, for a leg that would
    ///         convert into or out of a retired asset, pay the buffer in its own currency instead (their
    ///         fallback pots) — so a dead asset strands nothing. Reversible: un-retiring resumes
    ///         conversions, and what the fallback already credited stays claimable.
    /// @dev A flag, not a route: a route can be repointed, a dead asset has nowhere to point. Read only by
    ///      token implementations that know it; older clones keep converting (and failing) as before.
    mapping(address asset => bool) public isRetired;

    /// @dev Reserved for future storage. Appending past this on an upgrade is safe; reordering anything
    ///      above it is not.
    uint256[45] private __gap;

    //////////////////////// events //////////////////////

    event AdminSet(address indexed account, bool allowed);
    /// @notice `token` registered its route for `asset` at creation. `quote`: a sell route for one of
    ///         its ERC20 quotes rather than a payout asset's buy route. Replaying these, then
    ///         `RouteSet`, is how an indexer learns which pools each conversion crosses.
    event RouteRegistered(address indexed token, address indexed asset, bool quote, bytes route);
    /// @notice An admin repointed `token`'s route for `asset` (`token == ALL_TOKENS`: the override for
    ///         every token). Empty `route`: removed. `quote` as in `RouteRegistered`.
    event RouteSet(address indexed token, address indexed asset, bool quote, bytes route);
    event AssetPurchased(address indexed asset, address indexed recipient, uint256 nativeIn, uint256 assetOut);
    /// @notice The wallet the per-conversion `KEEPER_FEE` is paid to changed. `address(0)` turns the fee
    ///          off. Named for the funding, not for the keeper set — the allowlist lives in
    ///          `RealmKeepersRegistry` and emits its own `KeeperSet`.
    event KeeperFundingSet(address indexed keeper);
    /// @notice A conversion paid the keeper its fee. Reported per conversion because the clip makes it
    ///          less than `KEEPER_FEE` on a small one. `AssetPurchased.nativeIn` for the same
    ///          conversion is the FULL amount the token sent, this included, not the amount swapped.
    event KeeperFunded(address indexed keeper, uint256 amount);
    /// @notice `sellToken` is about to sell `amountIn` of the Realm `token` for `quote` in the token's own
    ///         pool. Emitted BEFORE the swap: the precursor that lets an indexer flag the hook's
    ///         `RealmSwapSell` / `RealmQuoteSwapSell` that follows as protocol-internal.
    event RealmTokenSellInitiated(address indexed token, address indexed quote, uint256 amountIn);
    /// @notice `asset` was retired (`true`) or brought back (`false`). Emitted on every `setRetired`.
    event AssetRetired(address indexed asset, bool retired);

    /// @notice A `swapAssetToAsset` conversion: `amountIn` of `source` became `nativeVia` native on the
    ///         way — the keeper's cut, if any, came out of that — and `assetOut` of `asset` for
    ///         `recipient` (`asset == address(0)`: native, and `assetOut` is what was delivered).
    event AssetSwapped(
        address indexed source,
        address indexed asset,
        address indexed recipient,
        uint256 amountIn,
        uint256 nativeVia,
        uint256 assetOut
    );

    //////////////////////// errors //////////////////////

    error NotAdmin();
    /// @notice The asset has no route (or, for `swapAssetToAsset`'s first leg, none that can be walked
    ///         backwards — only V4 can).
    error NoRoute();
    /// @notice The route is not well-formed for the asset it was set for (a quote route: or not V4).
    error MalformedRoute();
    /// @notice The token already registered a route for this asset; only an admin can change it now.
    error RouteAlreadyRegistered();
    error NothingToSwap();
    /// @notice The venue call reverted: a drained pool, a missed floor, a token that refuses the swap.
    ///         Reported as a revert because the caller (a dividend freeze) must keep its native.
    error SwapFailed();
    error InsufficientOutput();
    /// @notice A native payout could not be delivered to the recipient.
    error NativeDeliveryFailed();
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
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    //////////////////////// views //////////////////////

    /// @notice The WETH every V2/V3 route starts from.
    /// @dev `pure` because Uniswap's router declares `WETH()` that way; it is a STATICCALL either way.
    function nativeQuoteToken() public pure returns (address) {
        return UniswapV2Venue.pairToken(IUniswapV2Router(SWAP_ROUTER));
    }

    /// @inheritdoc IRealmSwapper
    function routeOf(address token, address asset) public view returns (bytes memory route) {
        route = _routes[ALL_TOKENS][asset];
        if (route.length == 0) route = _routes[token][asset];
    }

    /// @inheritdoc IRealmSwapper
    function quoteRouteOf(address token, address quote) public view returns (bytes memory route) {
        route = _quoteRoutes[ALL_TOKENS][quote];
        if (route.length == 0) route = _quoteRoutes[token][quote];
        if (route.length == 0) route = routeOf(token, quote);
    }

    //////////////////////// route registration //////////////////////

    /// @inheritdoc IRealmSwapper
    function registerRoute(address asset, bytes calldata route) external {
        _register(_routes, asset, route, false);
    }

    /// @inheritdoc IRealmSwapper
    function registerQuoteRoute(address quote, bytes calldata route) external {
        _register(_quoteRoutes, quote, route, true);
    }

    /// @dev Write-once per (`msg.sender`, asset): a token registers at creation and never again, so
    ///      anything after that is an admin's. Shape-checked only; anyone may call, but only ever writes
    ///      its own row, which nothing reads unless that caller is a token converting through here.
    function _register(
        mapping(address => mapping(address => bytes)) storage routes,
        address asset,
        bytes calldata route,
        bool quote
    ) private {
        require(routes[msg.sender][asset].length == 0, RouteAlreadyRegistered());
        require(_wellFormed(asset, route, quote), MalformedRoute());
        routes[msg.sender][asset] = route;
        emit RouteRegistered(msg.sender, asset, quote, route);
    }

    /// @dev Shape only — no liquidity read. Catches a route set for the wrong asset or a garbled path;
    ///      whether its pools can absorb a conversion is proven off-chain before listing (fork probe) and
    ///      re-proven by every swap.
    ///      A quote route (`quote`) must be V4: it is walked backwards, which only V4 can be.
    function _wellFormed(address asset, bytes memory route, bool quote) internal pure returns (bool) {
        uint8 venue = DividendRouteLib.venue(route);
        if (quote && venue != DividendRouteLib.VENUE_V4) return false;
        if (venue == DividendRouteLib.VENUE_V2) return route.length == 1;
        if (venue == DividendRouteLib.VENUE_V4) {
            Hop[] memory hops = DividendRouteLib.toV4Hops(route);
            uint256 n = hops.length;
            if (n == 0 || n > MAX_ROUTE_HOPS || hops[n - 1].currency != asset) return false;
            // Every V4 route starts at the native coin (`swapNativeToAssetV4Path` settles it).
            address from = address(0);
            for (uint256 i; i < n; ++i) {
                if (hops[i].currency == from) return false;
                from = hops[i].currency;
            }
            return true;
        }
        if (venue == DividendRouteLib.VENUE_V3) {
            bytes memory path = DividendRouteLib.toV3Path(route);
            uint256 len = path.length;
            if (
                len < V3_ADDR_BYTES + V3_FEE_BYTES + V3_ADDR_BYTES
                    || (len - V3_ADDR_BYTES) % (V3_FEE_BYTES + V3_ADDR_BYTES) != 0
                    || (len - V3_ADDR_BYTES) / (V3_FEE_BYTES + V3_ADDR_BYTES) > MAX_V3_ROUTE_HOPS
            ) return false;
            // `WRAP_ETH` funds the router in WETH, so the path must start there.
            return _v3PathToken(path, 0) == nativeQuoteToken() && _v3PathToken(path, len - V3_ADDR_BYTES) == asset;
        }
        return false;
    }

    /// @dev The 20-byte address starting at `offset` in a V3 encoded path.
    function _v3PathToken(bytes memory path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, mload(add(add(path, 0x20), offset)))
        }
    }

    /// @dev The caller's buy route for `asset`, decoded, or `NoRoute`.
    function _route(address asset) private view returns (DividendRouteLib.Decoded memory route) {
        route = DividendRouteLib.decode(routeOf(msg.sender, asset));
        require(route.venue != 0, NoRoute());
    }

    //////////////////////// the swap //////////////////////

    /// @notice Accepts the native a reverse leg takes out of the pool manager: `swapAssetToAsset`'s
    ///         first leg lands here before the keeper's cut and the second leg move it on. Nothing
    ///         rests here between calls — `swapNativeToAsset` never needed this because its native
    ///         arrives as `msg.value`.
    receive() external payable {}

    /// @inheritdoc IRealmSwapper
    function swapNativeToAsset(address asset, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        require(msg.value != 0, NothingToSwap());

        DividendRouteLib.Decoded memory route = _route(asset);

        // The keeper's fee comes off the top, so what follows only ever spends what is left. `minOut` is
        // therefore a floor on the SWAPPED amount, not on `msg.value` — the keeper computes it off-chain
        // and has to quote the net.
        (uint256 nativeIn, uint256 cut, address keeperWallet) = _keeperCut(msg.value);

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
        emit AssetPurchased(asset, recipient, msg.value, out);

        // Paid LAST, and only on a conversion that worked: a reverted swap keeps the caller's native
        // whole, so the keeper must not have been paid out of it on the way. Still custodies nothing —
        // the cut only rests here for the length of this call.
        _payKeeper(keeperWallet, cut);
    }

    /// @inheritdoc IRealmSwapper
    /// @dev Two legs, each through its asset's route. The keeper's cut
    ///      is taken from the native in between, so the ERC20 legs fund the keeper exactly as the native
    ///      ones do and nothing but native ever rests here for it. `minOut` guards the FINAL amount:
    ///      a sandwich on either leg shows up there, so the native leg carries no floor of its own except
    ///      when native IS the destination.
    function swapAssetToAsset(address source, address asset, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        require(amountIn != 0, NothingToSwap());
        require(source != address(0) && source != asset, NoRoute());
        IERC20(source).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 native = _swapToNative(source, amountIn, asset == address(0) ? minOut : 0);
        (uint256 nativeIn, uint256 cut, address keeperWallet) = _keeperCut(native);
        if (asset == address(0)) {
            out = nativeIn;
            require(out >= minOut, InsufficientOutput());
            (bool sent,) = recipient.call{value: out}("");
            require(sent, NativeDeliveryFailed());
        } else {
            out = _swapFromNative(asset, nativeIn, minOut);
            IERC20(asset).safeTransfer(recipient, out);
        }
        emit AssetSwapped(source, asset, recipient, amountIn, native, out);
        _payKeeper(keeperWallet, cut);
    }

    /// @inheritdoc IRealmSwapper
    /// @dev Permissionless, like the dividend legs: the caller sells its own tokens. The pool is the one
    ///      the token itself reports (`poolFee()`, its graduator's `hookFor`), so a token that is not a
    ///      Realm token can only ever route the caller's own funds through its own pool.
    /// @dev All of `amountIn` or revert, measured on this contract's balance: Permit2 pulls only what the
    ///      swap owed, and a partial fill must not leave the rest here.
    function sellToken(address token, address quote, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out)
    {
        require(amountIn != 0, NothingToSwap());
        require(token != quote, NoRoute());
        PoolKey memory key = abi.decode(
            abi.encode(
                UniswapV4PoolConstants.realmPoolKey(
                    token,
                    quote,
                    IRealmSwapperGraduator(IRealmSwapperToken(token).graduator()).hookFor(quote),
                    IRealmPoolFee(token).poolFee()
                )
            ),
            (PoolKey)
        );
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        UniversalRouterVenue.ensureRouterPull(PERMIT2, UNIV4_UNIVERSAL_ROUTER, token);

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 quoteBefore = _holdings(quote);
        emit RealmTokenSellInitiated(token, quote, amountIn);
        require(
            UniversalRouterVenue.swapExactInSingleV4(
                UNIV4_UNIVERSAL_ROUTER, key, Currency.unwrap(key.currency0) == token, amountIn, minOut
            ) && tokenBefore - IERC20(token).balanceOf(address(this)) == amountIn,
            SwapFailed()
        );
        uint256 gross = _holdings(quote) - quoteBefore;

        if (quote != address(0)) {
            out = gross;
            require(out != 0 && out >= minOut, InsufficientOutput());
            IERC20(quote).safeTransfer(recipient, out);
            return out;
        }
        (uint256 net, uint256 cut, address keeperWallet) = _keeperCut(gross);
        out = net;
        require(out != 0 && out >= minOut, InsufficientOutput());
        (bool sent,) = recipient.call{value: out}("");
        require(sent, NativeDeliveryFailed());
        _payKeeper(keeperWallet, cut);
    }

    function _holdings(address currency) private view returns (uint256) {
        return currency == address(0) ? address(this).balance : IERC20(currency).balanceOf(address(this));
    }

    /// @dev Leg 1 of `swapAssetToAsset`: the caller's quote route for `source` (`quoteRouteOf`) walked
    ///      BACKWARDS to native. Only a V4 route can be: it names its pools outright, whereas a V3 path is
    ///      one-directional calldata and a V2 pair swap needs the router's ETH-out entry point this
    ///      registry does not wire. A quote route is V4 by construction; the buy-route fallback may not be.
    function _swapToNative(address source, uint256 amountIn, uint256 minOut) private returns (uint256 native) {
        DividendRouteLib.Decoded memory route = DividendRouteLib.decode(quoteRouteOf(msg.sender, source));
        require(route.venue == DividendRouteLib.VENUE_V4, NoRoute());
        Hop[] memory hops = route.hops;
        uint256 n = hops.length;
        PathKey[] memory path = new PathKey[](n);
        // The route runs native -> ... -> source; walked back, hop `j` OUTPUTS the currency before it.
        for (uint256 k; k < n; ++k) {
            uint256 j = n - 1 - k;
            path[k] = PathKey({
                intermediateCurrency: Currency.wrap(j == 0 ? address(0) : hops[j - 1].currency),
                fee: hops[j].fee,
                tickSpacing: hops[j].tickSpacing,
                hooks: IHooks(hops[j].hooks),
                hookData: ""
            });
        }
        UniversalRouterVenue.ensureRouterPull(PERMIT2, UNIV4_UNIVERSAL_ROUTER, source);
        uint256 before = address(this).balance;
        uint256 sourceBefore = IERC20(source).balanceOf(address(this));
        // All of `amountIn` or nothing: a partial fill would leave the rest here, where nothing can sweep
        // it, while the caller books the whole spend.
        require(
            UniversalRouterVenue.swapAssetToNativeV4Path(UNIV4_UNIVERSAL_ROUTER, source, path, amountIn, minOut)
                && sourceBefore - IERC20(source).balanceOf(address(this)) == amountIn,
            SwapFailed()
        );
        native = address(this).balance - before;
        require(native != 0, InsufficientOutput());
    }

    /// @dev Leg 2 of `swapAssetToAsset`: the payout asset's own route, forward — `swapNativeToAsset`'s
    ///      body without the pull and the delivery.
    function _swapFromNative(address asset, uint256 nativeIn, uint256 minOut) private returns (uint256 out) {
        DividendRouteLib.Decoded memory route = _route(asset);
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        require(_venueSwap(asset, route, nativeIn, minOut), SwapFailed());
        out = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        require(out != 0 && out >= minOut, InsufficientOutput());
    }

    /// @dev The keeper's cut off `native`: the flat `KEEPER_FEE`, clipped to `MAX_KEEPER_CUT_BPS` of the
    ///      amount, and nothing while no keeper wallet is set.
    function _keeperCut(uint256 native) private view returns (uint256 net, uint256 cut, address keeperWallet) {
        keeperWallet = keeper;
        if (keeperWallet != address(0)) {
            uint256 maxCut = (MAX_KEEPER_CUT_BPS * native) / BPS_TOTAL;
            cut = KEEPER_FEE < maxCut ? KEEPER_FEE : maxCut;
        }
        net = native - cut;
    }

    /// @dev Paid LAST, and only on a conversion that worked: a reverted swap keeps the caller's input
    ///      whole, so the keeper must not have been paid out of it on the way. Still custodies nothing —
    ///      the cut only rests here for the length of the call.
    function _payKeeper(address keeperWallet, uint256 cut) private {
        if (cut == 0) return;
        (bool sent,) = keeperWallet.call{value: cut}("");
        require(sent, KeeperFundingFailed());
        emit KeeperFunded(keeperWallet, cut);
    }

    /// @dev Spends `nativeIn` on the venue `route` names. `_wellFormed` admitted only these three.
    /// @return ok false if the venue reverted; the caller turns that into `SwapFailed` and keeps the
    ///         native it was sent.
    function _venueSwap(address asset, DividendRouteLib.Decoded memory route, uint256 nativeIn, uint256 minOut)
        private
        returns (bool ok)
    {
        address quote = nativeQuoteToken();
        uint8 venue = route.venue;

        if (venue == DividendRouteLib.VENUE_V4) {
            Hop[] memory hops = route.hops;
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

        if (venue == DividendRouteLib.VENUE_V3) {
            return
                UniversalRouterVenue.swapNativeToAssetV3Path(
                    UNIV4_UNIVERSAL_ROUTER, quote, route.path, nativeIn, minOut
                );
        }

        address[] memory v2Path = new address[](2);
        v2Path[0] = quote;
        v2Path[1] = asset;
        return UniswapV2Venue.trySwapNativeToAsset(IUniswapV2Router(SWAP_ROUTER), quote, v2Path, nativeIn, minOut);
    }

    //////////////////////// admin //////////////////////

    /// @notice Owner-only: manage the admin set.
    function setAdmin(address account, bool allowed) external onlyOwner {
        isAdmin[account] = allowed;
        emit AdminSet(account, allowed);
    }

    /// @notice Set, repoint or (empty `route`) remove `token`'s buy route for `asset`. `token ==
    ///         ALL_TOKENS` sets the override every token paying `asset` converts through instead.
    /// @dev Checks shape, not depth: probe a route on a fork before listing it (`PickDividendRoutes`).
    function setRoute(address token, address asset, bytes calldata route) external onlyAdmin {
        _set(_routes, token, asset, route, false);
    }

    /// @notice Same for `token`'s quote (sell) route for `quote`. V4 only.
    function setQuoteRoute(address token, address quote, bytes calldata route) external onlyAdmin {
        _set(_quoteRoutes, token, quote, route, true);
    }

    function _set(
        mapping(address => mapping(address => bytes)) storage routes,
        address token,
        address asset,
        bytes calldata route,
        bool quote
    ) private {
        require(route.length == 0 || _wellFormed(asset, route, quote), MalformedRoute());
        routes[token][asset] = route;
        emit RouteSet(token, asset, quote, route);
    }

    /// @notice Retires `asset`, or brings it back. See `isRetired`. Admin or owner.
    function setRetired(address asset, bool retired) external onlyAdmin {
        isRetired[asset] = retired;
        emit AssetRetired(asset, retired);
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
