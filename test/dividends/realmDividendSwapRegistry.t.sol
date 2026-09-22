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
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {installDividendSwapRegistry, DEFAULT_DIVIDEND_POOL_LIQUIDITY} from "test/helpers/DividendRegistryHelpers.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

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
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        (bool spent,) = SINK.call{value: msg.value / 2}("");
        require(spent, "sink failed");
        IERC20(AAPL).transfer(msg.sender, 1e18);
    }
}

/// @notice Stand-in for the universal router on a PARTIAL fill of the REVERSE leg: Permit2 pulls only half
///         the source straight from the caller into the pool (here a sink), and the native side pays for
///         that half. Nothing lands in the router, so only the caller's own balance shows the shortfall.
contract PartialPullV4RouterStub {
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        IAllowanceTransfer(PERMIT2).transferFrom(msg.sender, SINK, 500e18, AAPL);
        (bool paid,) = msg.sender.call{value: 0.1 ether}("");
        require(paid, "pay failed");
    }
}

/// @notice The swap venue for third-asset dividends, and the keeper of the route each token registered.
///         The rule it enforces is deliberately permissionless — Realm does not review payout assets and
///         has no allowlist of them — so most of what is asserted here is what nobody needs permission
///         for, and what the one remaining admin lever CANNOT do.
/// @dev This test contract stands in for a TOKEN throughout: routes are keyed by the caller, so
///      `address(this)` registering a route and then converting is exactly the shape a clone has.
contract RealmDividendSwapRegistryTests is Test {
    uint256 internal constant BLOCKNUMBER = 58_000_000;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    /// @dev The Robinhood V4 pools the route tests cross, live at `BLOCKNUMBER`. AAPL's native pool is
    ///      the one hookless, static-fee pool on this chain that actually holds liquidity there.
    uint24 internal constant V4_FEE_AAPL = 8_000;
    int24 internal constant V4_SPACING_AAPL = 80;
    uint24 internal constant V4_FEE_TSLA = 50_000;
    int24 internal constant V4_SPACING_TSLA = 1_000;

    /// @dev The V2 depth floor these tests run at. Robinhood's xStock/WETH pairs hold ~0.005 ETH a
    ///      side, far under the shipped default of 10x MAX_EARNINGS_PER_PROCESS, so the suite lowers the
    ///      floor in `setUp` and every depth assertion below is relative to THIS value.
    uint256 internal constant V2_DEPTH_FLOOR = 0.001 ether;

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
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);
        weth = registry.nativeQuoteToken();

        vm.prank(owner);
        registry.setAdmin(admin, true);

        // Robinhood's xStock/WETH V2 pairs hold ~0.005 ETH a side, under the default depth floor of
        // 10x MAX_EARNINGS_PER_PROCESS. The floor is per-chain configurable; drop it so "a deep enough
        // pair" means something on this chain's real liquidity.
        vm.prank(admin);
        registry.setDefaultThreshold(V2_DEPTH_FLOOR);
    }

    //////////////////////// the rule //////////////////////

    /// @dev The whole eligibility rule for an unrouted asset: liquidity, measured live, with nobody's
    ///      approval. An asset the admins have never heard of passes as readily as one they have.
    function test_anyAssetWithADeepPairQualifiesUnprompted() public view {
        assertEq(uint8(registry.validateRoute(MSFT, V2_ROUTE)), uint8(SwapRejection.OK), "MSFT");
        assertEq(uint8(registry.validateRoute(AAPL, V2_ROUTE)), uint8(SwapRejection.OK), "AAPL");
    }

    /// @dev NOBODY IS ASKED. Registration is open to any caller, because the caller is always the token
    ///      committing itself. If this ever needs a role, the feature has quietly become a curated list.
    function test_anyoneMayRegisterARouteForThemselves() public {
        vm.prank(stranger);
        registry.registerRoute(MSFT, V2_ROUTE);

        (bool ok,) = registry.checkSwapSupported(stranger, MSFT);
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

        uint256 seeded = V2_DEPTH_FLOOR / 2;
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
        registry.setBlacklisted(MSFT, true);

        assertEq(uint8(registry.validateRoute(MSFT, V2_ROUTE)), uint8(SwapRejection.Blacklisted));
    }

    /// @dev A per-quote override beats the default in both directions.
    function test_aPerQuoteThresholdOverridesTheDefault() public {
        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, type(uint128).max);
        assertEq(
            uint8(registry.validateRoute(MSFT, V2_ROUTE)),
            uint8(SwapRejection.InsufficientLiquidity),
            "the override refuses what the default allowed"
        );

        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, 0);
        assertEq(uint8(registry.validateRoute(MSFT, V2_ROUTE)), uint8(SwapRejection.OK), "clearing it falls back");
    }

    function test_anUnlistedQuoteTokenIsRefused() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(weth, false);
        assertEq(uint8(registry.validateRoute(MSFT, V2_ROUTE)), uint8(SwapRejection.QuoteNotAllowed));
    }

    //////////////////////// registration //////////////////////

    /// @dev WRITE-ONCE. A route the creator could rewrite later would be a rug lever: point the token at
    ///      a pool you control the day before a big conversion. Creation runs once, so nothing legitimate
    ///      ever calls this twice.
    function test_aRouteCannotBeRewritten() public {
        registry.registerRoute(MSFT, V2_ROUTE);

        vm.expectRevert(RealmDividendSwapRegistry.RouteAlreadyRegistered.selector);
        registry.registerRoute(MSFT, _v4(MSFT, V4_FEE_AAPL, V4_SPACING_AAPL));
    }

    /// @dev The empty route is a REAL registration, not an absent one — which is why the write-once
    ///      guard is a separate flag rather than a test on the stored bytes.
    function test_theEmptyRouteIsARegistrationOfItsOwn() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        assertEq(registry.routeOf(address(this), MSFT).length, 0, "stored as empty");
        assertTrue(registry.routeRegistered(address(this), MSFT), "but registered all the same");
    }

    /// @dev Two tokens naming the same asset carry their own routes. One creator's bad choice cannot
    ///      reach another creator's holders, and nobody can grief a popular asset globally.
    function test_routesAreScopedToTheTokenThatRegisteredThem() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        vm.prank(stranger);
        registry.registerRoute(AAPL, V2_ROUTE);

        assertGt(registry.routeOf(address(this), AAPL).length, 0, "ours is the V4 route");
        assertEq(registry.routeOf(stranger, AAPL).length, 0, "theirs is the V2 pair");
    }

    /// @dev A route whose last hop buys something else would leave the swap unable to take what it was
    ///      told to take. Caught where it is cheap to catch instead of at the next freeze.
    function test_aRouteMustEndAtTheAsset() public {
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(MSFT, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
    }

    function test_aRouteLongerThanTheCapIsRefused() public {
        Hop[] memory hops = new Hop[](registry.MAX_ROUTE_HOPS() + 1);
        for (uint256 i; i < hops.length; ++i) {
            hops[i] = Hop({currency: MSFT, fee: V4_FEE_AAPL, tickSpacing: V4_SPACING_AAPL, hooks: address(0)});
        }
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(MSFT, DividendRouteLib.encodeV4(hops));
    }

    function test_anUnknownVenueTagIsRefusedRatherThanTreatedAsV2() public {
        _expectRejected(SwapRejection.MalformedRoute);
        registry.registerRoute(MSFT, hex"07deadbeef");
    }

    /// @dev THE TYPO GATE, and the reason registration validates at all. A fee/tickSpacing/hooks
    ///      combination nobody ever initialized is indistinguishable from the right pool until the pool
    ///      manager is asked. Without this the mistake would surface at some future `processDividends`,
    ///      on a clone nobody can patch, and there is no second chance to fix the route.
    function test_aRouteNamingAPoolThatWasNeverInitializedIsRefused() public {
        _expectRejected(SwapRejection.DeadPool);
        registry.registerRoute(AAPL, _v4(AAPL, 3000, int24(199)));
    }

    /// @dev The precheck a frontend runs before a token exists: same answer, no state, no caller.
    function test_validateRouteAnswersWithoutATokenAtAll() public view {
        assertEq(uint8(registry.validateRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL))), uint8(SwapRejection.OK));
        assertEq(uint8(registry.validateRoute(AAPL, _v4(AAPL, 3000, int24(199)))), uint8(SwapRejection.DeadPool));
    }

    //////////////////////// the swap //////////////////////

    function test_swapDeliversToTheRecipientAndKeepsNothing() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(MSFT).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(MSFT).balanceOf(address(registry)), 0, "the registry kept no asset");
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
        registry.registerRoute(MSFT, V2_ROUTE);
        vm.prank(admin);
        registry.setBlacklisted(MSFT, true);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.Blacklisted)
        );
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);
    }

    function test_swapRevertsOnAMissedFloor() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1_000_000e18, recipient);
    }

    /// @dev The keeper is paid a FLAT fee out of every conversion — gas is an absolute cost — and only
    ///      what is left is swapped. The registry still keeps nothing: the fee rests here for the length
    ///      of the call and no longer.
    function test_theKeeperIsFundedOutOfEveryConversion() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        address keeper = makeAddr("keeper");
        uint256 fee = registry.KEEPER_FEE();
        vm.prank(admin);
        registry.setKeeperFunding(keeper);

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);

        assertEq(keeper.balance, fee, "the keeper took its flat fee");
        assertEq(IERC20(MSFT).balanceOf(recipient), out, "the recipient got the rest, converted");
        assertEq(address(registry).balance, 0, "and the registry kept no native");

        // Ten times the conversion size, same fee: the whole point of flat over percentage.
        vm.deal(address(this), 10 ether);
        registry.swapNativeToAsset{value: 10 ether}(MSFT, 1, recipient);
        assertEq(keeper.balance, 2 * fee, "a ten-times-larger conversion pays the same fee");
    }

    /// @dev No keeper wallet, no fee — which is the state every registry is in until an admin configures
    ///      one, so an upgrade that ships this changes nothing on its own.
    function test_noKeeperMeansNoFee() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);
        assertEq(address(registry).balance, 0, "nothing was withheld");
    }

    /// @dev The clip is what keeps "flat" from breaking on a conversion smaller than the fee: without it
    ///      the swap would be handed nothing and revert, bricking the dust path the staleness bypass
    ///      exists for.
    function test_theFeeIsClippedOnATinyConversion() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        address keeper = makeAddr("keeper");
        vm.prank(admin);
        registry.setKeeperFunding(keeper);

        // Small enough that the ceiling bites: 20% of this is below `KEEPER_FEE`.
        uint256 tiny = (registry.KEEPER_FEE() * 10_000) / registry.MAX_KEEPER_CUT_BPS() / 2;
        vm.deal(address(this), tiny);
        uint256 out = registry.swapNativeToAsset{value: tiny}(MSFT, 1, recipient);

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
        registry.swapNativeToAsset(MSFT, 1, recipient);
    }

    //////////////////////// V4 routes //////////////////////

    /// @dev A route BYPASSES the V2 depth test entirely: the creator named the pools, so there is nothing
    ///      for the registry to measure against a threshold. Shown by making the V2 test impossible to
    ///      pass and watching the routed asset sail through anyway.
    function test_aRoutedAssetIgnoresTheV2DepthTest() public {
        vm.prank(admin);
        registry.setQuoteTokenThreshold(weth, type(uint128).max);
        assertEq(uint8(registry.validateRoute(AAPL, V2_ROUTE)), uint8(SwapRejection.InsufficientLiquidity));

        assertEq(
            uint8(registry.validateRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL))),
            uint8(SwapRejection.OK),
            "the route is the eligibility"
        );
    }

    /// @dev A route ADMITS; it never overrides the veto.
    function test_aRoutedAssetIsStillRefusedWhenBlacklisted() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

        vm.prank(admin);
        registry.setBlacklisted(AAPL, true);

        (bool ok, SwapRejection why) = registry.checkSwapSupported(address(this), AAPL);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    /// @dev The single-hop shape: an asset that DOES have a native V4 pool, bought through it rather
    ///      than through V2.
    function test_aSingleHopRouteBuysTheAssetOnV4() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

        vm.deal(address(this), 0.01 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.01 ether}(AAPL, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(AAPL).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev THE xStock SHAPE. The asset has no native pool of its own, so the route goes through an
    ///      intermediate — AAPL here, USDG on Robinhood Chain — and the swap is still one call.
    function test_aTwoHopRouteReachesAnAssetWithNoNativePool() public {
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: AAPL, fee: V4_FEE_AAPL, tickSpacing: V4_SPACING_AAPL, hooks: address(0)});
        hops[1] = Hop({currency: TSLA, fee: V4_FEE_TSLA, tickSpacing: V4_SPACING_TSLA, hooks: address(0)});
        registry.registerRoute(TSLA, DividendRouteLib.encodeV4(hops));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(TSLA, 1, recipient);

        assertGt(out, 0, "bought something two pools away");
        assertEq(IERC20(TSLA).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(TSLA).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev The floor is the keeper's protection and it is the ROUTER that enforces it. A route does not
    ///      soften it just because its pools validated.
    function test_aRoutedSwapStillHonoursTheFloor() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(AAPL, 1_000_000e18, recipient);
    }

    /// @dev A partial fill must FAIL the conversion, not book it. `SETTLE_ALL` settles what the swap
    ///      actually took, so the unspent native stays in the router — unrefunded, sweepable by anyone —
    ///      while the token has already debited the full spend from its dividend buffer. Refusing it
    ///      leaves the caller exactly the state it assumes after a failed swap: buffer intact, native
    ///      returned, retry next call. The real-pool route tests above are the full-fill control.
    function test_aPartialV4FillIsRefusedInsteadOfStrandingTheRest() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialFillV4RouterStub()).code);
        deal(AAPL, router, 1000e18);

        vm.deal(address(this), 1 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(AAPL, 1, recipient);

        assertEq(address(this).balance, balanceBefore, "the native never left the caller");
        assertEq(IERC20(AAPL).balanceOf(recipient), 0, "and nothing was delivered on a half-spent swap");
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
        registry.setBlacklisted(MSFT, true);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setDefaultThreshold(1);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setAllowedQuoteToken(AAPL, true);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setQuoteTokenThreshold(weth, 1);
        vm.stopPrank();
    }

    /// @dev The owner is an admin implicitly, so a deployment is usable before any admin is appointed.
    function test_theOwnerCanActAsAnAdmin() public {
        vm.prank(owner);
        registry.setAllowedQuoteToken(AAPL, true);
        assertTrue(registry.isAllowedQuoteToken(AAPL));
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
        assertEq(registry.defaultThreshold(), V2_DEPTH_FLOOR);
    }

    //////////////////////// swapAssetToAsset //////////////////////

    /// @dev A quote's route walked backwards and the payout asset's forward: AAPL -> native on the V4
    ///      pool, native -> MSFT on the V2 pair. The registry ends the call holding nothing of either.
    function test_swapAssetToAsset_pivotsThroughNative() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        registry.registerRoute(MSFT, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        uint256 out = registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1, recipient);

        // No parity to assert here, unlike the stablecoin pair this replaced: AAPL and MSFT are
        // separately priced stocks, so all the pivot promises is that both legs filled.
        assertGt(out, 0, "the pivot delivered MSFT");
        assertEq(IERC20(MSFT).balanceOf(recipient), out, "delivered to the recipient");
        assertEq(IERC20(AAPL).balanceOf(address(this)), 0, "the source was consumed whole");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "the registry kept no source");
        assertEq(address(registry).balance, 0, "nor any native");
    }

    /// @dev Native as the destination is the reverse leg alone; the floor applies to it directly.
    function test_swapAssetToAsset_deliversNativeWhenAskedFor() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        uint256 before = recipient.balance;
        uint256 out = registry.swapAssetToAsset(AAPL, address(0), 1e16, 0.001 ether, recipient);

        assertEq(recipient.balance - before, out, "native delivered");
        assertGt(out, 0.001 ether, "the floor held");
        assertEq(address(registry).balance, 0, "nothing withheld");
    }

    /// @dev The keeper is funded from the native in the MIDDLE of the conversion, so an ERC20 source
    ///      pays it exactly as a native one does — nothing but native ever rests here for it.
    function test_swapAssetToAsset_fundsTheKeeperInNative() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        registry.registerRoute(MSFT, V2_ROUTE);
        address keeper = makeAddr("keeper");
        vm.prank(admin);
        registry.setKeeperFunding(keeper);
        deal(AAPL, address(this), 1e17);
        IERC20(AAPL).approve(address(registry), 1e17);

        registry.swapAssetToAsset(AAPL, MSFT, 1e17, 1, recipient);

        assertEq(keeper.balance, registry.KEEPER_FEE(), "the flat fee, in native");
        assertEq(IERC20(AAPL).balanceOf(keeper), 0, "and nothing in the source");
    }

    /// @dev Only a V4 route names its pools outright; a V2 or V3 one cannot be walked backwards.
    function test_swapAssetToAsset_refusesASourceWithoutAV4Route() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        registry.registerRoute(AAPL, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        vm.expectRevert(
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.MalformedRoute)
        );
        registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1, recipient);
    }

    /// @dev The floor is on the FINAL asset, however many pools the conversion crossed.
    function test_swapAssetToAsset_enforcesTheFloorOnTheFinalAsset() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        registry.registerRoute(MSFT, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        vm.expectRevert();
        registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1e18, recipient);
        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "a refused conversion leaves the source whole");
    }

    /// @dev THE xStock SHAPE, BACKWARDS. The source's route is native -> AAPL -> TSLA, so the reverse leg
    ///      runs TSLA -> AAPL on the stable pool and AAPL -> native on the ETH pool: each hop outputs the
    ///      currency BEFORE it, and the last one outputs native. A multi-hop path, so the router's
    ///      `SWAP_EXACT_IN` branch runs rather than the single-pool one.
    function test_swapAssetToAsset_walksAMultiHopSourceRouteBackwards() public {
        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: AAPL, fee: V4_FEE_AAPL, tickSpacing: V4_SPACING_AAPL, hooks: address(0)});
        hops[1] = Hop({currency: TSLA, fee: V4_FEE_TSLA, tickSpacing: V4_SPACING_TSLA, hooks: address(0)});
        registry.registerRoute(TSLA, DividendRouteLib.encodeV4(hops));
        deal(TSLA, address(this), 1e16);
        // TSLA's `approve` returns nothing, which a plain `IERC20.approve` call cannot decode.
        SafeERC20.forceApprove(IERC20(TSLA), address(registry), 1e16);

        uint256 before = recipient.balance;
        uint256 out = registry.swapAssetToAsset(TSLA, address(0), 1e16, 0.1 ether, recipient);

        assertEq(recipient.balance - before, out, "native delivered");
        assertGt(out, 0.1 ether, "a thousand TSLA crossed both pools at a sane price");
        assertEq(IERC20(TSLA).balanceOf(address(this)), 0, "the source was consumed whole");
        assertEq(IERC20(TSLA).balanceOf(address(registry)), 0, "the registry kept no source");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "nor any native");
    }

    /// @dev Nothing to swap, no source, or a source that already IS the asset: refused before any pull.
    function test_swapAssetToAsset_refusesDegenerateInputs() public {
        vm.expectRevert(RealmDividendSwapRegistry.NothingToSwap.selector);
        registry.swapAssetToAsset(AAPL, MSFT, 0, 1, recipient);

        bytes memory malformed =
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.MalformedRoute);
        vm.expectRevert(malformed);
        registry.swapAssetToAsset(address(0), MSFT, 1e16, 1, recipient);

        vm.expectRevert(malformed);
        registry.swapAssetToAsset(AAPL, AAPL, 1e16, 1, recipient);
    }

    /// @dev A partial fill of the reverse leg fails the conversion. Permit2 pulls only what the swap owed,
    ///      so the unsold source would stay HERE, where nothing can sweep it, while the calling token books
    ///      the whole `amountIn` as spent.
    function test_swapAssetToAsset_refusesAPartiallyFilledSourceLeg() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);
        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialPullV4RouterStub()).code);
        vm.deal(router, 1 ether);

        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapAssetToAsset(AAPL, address(0), 1e16, 0, recipient);

        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "the source went back whole");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "and none of it stranded in the registry");
    }

    /// @dev A recipient that refuses native fails the whole conversion rather than leaving the native
    ///      here, and the source goes back with the revert.
    function test_swapAssetToAsset_revertsWhenTheRecipientRefusesNative() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);
        address refuser = address(new Ghost()); // no `receive()`

        vm.expectRevert(RealmDividendSwapRegistry.NativeDeliveryFailed.selector);
        registry.swapAssetToAsset(AAPL, address(0), 1e16, 0, refuser);
        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "the source never left");
    }

    /// @dev The source's route is re-validated on every conversion, as a payout asset's is: a source pool
    ///      drained after registration is refused as dead rather than swapped against.
    function test_swapAssetToAsset_refusesASourcePoolDrainedAfterRegistration() public {
        registry.registerRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        registry.registerRoute(MSFT, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        // Zero the pool's in-range liquidity, which is what `_validateV4` reads.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(AAPL),
            fee: V4_FEE_AAPL,
            tickSpacing: V4_SPACING_AAPL,
            hooks: IHooks(address(0))
        });
        bytes32 state = keccak256(abi.encodePacked(PoolId.unwrap(PoolIdLibrary.toId(key)), StateLibrary.POOLS_SLOT));
        vm.store(
            DeploymentAddresses.UNIV4_POOL_MANAGER, bytes32(uint256(state) + StateLibrary.LIQUIDITY_OFFSET), bytes32(0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(RealmDividendSwapRegistry.SwapNotSupported.selector, SwapRejection.DeadPool)
        );
        registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1, recipient);
        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "the source never left");
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
