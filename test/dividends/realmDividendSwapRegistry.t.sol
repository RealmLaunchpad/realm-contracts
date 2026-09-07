// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {SwapRejection, Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {installDividendSwapRegistry, DEFAULT_DIVIDEND_POOL_LIQUIDITY} from "test/helpers/DividendRegistryHelpers.sol";

contract Ghost is ERC20 {
    constructor() ERC20("Ghost", "GHOST") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Stand-in for the universal router on a PARTIAL fill: the pool takes only half the native and
///         the rest stays with the router, which never refunds on its own and which anyone may sweep.
///         A real V4 pool reaches this when its liquidity runs out before the input does — `SETTLE_ALL`
///         then settles the debt the swap actually incurred, not what was sent.
contract PartialFillV4RouterStub {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        (bool spent,) = SINK.call{value: msg.value / 2}("");
        require(spent, "sink failed");
        IERC20(USDC).transfer(msg.sender, 1e6);
    }
}

/// @notice The swap venue for third-asset dividends, and the keeper of the route each token registered.
///         The rule it enforces is deliberately permissionless — Realm does not review payout assets and
///         has no allowlist of them — so most of what is asserted here is what nobody needs permission
///         for, and what the one remaining admin lever CANNOT do.
/// @dev This test contract stands in for a TOKEN throughout: routes are keyed by the caller, so
///      `address(this)` registering a route and then converting is exactly the shape a clone has.
contract RealmDividendSwapRegistryTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @dev The mainnet V4 pools the route tests cross, live at `BLOCKNUMBER`. Hookless and static-fee,
    ///      unlike Robinhood Chain's xStock pools — the encoding under test is the same either way.
    uint24 internal constant V4_FEE_005 = 500;
    int24 internal constant V4_SPACING_10 = 10;
    uint24 internal constant V4_FEE_001 = 100;
    int24 internal constant V4_SPACING_1 = 1;

    /// @dev The empty route: the explicit choice of the asset's permissionless Uniswap V2 pair.
    bytes internal constant V2_ROUTE = "";

    RealmDividendSwapRegistry internal registry;
    address internal weth;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);
        weth = registry.nativeQuoteToken();

        vm.prank(owner);
        registry.setAdmin(admin, true);
    }

    //////////////////////// the rule //////////////////////

    /// @dev The whole eligibility rule for an unrouted asset: liquidity, measured live, with nobody's
    ///      approval. An asset the admins have never heard of passes as readily as one they have.
    function test_anyAssetWithADeepPairQualifiesUnprompted() public view {
        assertEq(uint8(registry.validateRoute(DAI, V2_ROUTE)), uint8(SwapRejection.OK), "DAI");
        assertEq(uint8(registry.validateRoute(USDC, V2_ROUTE)), uint8(SwapRejection.OK), "USDC");
    }

    /// @dev NOBODY IS ASKED. Registration is open to any caller, because the caller is always the token
    ///      committing itself. If this ever needs a role, the feature has quietly become a curated list.
    function test_anyoneMayRegisterARouteForThemselves() public {
        vm.prank(stranger);
        registry.registerRoute(DAI, V2_ROUTE);

        (bool ok,) = registry.checkSwapSupported(stranger, DAI);
        assertTrue(ok, "a stranger configured their own token with no permission at all");
    }

    function test_anAssetWithNoPairIsRejectedWithNoPair() public {
        SwapRejection why = registry.validateRoute(address(new Ghost()), V2_ROUTE);
        assertEq(uint8(why), uint8(SwapRejection.NoPair));
    }

    /// @dev A pair that exists but is too thin reports a DIFFERENT reason from one that does not exist.
    ///      The distinction is the whole point of the detailed view: "seed more liquidity" and "you have
    ///      the wrong address" are different problems for a creator.
    function test_aThinPairIsRejectedWithInsufficientLiquidity() public {
        Ghost thin = new Ghost();
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

        uint256 seeded = DEFAULT_DIVIDEND_POOL_LIQUIDITY / 2;
        vm.deal(address(this), seeded);
        thin.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: seeded}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        assertEq(uint8(registry.validateRoute(address(thin), V2_ROUTE)), uint8(SwapRejection.InsufficientLiquidity));

        (address pair, uint256 depth) = registry.pairFor(weth, address(thin));
        assertTrue(pair != address(0), "the pair does exist");
        assertEq(depth, seeded, "and its depth is what was seeded");
    }

    /// @dev The one veto. It refuses; nothing here can admit.
    function test_blacklistingRefusesTheAsset() public {
        vm.prank(admin);
        registry.setBlacklisted(DAI, true);

        assertEq(uint8(registry.validateRoute(DAI, V2_ROUTE)), uint8(SwapRejection.Blacklisted));
    }

    /// @dev A per-quote override beats the default in both directions.
    function test_aPerQuoteThresholdOverridesTheDefault() public {
        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, type(uint128).max);
        assertEq(
            uint8(registry.validateRoute(DAI, V2_ROUTE)),
            uint8(SwapRejection.InsufficientLiquidity),
            "the override refuses what the default allowed"
        );

        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, 0);
        assertEq(uint8(registry.validateRoute(DAI, V2_ROUTE)), uint8(SwapRejection.OK), "clearing it falls back");
    }

    function test_anUnlistedQuoteTokenIsRefused() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(weth, false);
        assertEq(uint8(registry.validateRoute(DAI, V2_ROUTE)), uint8(SwapRejection.QuoteNotAllowed));
    }

    //////////////////////// registration //////////////////////

    /// @dev WRITE-ONCE. A route the creator could rewrite later would be a rug lever: point the token at
    ///      a pool you control the day before a big conversion. Creation runs once, so nothing legitimate
    ///      ever calls this twice.
    function test_aRouteCannotBeRewritten() public {
        registry.registerRoute(DAI, V2_ROUTE);

        vm.expectRevert(RealmDividendSwapRegistry.RouteAlreadyRegistered.selector);
        registry.registerRoute(DAI, _v4(DAI, V4_FEE_005, V4_SPACING_10));
    }

    /// @dev The empty route is a REAL registration, not an absent one — which is why the write-once
    ///      guard is a separate flag rather than a test on the stored bytes.
    function test_theEmptyRouteIsARegistrationOfItsOwn() public {
        registry.registerRoute(DAI, V2_ROUTE);
        assertEq(registry.routeOf(address(this), DAI).length, 0, "stored as empty");
        assertTrue(registry.routeRegistered(address(this), DAI), "but registered all the same");
    }

    /// @dev Two tokens naming the same asset carry their own routes. One creator's bad choice cannot
    ///      reach another creator's holders, and nobody can grief a popular asset globally.
    function test_routesAreScopedToTheTokenThatRegisteredThem() public {
        registry.registerRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10));
        vm.prank(stranger);
        registry.registerRoute(USDC, V2_ROUTE);

        assertGt(registry.routeOf(address(this), USDC).length, 0, "ours is the V4 route");
        assertEq(registry.routeOf(stranger, USDC).length, 0, "theirs is the V2 pair");
    }

    /// @dev A route whose last hop buys something else would leave the swap unable to take what it was
    ///      told to take. Caught where it is cheap to catch instead of at the next freeze.
    function test_aRouteMustEndAtTheAsset() public {
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(DAI, _v4(USDC, V4_FEE_005, V4_SPACING_10));
    }

    function test_aRouteLongerThanTheCapIsRefused() public {
        Hop[] memory hops = new Hop[](registry.MAX_ROUTE_HOPS() + 1);
        for (uint256 i; i < hops.length; ++i) {
            hops[i] = Hop({currency: DAI, fee: V4_FEE_005, tickSpacing: V4_SPACING_10, hooks: address(0)});
        }
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(DAI, DividendRouteLib.encodeV4(hops));
    }

    function test_anUnknownVenueTagIsRefusedRatherThanTreatedAsV2() public {
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(DAI, hex"07deadbeef");
    }

    /// @dev THE TYPO GATE, and the reason registration validates at all. A fee/tickSpacing/hooks
    ///      combination nobody ever initialized is indistinguishable from the right pool until the pool
    ///      manager is asked. Without this the mistake would surface at some future `processDividends`,
    ///      on a clone nobody can patch, and there is no second chance to fix the route.
    function test_aRouteNamingAPoolThatWasNeverInitializedIsRefused() public {
        _expectRejected(SwapRejection.DeadPool);
        registry.registerRoute(USDC, _v4(USDC, 3000, int24(199)));
    }

    /// @dev The precheck a frontend runs before a token exists: same answer, no state, no caller.
    function test_validateRouteAnswersWithoutATokenAtAll() public view {
        assertEq(uint8(registry.validateRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10))), uint8(SwapRejection.OK));
        assertEq(uint8(registry.validateRoute(USDC, _v4(USDC, 3000, int24(199)))), uint8(SwapRejection.DeadPool));
    }

    //////////////////////// the swap //////////////////////

    function test_swapDeliversToTheRecipientAndKeepsNothing() public {
        registry.registerRoute(DAI, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(DAI).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(DAI).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    function test_swapRevertsForAnIneligibleAsset() public {
        address ghost = address(new Ghost());
        vm.deal(address(this), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.NoPair)
        );
        registry.swapNativeToAsset{value: 1 ether}(ghost, 1, recipient);
    }

    /// @dev Eligibility is re-checked on every conversion, not trusted from registration time. Without
    ///      this a blacklist would only ever bind tokens created after it was set — and since routes are
    ///      permanent, the blacklist is the ONLY thing that can still stop a hostile asset.
    function test_swapRevertsForAnAssetBlacklistedAfterRegistration() public {
        registry.registerRoute(DAI, V2_ROUTE);
        vm.prank(admin);
        registry.setBlacklisted(DAI, true);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.Blacklisted)
        );
        registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);
    }

    function test_swapRevertsOnAMissedFloor() public {
        registry.registerRoute(DAI, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        registry.swapNativeToAsset{value: 1 ether}(DAI, 1_000_000e18, recipient);
    }

    /// @dev The keeper is paid a FLAT fee out of every conversion — gas is an absolute cost — and only
    ///      what is left is swapped. The registry still keeps nothing: the fee rests here for the length
    ///      of the call and no longer.
    function test_theKeeperIsFundedOutOfEveryConversion() public {
        registry.registerRoute(DAI, V2_ROUTE);
        address keeper = makeAddr("keeper");
        uint256 fee = registry.KEEPER_FEE();
        vm.prank(admin);
        registry.setKeeperFunding(keeper);

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);

        assertEq(keeper.balance, fee, "the keeper took its flat fee");
        assertEq(IERC20(DAI).balanceOf(recipient), out, "the recipient got the rest, converted");
        assertEq(address(registry).balance, 0, "and the registry kept no native");

        // Ten times the conversion size, same fee: the whole point of flat over percentage.
        vm.deal(address(this), 10 ether);
        registry.swapNativeToAsset{value: 10 ether}(DAI, 1, recipient);
        assertEq(keeper.balance, 2 * fee, "a ten-times-larger conversion pays the same fee");
    }

    /// @dev No keeper wallet, no fee — which is the state every registry is in until an admin configures
    ///      one, so an upgrade that ships this changes nothing on its own.
    function test_noKeeperMeansNoFee() public {
        registry.registerRoute(DAI, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);
        assertEq(address(registry).balance, 0, "nothing was withheld");
    }

    /// @dev The clip is what keeps "flat" from breaking on a conversion smaller than the fee: without it
    ///      the swap would be handed nothing and revert, bricking the dust path the staleness bypass
    ///      exists for.
    function test_theFeeIsClippedOnATinyConversion() public {
        registry.registerRoute(DAI, V2_ROUTE);
        address keeper = makeAddr("keeper");
        vm.prank(admin);
        registry.setKeeperFunding(keeper);

        // Small enough that the ceiling bites: 20% of this is below `KEEPER_FEE`.
        uint256 tiny = (registry.KEEPER_FEE() * 10_000) / registry.MAX_KEEPER_CUT_BPS() / 2;
        vm.deal(address(this), tiny);
        uint256 out = registry.swapNativeToAsset{value: tiny}(DAI, 1, recipient);

        assertEq(keeper.balance, tiny * registry.MAX_KEEPER_CUT_BPS() / 10_000, "clipped to the ceiling");
        assertLt(keeper.balance, registry.KEEPER_FEE(), "the keeper ate the difference");
        assertGt(out, 0, "and the conversion still happened");
    }

    function test_theKeeperWalletIsAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setKeeperFunding(makeAddr("keeper"));
    }

    function test_swapRevertsWithNothingToSwap() public {
        vm.expectRevert(RealmDividendSwapRegistry.NothingToSwap.selector);
        registry.swapNativeToAsset(DAI, 1, recipient);
    }

    //////////////////////// V4 routes //////////////////////

    /// @dev A route BYPASSES the V2 depth test entirely: the creator named the pools, so there is nothing
    ///      for the registry to measure against a threshold. Shown by making the V2 test impossible to
    ///      pass and watching the routed asset sail through anyway.
    function test_aRoutedAssetIgnoresTheV2DepthTest() public {
        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, type(uint128).max);
        assertEq(uint8(registry.validateRoute(USDC, V2_ROUTE)), uint8(SwapRejection.InsufficientLiquidity));

        assertEq(
            uint8(registry.validateRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10))),
            uint8(SwapRejection.OK),
            "the route is the eligibility"
        );
    }

    /// @dev A route ADMITS; it never overrides the veto.
    function test_aRoutedAssetIsStillRefusedWhenBlacklisted() public {
        registry.registerRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10));

        vm.prank(admin);
        registry.setBlacklisted(USDC, true);

        (bool ok, SwapRejection why) = registry.checkSwapSupported(address(this), USDC);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    /// @dev The single-hop shape: an asset that DOES have a native V4 pool, bought through it rather
    ///      than through V2.
    function test_aSingleHopRouteBuysTheAssetOnV4() public {
        registry.registerRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(USDC, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(USDC).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(USDC).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev THE xStock SHAPE. The asset has no native pool of its own, so the route goes through an
    ///      intermediate — USDC here, USDG on Robinhood Chain — and the swap is still one call.
    function test_aTwoHopRouteReachesAnAssetWithNoNativePool() public {
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: USDC, fee: V4_FEE_005, tickSpacing: V4_SPACING_10, hooks: address(0)});
        hops[1] = Hop({currency: USDT, fee: V4_FEE_001, tickSpacing: V4_SPACING_1, hooks: address(0)});
        registry.registerRoute(USDT, DividendRouteLib.encodeV4(hops));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(USDT, 1, recipient);

        assertGt(out, 0, "bought something two pools away");
        assertEq(IERC20(USDT).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(USDT).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(IERC20(USDC).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev The floor is the keeper's protection and it is the ROUTER that enforces it. A route does not
    ///      soften it just because its pools validated.
    function test_aRoutedSwapStillHonoursTheFloor() public {
        registry.registerRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(USDC, 1_000_000e6, recipient);
    }

    /// @dev A partial fill must FAIL the conversion, not book it. `SETTLE_ALL` settles what the swap
    ///      actually took, so the unspent native stays in the router — unrefunded, sweepable by anyone —
    ///      while the token has already debited the full spend from its dividend buffer. Refusing it
    ///      leaves the caller exactly the state it assumes after a failed swap: buffer intact, native
    ///      returned, retry next call. The real-pool route tests above are the full-fill control.
    function test_aPartialV4FillIsRefusedInsteadOfStrandingTheRest() public {
        registry.registerRoute(USDC, _v4(USDC, V4_FEE_005, V4_SPACING_10));

        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialFillV4RouterStub()).code);
        deal(USDC, router, 1000e6);

        vm.deal(address(this), 1 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(USDC, 1, recipient);

        assertEq(address(this).balance, balanceBefore, "the native never left the caller");
        assertEq(IERC20(USDC).balanceOf(recipient), 0, "and nothing was delivered on a half-spent swap");
    }

    //////////////////////// access control //////////////////////

    /// @dev Two tiers: the owner is a cold key that manages admins and upgrades; admins do the frequent,
    ///      operational work. Neither tier can be reached by anyone else — and neither can admit an
    ///      asset, only refuse one.
    function test_onlyTheOwnerManagesAdmins() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        registry.setAdmin(stranger, true);

        vm.prank(owner);
        registry.setAdmin(stranger, true);
        assertTrue(registry.isAdmin(stranger), "the owner can");
    }

    function test_strangersCannotTouchEntries() public {
        vm.startPrank(stranger);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setBlacklisted(DAI, true);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setDefaultThreshold(1);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setAllowedQuoteToken(USDC, true);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setQuoteTokenThreshold(weth, 1);
        vm.stopPrank();
    }

    /// @dev The owner is an admin implicitly, so a deployment is usable before any admin is appointed.
    function test_theOwnerCanActAsAnAdmin() public {
        vm.prank(owner);
        registry.setAllowedQuoteToken(USDC, true);
        assertTrue(registry.isAllowedQuoteToken(USDC));
    }

    function test_thresholdCannotBeZeroed() public {
        vm.prank(admin);
        vm.expectRevert(RealmDividendSwapRegistry.ZeroThreshold.selector);
        registry.setDefaultThreshold(0);
    }

    /// @dev The chain's own quote currency is allowed from the start, so the first token created after a
    ///      deployment does not need an admin transaction to name a payout asset.
    function test_theNativeQuoteIsAllowedOutOfTheBox() public view {
        assertTrue(registry.isAllowedQuoteToken(weth));
        assertEq(registry.defaultThreshold(), DEFAULT_DIVIDEND_POOL_LIQUIDITY);
    }

    //////////////////////// helpers //////////////////////

    function _v4(address currency, uint24 fee, int24 tickSpacing) internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: currency, fee: fee, tickSpacing: tickSpacing, hooks: address(0)});
        return DividendRouteLib.encodeV4(hops);
    }

    function _expectRejected(SwapRejection why) internal {
        vm.expectRevert(abi.encodeWithSelector(RealmDividendSwapRegistry.RouteRejected.selector, why));
    }
}
