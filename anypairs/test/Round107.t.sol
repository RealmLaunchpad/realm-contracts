// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {RealmAnyPairsRouteLib} from "src/RealmAnyPairsRouteLib.sol";
import {RealmAnyPairsDividendTrackerBasket} from "src/RealmAnyPairsDividendTrackerBasket.sol";
import {RealmAnyPairsDividendTrackerEthBasket} from "src/RealmAnyPairsDividendTrackerEthBasket.sol";
import {RealmAnyPairsDividendTrackerMultiBasket} from "src/RealmAnyPairsDividendTrackerMultiBasket.sol";
import {V4Fixture, R106Token, MockWethR106} from "./Round106.t.sol";

/// @dev A hook with only BEFORE_INITIALIZE: its pools are real, swappable, and NOT discoverable (the key carries a hook).
contract R107Hook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
}

abstract contract HookedFixture is V4Fixture {
    address constant HOOK_A = address(uint160(1 << 13));
    address constant HOOK_B = address(uint160((1 << 13) | (1 << 20)));

    function _hooks() internal {
        bytes memory code = address(new R107Hook()).code;
        vm.etch(HOOK_A, code);
        vm.etch(HOOK_B, code);
    }

    function _hookedPool(address a, address b, address hook, uint128 liquidity) internal returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 2500, 25, IHooks(hook));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        if (c0 != address(0)) {
            R106Token(c0).approve(address(lp), type(uint256).max);
        }
        R106Token(c1).approve(address(lp), type(uint256).max);
        uint256 value = c0 == address(0) ? 1_000_000 ether : 0;
        lp.modifyLiquidity{value: value}(
            key, ModifyLiquidityParams(-60000, 60000, int256(uint256(liquidity)), bytes32(0)), ""
        );
    }
}

contract Round107BasketTest is HookedFixture {
    R106Token quote;
    R106Token stock;

    function setUp() public {
        _pm();
        _hooks();
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
    }

    function _tracker(address feeder) internal returns (RealmAnyPairsDividendTrackerBasket t) {
        RealmAnyPairsDividendTrackerBasket.Leg[] memory legs = new RealmAnyPairsDividendTrackerBasket.Leg[](1);
        legs[0] = RealmAnyPairsDividendTrackerBasket.Leg(address(stock), 10_000);
        t = new RealmAnyPairsDividendTrackerBasket(
            RealmAnyPairsDividendTrackerBasket.Config({
                token: address(this),
                feeder: feeder,
                quote: address(quote),
                swapRouter: address(0),
                v3Factory: address(0),
                poolManager: address(pm),
                minEligible: 1,
                excluded: new address[](0),
                basket: legs
            })
        );
        t.setBalance(alice, 1e18);
        quote.transfer(address(t), 1e18);
        vm.prank(feeder);
        t.feedToken(0);
    }

    function _mins(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _routes(bytes memory r) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = r;
    }

    function test_hookedPoolIsNotDiscoverable_butASuppliedRouteReachesIt() public {
        PoolKey memory key = _hookedPool(address(quote), address(stock), HOOK_A, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));

        (,, bytes memory discovered) = t.basketLeg(0);
        assertEq(discovered.length, 0, "a hooked pool cannot be discovered");

        vm.prank(alice);
        t.claimWithRoutes(_mins(0.9e18), _routes(abi.encode(key)));
        assertGt(stock.balanceOf(alice), 0.9e18, "the supplied V4 route delivered the stock");
    }

    function test_emptyRouteMeansDiscover() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        t.claimWithRoutes(_mins(0.9e18), _routes(""));
        assertGt(stock.balanceOf(alice), 0.9e18);
    }

    function test_suppliedRouteBeatsDiscovery() public {
        _pool(address(quote), address(stock), 100, 1, 1e18); // discoverable but shallow: a big slippage
        PoolKey memory deep = _hookedPool(address(quote), address(stock), HOOK_A, 1e25);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        t.claimWithRoutes(_mins(0.99e18), _routes(abi.encode(deep)));
        assertGt(stock.balanceOf(alice), 0.99e18, "the deep hooked pool was used, not the shallow discoverable one");
    }

    function test_rejectsARouteToTheWrongAsset() public {
        R106Token other = new R106Token("OTHER");
        other.mint(address(this), 1e36);
        PoolKey memory wrong = _hookedPool(address(quote), address(other), HOOK_A, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.claimWithRoutes(_mins(0), _routes(abi.encode(wrong)));
    }

    function test_rejectsAnUninitializedPool() public {
        (address c0, address c1) =
            address(quote) < address(stock) ? (address(quote), address(stock)) : (address(stock), address(quote));
        PoolKey memory ghost = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 2500, 25, IHooks(HOOK_A));
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.claimWithRoutes(_mins(0), _routes(abi.encode(ghost)));
    }

    function test_rejectsARouteThroughTheFeederHook() public {
        PoolKey memory viaFeeder = _hookedPool(address(quote), address(stock), HOOK_B, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(HOOK_B); // this tracker's feeder IS that hook
        vm.prank(alice);
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.claimWithRoutes(_mins(0), _routes(abi.encode(viaFeeder)));
    }

    function test_rejectsGarbageAndAV3PathWithoutAFactory() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.startPrank(alice);
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.claimWithRoutes(_mins(0), _routes(hex"1234"));
        vm.expectRevert(RealmAnyPairsRouteLib.BadRoute.selector);
        t.claimWithRoutes(_mins(0), _routes(abi.encodePacked(address(quote), uint24(3000), address(stock))));
        vm.stopPrank();
    }

    function test_routesLengthMustMatchLegs() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        vm.expectRevert(RealmAnyPairsDividendTrackerBasket.BadRoutes.selector);
        t.claimWithRoutes(_mins(0), new bytes[](2));
    }

    function test_oldEntryPointsStillDiscover() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(this));
        vm.prank(alice);
        t.claimWithMinOuts(_mins(0.9e18));
        assertGt(stock.balanceOf(alice), 0.9e18);
    }
}

contract Round107EthBasketTest is HookedFixture {
    R106Token stock;
    MockWethR106 weth;

    function setUp() public {
        _pm();
        _hooks();
        stock = new R106Token("xSTOCK");
        stock.mint(address(this), 1e36);
        weth = new MockWethR106();
    }

    function test_suppliedNativeHookedRoute() public {
        PoolKey memory key = _hookedPool(address(0), address(stock), HOOK_A, 1e22);
        RealmAnyPairsDividendTrackerEthBasket.Leg[] memory legs = new RealmAnyPairsDividendTrackerEthBasket.Leg[](1);
        legs[0] = RealmAnyPairsDividendTrackerEthBasket.Leg(address(stock), 10_000);
        RealmAnyPairsDividendTrackerEthBasket t = new RealmAnyPairsDividendTrackerEthBasket(
            RealmAnyPairsDividendTrackerEthBasket.Config({
                token: address(this),
                feeder: address(this),
                weth: address(weth),
                swapRouter: address(0),
                v3Factory: address(0),
                poolManager: address(pm),
                minEligible: 1,
                excluded: new address[](0),
                basket: legs
            })
        );
        t.setBalance(alice, 1e18);
        t.feed{value: 1 ether}();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0.9e18;
        bytes[] memory routes = new bytes[](1);
        routes[0] = abi.encode(key);
        vm.prank(alice);
        t.claimWithRoutes(mins, routes);
        assertGt(stock.balanceOf(alice), 0.9e18);
    }
}

contract Round107MultiBasketTest is HookedFixture {
    R106Token quote;
    R106Token stock;

    function setUp() public {
        _pm();
        _hooks();
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
    }

    function test_suppliedHookedRoutePerDenomination() public {
        PoolKey memory key = _hookedPool(address(quote), address(stock), HOOK_A, 1e24);
        RealmAnyPairsDividendTrackerMultiBasket.Leg[] memory legs = new RealmAnyPairsDividendTrackerMultiBasket.Leg[](1);
        legs[0] = RealmAnyPairsDividendTrackerMultiBasket.Leg(address(stock), 10_000);
        RealmAnyPairsDividendTrackerMultiBasket.DenomBasket[] memory dbs =
            new RealmAnyPairsDividendTrackerMultiBasket.DenomBasket[](1);
        dbs[0] = RealmAnyPairsDividendTrackerMultiBasket.DenomBasket(address(quote), legs);
        RealmAnyPairsDividendTrackerMultiBasket t = new RealmAnyPairsDividendTrackerMultiBasket(
            RealmAnyPairsDividendTrackerMultiBasket.Config({
                token: address(this),
                feeder: address(this),
                swapRouter: address(0),
                v3Factory: address(0),
                poolManager: address(pm),
                minEligible: 1,
                excluded: new address[](0),
                denomBaskets: dbs
            })
        );
        t.setBalance(alice, 1e18);
        quote.transfer(address(t), 1e18);
        t.feedToken(0);
        uint256[][] memory mins = new uint256[][](1);
        mins[0] = new uint256[](1);
        mins[0][0] = 0.9e18;
        bytes[][] memory routes = new bytes[][](1);
        routes[0] = new bytes[](1);
        routes[0][0] = abi.encode(key);
        vm.prank(alice);
        t.claimWithRoutes(mins, routes);
        assertGt(stock.balanceOf(alice), 0.9e18);
    }
}
