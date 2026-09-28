// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {installDividendSwapRegistry} from "test/helpers/DividendRegistryHelpers.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolSeeding} from "test/helpers/V4PoolSeeding.sol";

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

/// @notice The swap venue for third-asset dividends, and the one place their routes live: each token's
///         own, registered at creation, repointable by an admin per token or for every token at once.
/// @dev This test contract stands in for a TOKEN throughout: it converts exactly as a clone does.
contract RealmDividendSwapRegistryTests is V4PoolSeeding {
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

    /// @dev A route through the asset's V2 pair with the native quote.
    bytes internal constant V2_ROUTE = hex"02";

    RealmDividendSwapRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);

        vm.prank(owner);
        registry.setAdmin(admin, true);
    }

    //////////////////////// routes //////////////////////

    /// @dev ANY ASSET, NO ROUTE: nothing converts until an admin sets one, and nothing about the asset is
    ///      checked beyond that.
    function test_anAssetWithoutARouteDoesNotConvert() public {
        address ghost = address(new Ghost());
        assertEq(registry.routeOf(address(0), ghost).length, 0, "no route by default");
        vm.deal(address(this), 1 ether);
        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapNativeToAsset{value: 1 ether}(ghost, 1, recipient);
    }

    /// @dev The `ALL_TOKENS` override is shared by every caller: whoever converts MSFT converts it the same way.
    function test_theOverrideServesEveryCaller() public {
        _set(MSFT, V2_ROUTE);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        assertGt(registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, stranger), 0, "a caller that set nothing");
    }

    /// @dev A wrong or dead route is repointed once, for everyone.
    function test_aRouteCanBeRepointed() public {
        _set(AAPL, _v4(AAPL, 3_000, 60)); // a pool nobody initialized: shape is fine, the swap is not
        vm.deal(address(this), 0.02 ether);
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.01 ether}(AAPL, 1, recipient);

        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        assertGt(registry.swapNativeToAsset{value: 0.01 ether}(AAPL, 1, recipient), 0, "converts after repointing");
    }

    /// @dev Clearing is the veto: the asset stops converting for every token paying it.
    function test_clearingARouteStopsConversions() public {
        _set(MSFT, V2_ROUTE);
        _set(MSFT, "");
        vm.deal(address(this), 1 ether);
        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);
    }

    function test_everyRouteChangeIsAnnounced() public {
        bytes memory route = _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL);
        vm.expectEmit(true, false, false, true, address(registry));
        emit RealmDividendSwapRegistry.DividendRouteSet(address(0), AAPL, false, route);
        _set(AAPL, route);
        assertEq(registry.routeOf(address(0), AAPL), route, "stored as given");
    }

    /// @dev Shape only, no liquidity read: a route set for the wrong asset or with a garbled body is
    ///      refused; whether its pools can deliver is the fork probe's job before listing.
    function test_aMalformedRouteIsRefused() public {
        vm.startPrank(admin);
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.setRoute(address(0), MSFT, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL)); // ends at AAPL

        Hop[] memory tooLong = new Hop[](registry.MAX_ROUTE_HOPS() + 1);
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = Hop({currency: address(uint160(i + 1)), fee: 3_000, tickSpacing: 60, hooks: address(0)});
        }
        tooLong[tooLong.length - 1].currency = AAPL;
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.setRoute(address(0), AAPL, DividendRouteLib.encodeV4(tooLong));

        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.setRoute(address(0), MSFT, hex"07"); // unknown venue tag
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.setRoute(address(0), MSFT, hex"0200"); // V2 carries no body
        vm.stopPrank();
    }

    //////////////////////// per-token routes //////////////////////

    /// @dev A token's own route serves that token only: another caller has none.
    function test_aTokenRegistersItsOwnRoute() public {
        vm.expectEmit(address(registry));
        emit RealmDividendSwapRegistry.DividendRouteRegistered(address(this), MSFT, false, V2_ROUTE);
        registry.registerRoute(MSFT, V2_ROUTE);
        assertEq(registry.routeOf(address(this), MSFT), V2_ROUTE, "stored against the caller");

        vm.deal(address(this), 1 ether);
        assertGt(registry.swapNativeToAsset{value: 0.5 ether}(MSFT, 1, recipient), 0, "the token converts");

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, stranger);
    }

    /// @dev Write-once: after creation only an admin changes a token's route.
    function test_registrationIsWriteOnce() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        vm.expectRevert(RealmDividendSwapRegistry.RouteAlreadyRegistered.selector);
        registry.registerRoute(MSFT, V2_ROUTE);
    }

    /// @dev Shape only: an asset with no pool at all is accepted; a garbled or empty route is not.
    function test_registrationChecksShapeOnly() public {
        address ghost = address(new Ghost());
        registry.registerRoute(ghost, V2_ROUTE); // no pair exists
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.registerRoute(MSFT, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL)); // ends at AAPL
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.registerRoute(AAPL, "");
    }

    /// @dev An admin repoints ONE token's route without touching anyone else's.
    function test_anAdminRepointsOneTokensRoute() public {
        registry.registerRoute(AAPL, _v4(AAPL, 3_000, 60)); // a pool nobody initialized
        vm.prank(stranger);
        registry.registerRoute(AAPL, _v4(AAPL, 3_000, 60));

        vm.expectEmit(address(registry));
        emit RealmDividendSwapRegistry.DividendRouteSet(
            address(this), AAPL, false, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL)
        );
        vm.prank(admin);
        registry.setRoute(address(this), AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

        vm.deal(address(this), 0.01 ether);
        assertGt(registry.swapNativeToAsset{value: 0.01 ether}(AAPL, 1, recipient), 0, "repointed token converts");
        assertEq(registry.routeOf(stranger, AAPL), _v4(AAPL, 3_000, 60), "the other token's route is untouched");
    }

    /// @dev The override wins over every token's own route, and clearing it hands each its own back.
    function test_theOverrideWinsUntilCleared() public {
        registry.registerRoute(MSFT, V2_ROUTE);
        _set(MSFT, _v4(MSFT, 3_000, 60));
        assertEq(registry.routeOf(address(this), MSFT), _v4(MSFT, 3_000, 60), "override first");
        _set(MSFT, "");
        assertEq(registry.routeOf(address(this), MSFT), V2_ROUTE, "own route again");
    }

    /// @dev Only a V4 route can be walked backwards, so a quote route is V4 or nothing.
    function test_aQuoteRouteMustBeV4() public {
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.registerQuoteRoute(AAPL, V2_ROUTE);
        vm.prank(admin);
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
        registry.setQuoteRoute(address(this), AAPL, V2_ROUTE);

        registry.registerQuoteRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        assertEq(registry.quoteRouteOf(address(this), AAPL), _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
    }

    /// @dev Resolution: quote override, else the token's quote route, else the buy route.
    function test_quoteRouteResolution() public {
        bytes memory buy = _v4(AAPL, 3_000, 60);
        bytes memory own = _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL);
        bytes memory all = _v4(AAPL, 10_000, 200);
        registry.registerRoute(AAPL, buy);
        assertEq(registry.quoteRouteOf(address(this), AAPL), buy, "falls back to the buy route");
        registry.registerQuoteRoute(AAPL, own);
        assertEq(registry.quoteRouteOf(address(this), AAPL), own, "own quote route");
        vm.prank(admin);
        registry.setQuoteRoute(address(0), AAPL, all);
        assertEq(registry.quoteRouteOf(address(this), AAPL), all, "override");
    }

    //////////////////////// the swap //////////////////////

    function test_swapDeliversToTheRecipientAndKeepsNothing() public {
        _set(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(MSFT).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(MSFT).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(address(registry).balance, 0, "and no native");
    }

    function test_swapRevertsOnAMissedFloor() public {
        _set(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1_000_000e18, recipient);
    }

    /// @dev The keeper is paid a FLAT fee out of every conversion — gas is an absolute cost — and only
    ///      what is left is swapped. The registry still keeps nothing: the fee rests here for the length
    ///      of the call and no longer.
    function test_theKeeperIsFundedOutOfEveryConversion() public {
        _set(MSFT, V2_ROUTE);
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
        _set(MSFT, V2_ROUTE);
        vm.deal(address(this), 1 ether);
        registry.swapNativeToAsset{value: 1 ether}(MSFT, 1, recipient);
        assertEq(address(registry).balance, 0, "nothing was withheld");
    }

    /// @dev The clip is what keeps "flat" from breaking on a conversion smaller than the fee: without it
    ///      the swap would be handed nothing and revert on a keeper's small slice.
    function test_theFeeIsClippedOnATinyConversion() public {
        _set(MSFT, V2_ROUTE);
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

    /// @dev The single-hop shape: an asset that DOES have a native V4 pool, bought through it rather
    ///      than through V2.
    function test_aSingleHopRouteBuysTheAssetOnV4() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

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
        _seedAaplTslaPool();
        _set(TSLA, DividendRouteLib.encodeV4(hops));

        // Sized for AAPL's thin native pool: 1 ETH part-fills it (see the single-hop AAPL test).
        vm.deal(address(this), 0.01 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.01 ether}(TSLA, 1, recipient);

        assertGt(out, 0, "bought something two pools away");
        assertEq(IERC20(TSLA).balanceOf(recipient), out, "the recipient got exactly what was reported");
        assertEq(IERC20(TSLA).balanceOf(address(registry)), 0, "the registry kept no asset");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "and no native");
    }

    /// @dev The floor is the keeper's protection and it is the ROUTER that enforces it. A route does not
    ///      soften it just because its pools validated.
    function test_aRoutedSwapStillHonoursTheFloor() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

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
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));

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
    ///      operational work. Neither tier can be reached by anyone else.
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
        registry.setRoute(address(0), MSFT, V2_ROUTE);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setKeeperFunding(stranger);
        vm.stopPrank();
    }

    /// @dev The owner is an admin implicitly, so a deployment is usable before any admin is appointed.
    function test_theOwnerCanActAsAnAdmin() public {
        vm.prank(owner);
        registry.setRoute(address(0), MSFT, V2_ROUTE);
        assertEq(registry.routeOf(address(0), MSFT), V2_ROUTE);
    }

    //////////////////////// swapAssetToAsset //////////////////////

    /// @dev A quote's route walked backwards and the payout asset's forward: AAPL -> native on the V4
    ///      pool, native -> MSFT on the V2 pair. The registry ends the call holding nothing of either.
    function test_swapAssetToAsset_pivotsThroughNative() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        _set(MSFT, V2_ROUTE);
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
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
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
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        _set(MSFT, V2_ROUTE);
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
        _set(MSFT, V2_ROUTE);
        _set(AAPL, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1, recipient);
    }

    /// @dev F1: a quote bought on V2 as a payout asset is still sold on its own V4 quote route.
    function test_swapAssetToAsset_sellsThroughTheQuoteRouteNotTheBuyRoute() public {
        registry.registerRoute(AAPL, V2_ROUTE);
        registry.registerQuoteRoute(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        assertGt(registry.swapAssetToAsset(AAPL, address(0), 1e16, 1, recipient), 0, "sold on V4");
    }

    /// @dev The floor is on the FINAL asset, however many pools the conversion crossed.
    function test_swapAssetToAsset_enforcesTheFloorOnTheFinalAsset() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        _set(MSFT, V2_ROUTE);
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
        _seedAaplTslaPool();
        _set(TSLA, DividendRouteLib.encodeV4(hops));
        deal(TSLA, address(this), 1e16);
        // TSLA's `approve` returns nothing, which a plain `IERC20.approve` call cannot decode.
        SafeERC20.forceApprove(IERC20(TSLA), address(registry), 1e16);

        uint256 before = recipient.balance;
        uint256 out = registry.swapAssetToAsset(TSLA, address(0), 1e16, 1, recipient);

        assertEq(recipient.balance - before, out, "native delivered");
        // The AAPL/TSLA leg is a seeded 1:1 pool, so no price floor here means anything; filling is the test.
        assertGt(out, 0, "the TSLA crossed both pools");
        assertEq(IERC20(TSLA).balanceOf(address(this)), 0, "the source was consumed whole");
        assertEq(IERC20(TSLA).balanceOf(address(registry)), 0, "the registry kept no source");
        assertEq(IERC20(AAPL).balanceOf(address(registry)), 0, "nor any of the intermediate");
        assertEq(address(registry).balance, 0, "nor any native");
    }

    /// @dev Nothing to swap, no source, or a source that already IS the asset: refused before any pull.
    function test_swapAssetToAsset_refusesDegenerateInputs() public {
        vm.expectRevert(RealmDividendSwapRegistry.NothingToSwap.selector);
        registry.swapAssetToAsset(AAPL, MSFT, 0, 1, recipient);

        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapAssetToAsset(address(0), MSFT, 1e16, 1, recipient);

        vm.expectRevert(RealmDividendSwapRegistry.NoRoute.selector);
        registry.swapAssetToAsset(AAPL, AAPL, 1e16, 1, recipient);
    }

    /// @dev A partial fill of the reverse leg fails the conversion. Permit2 pulls only what the swap owed,
    ///      so the unsold source would stay HERE, where nothing can sweep it, while the calling token books
    ///      the whole `amountIn` as spent.
    function test_swapAssetToAsset_refusesAPartiallyFilledSourceLeg() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
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
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);
        address refuser = address(new Ghost()); // no `receive()`

        vm.expectRevert(RealmDividendSwapRegistry.NativeDeliveryFailed.selector);
        registry.swapAssetToAsset(AAPL, address(0), 1e16, 0, refuser);
        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "the source never left");
    }

    /// @dev No liquidity gate runs at conversion: a source pool drained after listing simply fails the
    ///      swap, and the source goes back whole.
    function test_swapAssetToAsset_aDrainedSourcePoolFailsTheSwap() public {
        _set(AAPL, _v4(AAPL, V4_FEE_AAPL, V4_SPACING_AAPL));
        _set(MSFT, V2_ROUTE);
        deal(AAPL, address(this), 1e16);
        IERC20(AAPL).approve(address(registry), 1e16);

        // Zero the pool's in-range liquidity.
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

        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapAssetToAsset(AAPL, MSFT, 1e16, 1, recipient);
        assertEq(IERC20(AAPL).balanceOf(address(this)), 1e16, "the source never left");
    }

    //////////////////////// helpers //////////////////////

    function _v4(address currency, uint24 fee, int24 tickSpacing) internal pure returns (bytes memory) {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: currency, fee: fee, tickSpacing: tickSpacing, hooks: address(0)});
        return DividendRouteLib.encodeV4(hops);
    }

    /// @dev The hookless AAPL/TSLA pool the two-hop tests cross. Robinhood has no native -> X -> Y V4
    ///      chain with liquidity at `BLOCKNUMBER`, so the second leg is built here, 1:1.
    function _seedAaplTslaPool() internal {
        _seedV4Pool(
            IPoolManager(DeploymentAddresses.UNIV4_POOL_MANAGER), AAPL, TSLA, V4_FEE_TSLA, V4_SPACING_TSLA, 1e22
        );
    }

    function _set(address asset, bytes memory route) internal {
        vm.prank(admin);
        registry.setRoute(address(0), asset, route);
    }
}
