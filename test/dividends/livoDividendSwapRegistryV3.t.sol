// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
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
    address internal constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant NVDA = 0xC763873bb5509b6Bfe0a76A902207E41f2AaF340;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        IWETH9(WETH9).deposit{value: msg.value}();
        IERC20(WETH9).transfer(SINK, msg.value / 2); // the half the pool actually took
        IERC20(NVDA).transfer(msg.sender, 1e18);
    }
}

contract LivoDividendSwapRegistryV3Tests is Test {
    uint256 internal constant BLOCKNUMBER = 25880000;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @dev Ondo Global Markets tokenized equities. Single-hop WETH pools at the 0.3% tier.
    address internal constant NVDAon = 0xC763873bb5509b6Bfe0a76A902207E41f2AaF340;
    address internal constant HOODon = 0x916ad7E8c3a84b72cdF28d660beA9735f9D512e2;
    /// @dev Reachable only through USDC — the reason two-hop routes are supported at all.
    address internal constant SPYon = 0xFeDC5f4a6c38211c1338aa411018DFAf26612c08;

    uint24 internal constant FEE_005 = 500;
    uint24 internal constant FEE_030 = 3000;
    uint24 internal constant FEE_001 = 100;

    LivoDividendSwapRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);

        vm.prank(owner);
        registry.setAdmin(admin, true);
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
        vm.expectRevert(abi.encodeWithSelector(LivoDividendSwapRegistry.RouteRejected.selector, why));
    }

    //////////////////////// admission //////////////////////

    /// @dev An asset with no V2 pair is refused until a route admits it. The route IS the curation.
    function test_aV3RouteAdmitsAnAssetTheV2TestCannotSee() public {
        assertEq(
            uint8(registry.validateRoute(NVDAon, "")), uint8(SwapRejection.NoPair), "no V2 pair, so refused on its own"
        );

        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        assertTrue(_supported(NVDAon), "the route admits it");
        assertEq(
            registry.routeOf(address(this), NVDAon),
            DividendRouteLib.encodeV3(_path(WETH, FEE_030, NVDAon)),
            "and is readable back"
        );
    }

    /// @dev ⚠️ THE REGRESSION GUARD. The NVDAon/WETH pool holds essentially no WETH — its liquidity is
    ///      single-sided in the asset, which is what a sell-side maker looks like and what a buyer
    ///      wants. Any depth gate that read the quote-side balance would reject it. It converts fine.
    function test_aPoolHoldingAlmostNoQuoteTokenIsStillUsable() public {
        assertLt(IERC20(WETH).balanceOf(0x2323192488E6632840873410bb65B7Ec8DBfAb6f), 0.01 ether, "pool holds ~no WETH");

        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        vm.deal(address(this), 0.2 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.2 ether}(NVDAon, 1, recipient);
        assertGt(out, 0, "and yet it converts");
        assertEq(IERC20(NVDAon).balanceOf(recipient), out, "delivered in full");
    }

    /// @dev There is no clearing any more. A route is chosen once, by the creator, and is the token's
    ///      venue for life — including when the pool it names dies. That permanence is the cost of
    ///      dropping the review step, and it is why registration validates rather than trusts.
    function test_aRouteCannotBeClearedOrReplaced() public {
        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        vm.expectRevert(LivoDividendSwapRegistry.RouteAlreadyRegistered.selector);
        registry.registerRoute(NVDAon, "");
    }

    /// @dev A blacklist still overrides a curated route. The one admin veto outranks the one admin
    ///      admission, or blacklisting a routed asset would do nothing.
    function test_aBlacklistBeatsAV3Route() public {
        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        vm.prank(admin);
        registry.setBlacklisted(NVDAon, true);

        (bool ok, SwapRejection why) = registry.checkSwapSupported(address(this), NVDAon);
        assertFalse(ok);
        assertEq(uint8(why), uint8(SwapRejection.Blacklisted));
    }

    //////////////////////// execution //////////////////////

    function test_singleHopConvertsAndTheRegistryKeepsNothing() public {
        _route(HOODon, _path(WETH, FEE_030, HOODon));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(HOODon, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(HOODon).balanceOf(recipient), out, "recipient got exactly what was reported");
        assertEq(IERC20(HOODon).balanceOf(address(registry)), 0, "no asset retained");
        assertEq(address(registry).balance, 0, "no native retained");
    }

    /// @dev The two-hop case, and the whole reason multi-hop is supported: SPYon has no direct WETH
    ///      pool and is only reachable through USDC.
    function test_twoHopConvertsThroughTheIntermediate() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(USDC, true);
        _route(SPYon, _path(WETH, FEE_001, USDC, FEE_030, SPYon));

        vm.deal(address(this), 0.2 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.2 ether}(SPYon, 1, recipient);

        assertGt(out, 0, "reached through USDC");
        assertEq(IERC20(SPYon).balanceOf(recipient), out, "delivered in full");
        assertEq(IERC20(USDC).balanceOf(address(registry)), 0, "the intermediate is not retained either");
    }

    /// @dev A floor the pool cannot meet reverts, so a dividend freeze keeps its buffer.
    function test_aMissedFloorRevertsAndSpendsNothing() public {
        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        vm.deal(address(this), 0.2 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert();
        registry.swapNativeToAsset{value: 0.2 ether}(NVDAon, 1_000_000e18, recipient);
        assertEq(address(this).balance, balanceBefore, "native never left");
    }

    /// @dev The V3 twin of the V4 partial-fill guard, and it needs its own check because the leftover is
    ///      WETH rather than native: `WRAP_ETH` funds the router in WETH before the swap, so whatever the
    ///      pool did not take stays there in wrapped form. Refuse the fill rather than book a full spend
    ///      against a half-spent swap. The real-pool tests above are the full-fill control.
    function test_aPartialV3FillIsRefusedInsteadOfStrandingTheRest() public {
        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialFillV3RouterStub()).code);
        deal(NVDAon, router, 1000e18);

        vm.deal(address(this), 1 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(LivoDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 1 ether}(NVDAon, 1, recipient);

        assertEq(address(this).balance, balanceBefore, "the native never left the caller");
        assertEq(IERC20(NVDAon).balanceOf(recipient), 0, "and nothing was delivered on a half-spent swap");
    }

    /// @dev A route registered on the wrong fee tier names a pool that does not exist. Nothing on-chain
    ///      refuses it at write time — this is what the off-chain admission bar is for — but the swap
    ///      fails loudly rather than converting at a bad price.
    function test_aRouteOnTheWrongFeeTierFailsAtSwapTime() public {
        _route(NVDAon, _path(WETH, FEE_005, NVDAon));

        vm.deal(address(this), 0.2 ether);
        vm.expectRevert(LivoDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.2 ether}(NVDAon, 1, recipient);
    }

    //////////////////////// resolution order //////////////////////

    /// @dev An asset that ALSO passes the V2 test is redirected by its route: the curated pool wins,
    ///      because an asset only carries a route when an admin judged it the better venue.
    function test_aV3RouteWinsOverAViableV2Pair() public {
        assertEq(uint8(registry.validateRoute(DAI, "")), uint8(SwapRejection.OK), "DAI passes the V2 test");

        _route(DAI, _path(WETH, FEE_030, DAI));

        vm.deal(address(this), 1 ether);
        uint256 out = registry.swapNativeToAsset{value: 1 ether}(DAI, 1, recipient);
        assertGt(out, 0, "still converts");
        assertEq(IERC20(DAI).balanceOf(recipient), out, "and through the route, not the pair");
    }

    /// @dev Adding a route for one asset must not move any other asset's venue.
    function test_aRouteDoesNotDisturbAnotherAsset() public {
        _route(NVDAon, _path(WETH, FEE_030, NVDAon));

        (address pair,) = registry.pairFor(WETH, DAI);
        assertTrue(pair != address(0), "DAI still resolves to its V2 pair");
        assertEq(registry.routeOf(address(this), DAI).length, 0, "and has no route of its own");
    }

    //////////////////////// path validation //////////////////////

    function test_aPathThatDoesNotStartAtTheQuoteIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(NVDAon, _path(DAI, FEE_030, NVDAon));
    }

    function test_aPathThatDoesNotEndAtTheAssetIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(NVDAon, _path(WETH, FEE_030, HOODon));
    }

    function test_aMalformedPathIsRejected() public {
        _expectRejected(SwapRejection.MalformedRoute);
        _route(NVDAon, abi.encodePacked(WETH, FEE_030)); // no destination
        _expectRejected(SwapRejection.MalformedRoute);
        _route(NVDAon, abi.encodePacked(WETH, FEE_030, NVDAon, hex"00")); // a trailing byte
    }

    /// @dev Three hops is refused: each extra hop is another pool that can drain, and the safety of a
    ///      two-hop route rests on its first leg being a major pool that will not.
    function test_aRouteLongerThanTwoHopsIsRejected() public {
        vm.prank(admin);
        registry.setAllowedQuoteToken(USDC, true);
        _expectRejected(SwapRejection.MalformedRoute);
        _route(SPYon, abi.encodePacked(WETH, FEE_001, USDC, FEE_005, DAI, FEE_030, SPYon));
    }

    /// @dev A middle token has to be one the protocol already trusts to route through. Without this a
    ///      two-hop route could put a long-tail pool in the middle, giving the path two fragile legs.
    function test_anUnapprovedIntermediateIsRejected() public {
        _expectRejected(SwapRejection.IntermediateNotAllowed);
        _route(SPYon, _path(WETH, FEE_005, DAI, FEE_030, SPYon));
    }

    //////////////////////// discoverability + access //////////////////////

    /// @dev An indexer learns which pools a token's dividends cross by replaying this event; nothing
    ///      else records it, since the route is not derivable from the asset.
    function test_everyRegistrationIsAnnounced() public {
        bytes memory route = DividendRouteLib.encodeV3(_path(WETH, FEE_030, NVDAon));

        vm.expectEmit(true, true, false, true, address(registry));
        emit LivoDividendSwapRegistry.DividendRouteRegistered(address(this), NVDAon, route);
        registry.registerRoute(NVDAon, route);
    }

    /// @dev NOBODY IS ASKED. A stranger registers their own token's route with no role at all — the
    ///      inverse of what this test asserted before the review step was dropped.
    function test_anyoneCanRegisterTheirOwnRoute() public {
        vm.prank(stranger);
        registry.registerRoute(NVDAon, DividendRouteLib.encodeV3(_path(WETH, FEE_030, NVDAon)));

        (bool ok,) = registry.checkSwapSupported(stranger, NVDAon);
        assertTrue(ok);
    }

    receive() external payable {}
}
