// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {SwapRejection} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {installDividendSwapRegistry} from "test/helpers/DividendRegistryHelpers.sol";

/// @notice The curated Uniswap V3 venue, exercised against the real Ondo Global Markets pools — the
///         assets this venue exists for, and the only tokenized equities on Ethereum with usable depth.
///
/// @dev PINNED LATER THAN THE REST OF THE SUITE, on purpose. These pools did not exist at the block the
///      other dividend fork tests use, so this file carries its own.
///
/// @dev The most important test here is `test_aPoolHoldingAlmostNoQuoteTokenIsStillUsable`. A V3
///      position that currently holds only the ASSET and none of the quote token is what a healthy
///      sell-side market maker looks like, and it is exactly the shape a buyer wants — so any gate that
///      judged depth by reading the pool's quote-side balance would reject precisely the pools this
///      venue was added to reach. That test is the regression guard for ever reintroducing one.
interface IWETH9 {
    function deposit() external payable;
}

/// @notice Stand-in for the universal router on a PARTIAL V3 fill. `WRAP_ETH` wraps the whole input up
///         front but the swap consumes only what the pool's liquidity could take, so the unspent WETH
///         stays with the router — unrefunded, sweepable by anyone — while the caller has already
///         debited the full spend.
contract PartialFillV3RouterStub {
    address internal constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        IWETH9(WETH9).deposit{value: msg.value}();
        IERC20(WETH9).transfer(SINK, msg.value / 2); // the half the pool actually took
        IERC20(AAPL).transfer(msg.sender, 1e18);
    }
}

contract RealmDividendSwapRegistryV3Tests is Test {
    uint256 internal constant BLOCKNUMBER = 58_000_000;

    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    /// @dev Robinhood xStocks, the chain's tokenized equities. Single-hop WETH V3 pools.
    address internal constant AAPLon = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant HOODon = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    /// @dev Reachable only through USDG — its WETH V3 pool is empty at the pinned block, which is
    ///      the reason two-hop routes are supported at all.
    address internal constant SPYon = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    uint24 internal constant FEE_005 = 500;
    uint24 internal constant FEE_030 = 3000;
    uint24 internal constant FEE_001 = 100;

    RealmDividendSwapRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);

        vm.prank(owner);
        registry.setAdmin(admin, true);

        // Robinhood's xStock/WETH V2 pairs hold ~0.005 ETH a side, under the shipped default floor.
        vm.prank(admin);
        registry.setDefaultThreshold(0.001 ether);
    }

    /// @dev `token | fee | token`, Uniswap V3's own encoding.
    function _path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function _path(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }

    /// @dev This test contract stands in for the TOKEN: routes are keyed by the caller, so registering
    ///      here and converting here is exactly the shape a clone has.
    function _route(address asset, bytes memory path) internal {
        registry.registerRoute(asset, DividendRouteLib.encodeV3(path));
    }

    function _supported(address asset) internal view returns (bool ok) {
        (ok,) = registry.checkSwapSupported(address(this), asset);
    }

    function _expectRejected(SwapRejection why) internal {
        vm.expectRevert(abi.encodeWithSelector(RealmDividendSwapRegistry.RouteRejected.selector, why));
    }

    //////////////////////// admission //////////////////////

    /// @dev An asset with no V2 pair is refused until a route admits it. The route IS the curation.
    function test_aV3RouteAdmitsAnAssetTheV2TestCannotSee() public {
        assertEq(
            uint8(registry.validateRoute(AAPLon, "")), uint8(SwapRejection.NoPair), "no V2 pair, so refused on its own"
        );

        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        assertTrue(_supported(AAPLon), "the route admits it");
        assertEq(
            registry.routeOf(address(this), AAPLon),
            DividendRouteLib.encodeV3(_path(WETH, FEE_030, AAPLon)),
            "and is readable back"
        );
    }

    /// @dev ⚠️ THE REGRESSION GUARD. The AAPLon/WETH pool holds essentially no WETH — its liquidity is
    ///      single-sided in the asset, which is what a sell-side maker looks like and what a buyer
    ///      wants. Any depth gate that read the quote-side balance would reject it. It converts fine.
    function test_aPoolHoldingAlmostNoQuoteTokenIsStillUsable() public {
        assertLt(IERC20(WETH).balanceOf(0x2323192488E6632840873410bb65B7Ec8DBfAb6f), 0.01 ether, "pool holds ~no WETH");

        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.deal(address(this), 0.005 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1, recipient);
        assertGt(out, 0, "and yet it converts");
        assertEq(IERC20(AAPLon).balanceOf(recipient), out, "delivered in full");
    }

    /// @dev There is no clearing any more. A route is chosen once, by the creator, and is the token's
    ///      venue for life — including when the pool it names dies. That permanence is the cost of
    ///      dropping the review step, and it is why registration validates rather than trusts.
    function test_aRouteCannotBeClearedOrReplaced() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.expectRevert(RealmDividendSwapRegistry.RouteAlreadyRegistered.selector);
        registry.registerRoute(AAPLon, "");
    }

    /// @dev A blacklist still overrides a curated route. The one admin veto outranks the one admin
    ///      admission, or blacklisting a routed asset would do nothing.
    function test_aBlacklistBeatsAV3Route() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.prank(admin);
        registry.setBlacklisted(AAPLon, true);

        (bool ok, SwapRejection why) = registry.checkSwapSupported(address(this), AAPLon);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    //////////////////////// execution //////////////////////

    function test_singleHopConvertsAndTheRegistryKeepsNothing() public {
        _route(HOODon, _path(WETH, FEE_030, HOODon));

        vm.deal(address(this), 0.01 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.01 ether}(HOODon, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(HOODon).balanceOf(recipient), out, "recipient got exactly what was reported");
        assertEq(IERC20(HOODon).balanceOf(address(registry)), 0, "no asset retained");
        assertEq(address(registry).balance, 0, "no native retained");
    }

    /// @dev The two-hop case, and the whole reason multi-hop is supported: SPYon has no direct WETH
    ///      pool and is only reachable through USDG.
    function test_twoHopConvertsThroughTheIntermediate() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(USDG, true);
        _route(SPYon, _path(WETH, FEE_001, USDG, FEE_030, SPYon));

        vm.deal(address(this), 0.005 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.005 ether}(SPYon, 1, recipient);

        assertGt(out, 0, "reached through USDG");
        assertEq(IERC20(SPYon).balanceOf(recipient), out, "delivered in full");
        assertEq(IERC20(USDG).balanceOf(address(registry)), 0, "the intermediate is not retained either");
    }

    /// @dev A floor the pool cannot meet reverts, so a dividend freeze keeps its buffer.
    function test_aMissedFloorRevertsAndSpendsNothing() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.deal(address(this), 0.005 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert();
        registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1_000_000e18, recipient);
        assertEq(address(this).balance, balanceBefore, "native never left");
    }

    /// @dev The V3 twin of the V4 partial-fill guard, and it needs its own check because the leftover is
    ///      WETH rather than native: `WRAP_ETH` funds the router in WETH before the swap, so whatever the
    ///      pool did not take stays there in wrapped form. Refuse the fill rather than book a full spend
    ///      against a half-spent swap. The real-pool tests above are the full-fill control.
    function test_aPartialV3FillIsRefusedInsteadOfStrandingTheRest() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialFillV3RouterStub()).code);
        deal(AAPLon, router, 1000e18);

        vm.deal(address(this), 0.01 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.01 ether}(AAPLon, 1, recipient);

        assertEq(address(this).balance, balanceBefore, "the native never left the caller");
        assertEq(IERC20(AAPLon).balanceOf(recipient), 0, "and nothing was delivered on a half-spent swap");
    }

    /// @dev A route registered on the wrong fee tier names a pool that does not exist. Nothing on-chain
    ///      refuses it at write time — this is what the off-chain admission bar is for — but the swap
    ///      fails loudly rather than converting at a bad price.
    function test_aRouteOnTheWrongFeeTierFailsAtSwapTime() public {
        _route(AAPLon, _path(WETH, FEE_005, AAPLon));

        vm.deal(address(this), 0.005 ether);
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1, recipient);
    }

    //////////////////////// resolution order //////////////////////

    /// @dev An asset that ALSO passes the V2 test is redirected by its route: the curated pool wins,
    ///      because an asset only carries a route when an admin judged it the better venue.
    function test_aV3RouteWinsOverAViableV2Pair() public {
        assertEq(uint8(registry.validateRoute(MSFT, "")), uint8(SwapRejection.OK), "MSFT passes the V2 test");

        _route(MSFT, _path(WETH, FEE_030, MSFT));

        vm.deal(address(this), 0.01 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.01 ether}(MSFT, 1, recipient);
        assertGt(out, 0, "still converts");
        assertEq(IERC20(MSFT).balanceOf(recipient), out, "and through the route, not the pair");
    }

    /// @dev Adding a route for one asset must not move any other asset's venue.
    function test_aRouteDoesNotDisturbAnotherAsset() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        (address pair,) = registry.pairFor(WETH, MSFT);
        assertTrue(pair != address(0), "MSFT still resolves to its V2 pair");
        assertEq(registry.routeOf(address(this), MSFT).length, 0, "and has no route of its own");
    }

    //////////////////////// path validation //////////////////////

    function test_aPathThatDoesNotStartAtTheQuoteIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(AAPLon, _path(MSFT, FEE_030, AAPLon));
    }

    function test_aPathThatDoesNotEndAtTheAssetIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(AAPLon, _path(WETH, FEE_030, HOODon));
    }

    function test_aMalformedPathIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(AAPLon, abi.encodePacked(WETH, FEE_030)); // no destination
        _expectRejected(SwapRejection.MalformedRoute);
        _route(AAPLon, abi.encodePacked(WETH, FEE_030, AAPLon, hex"00")); // a trailing byte
    }

    /// @dev Three hops is refused: each extra hop is another pool that can drain, and the safety of a
    ///      two-hop route rests on its first leg being a major pool that will not.
    function test_aRouteLongerThanTwoHopsIsRejected() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(USDG, true);
        _expectRejected(SwapRejection.MalformedRoute);
        _route(SPYon, abi.encodePacked(WETH, FEE_001, USDG, FEE_005, MSFT, FEE_030, SPYon));
    }

    /// @dev A middle token has to be one the protocol already trusts to route through. Without this a
    ///      two-hop route could put a long-tail pool in the middle, giving the path two fragile legs.
    function test_anUnapprovedIntermediateIsRejected() public {
        _expectRejected(SwapRejection.IntermediateNotAllowed);
        _route(SPYon, _path(WETH, FEE_005, MSFT, FEE_030, SPYon));
    }

    //////////////////////// discoverability + access //////////////////////

    /// @dev An indexer learns which pools a token's dividends cross by replaying this event; nothing
    ///      else records it, since the route is not derivable from the asset.
    function test_everyRegistrationIsAnnounced() public {
        bytes memory route = DividendRouteLib.encodeV3(_path(WETH, FEE_030, AAPLon));

        vm.expectEmit(true, true, false, true, address(registry));
        emit RealmDividendSwapRegistry.DividendRouteRegistered(address(this), AAPLon, route);
        registry.registerRoute(AAPLon, route);
    }

    /// @dev NOBODY IS ASKED. A stranger registers their own token's route with no role at all — the
    ///      inverse of what this test asserted before the review step was dropped.
    function test_anyoneCanRegisterTheirOwnRoute() public {
        vm.prank(stranger);
        registry.registerRoute(AAPLon, DividendRouteLib.encodeV3(_path(WETH, FEE_030, AAPLon)));

        (bool ok,) = registry.checkSwapSupported(stranger, AAPLon);
        assertTrue(ok);
    }

    receive() external payable {}
}
