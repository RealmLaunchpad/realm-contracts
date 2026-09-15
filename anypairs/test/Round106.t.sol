// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RealmAnyPairsFeeMath} from "src/RealmAnyPairsFeeMath.sol";
import {RealmAnyPairsDividendTrackerBasket} from "src/RealmAnyPairsDividendTrackerBasket.sol";
import {RealmAnyPairsDividendTrackerEthBasket} from "src/RealmAnyPairsDividendTrackerEthBasket.sol";
import {RealmAnyPairsDividendTrackerMultiBasket} from "src/RealmAnyPairsDividendTrackerMultiBasket.sol";

contract R106Token is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract FeeMathHarness {
    function total(uint256 eff, uint256 floor) external pure returns (uint256) {
        return RealmAnyPairsFeeMath.totalBps(eff, floor);
    }

    function platform(uint256 t, uint256 share, uint256 floor, uint256 cap) external pure returns (uint256) {
        return RealmAnyPairsFeeMath.platformBps(t, share, floor, cap);
    }
}

contract Round106FeeMathTest is Test {
    FeeMathHarness h = new FeeMathHarness();

    function _row(uint256 rate, uint256 wantTotal, uint256 wantPlatform) internal view {
        uint256 t = h.total(rate, 20);
        assertEq(t, wantTotal, "trader pays");
        assertEq(h.platform(t, 2000, 20, 100), wantPlatform, "platform slice");
    }

    /// The table in the hook's docs, at the default rates.
    function test_defaultScheduleTable() public view {
        _row(0, 20, 20); // 0% coin: pays the 0.20% floor, all of it to the platform
        _row(50, 50, 20); // 0.50%: platform takes the floor, creator 0.30%
        _row(100, 100, 20); // 1%
        _row(300, 300, 60); // 3%: 20%
        _row(500, 500, 100); // 5%: trader pays 5%, never 6%
        _row(3000, 3000, 100); // 30% launch ramp: the cap binds
    }

    function testFuzz_platformNeverExceedsWhatTheTraderPays(uint16 rate, uint16 share, uint16 floor, uint16 cap) public view {
        rate = uint16(bound(rate, 0, 3000));
        share = uint16(bound(share, 1000, 3000));
        floor = uint16(bound(floor, 0, 100));
        cap = uint16(bound(cap, floor, 300));
        uint256 t = h.total(rate, floor);
        uint256 p = h.platform(t, share, floor, cap);
        assertLe(p, t, "platform <= total");
        assertGe(t, rate, "trader never pays below the creator rate");
        assertGe(t, floor, "trader never pays below the floor");
        if (t > 0) assertGe(p, floor < t ? floor : t, "the floor always reaches the platform");
    }
}

abstract contract V4Fixture is Test {
    IPoolManager pm;
    PoolModifyLiquidityTest lp;
    address alice = makeAddr("alice");

    receive() external payable {}

    function _pm() internal {
        pm = IPoolManager(deployCode("artifacts/TestPoolManager.json", abi.encode(address(this))));
        lp = new PoolModifyLiquidityTest(pm);
        vm.deal(address(this), 10_000_000 ether);
    }

    function _pool(address a, address b, uint24 fee, int24 spacing, uint128 liquidity) internal returns (PoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        if (c0 != address(0)) R106Token(c0).approve(address(lp), type(uint256).max);
        R106Token(c1).approve(address(lp), type(uint256).max);
        int24 lo = -int24(60000 / spacing) * spacing;
        uint256 value = c0 == address(0) ? 1_000_000 ether : 0;
        lp.modifyLiquidity{value: value}(key, ModifyLiquidityParams(lo, -lo, int256(uint256(liquidity)), bytes32(0)), "");
    }
}

contract Round106BasketTest is V4Fixture {
    R106Token quote;
    R106Token stock;

    function setUp() public {
        _pm();
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
    }

    function _tracker(address asset) internal returns (RealmAnyPairsDividendTrackerBasket t) {
        RealmAnyPairsDividendTrackerBasket.Leg[] memory legs = new RealmAnyPairsDividendTrackerBasket.Leg[](1);
        legs[0] = RealmAnyPairsDividendTrackerBasket.Leg(asset, 10_000);
        t = new RealmAnyPairsDividendTrackerBasket(
            RealmAnyPairsDividendTrackerBasket.Config({
                token: address(this),
                feeder: address(this),
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
        t.feedToken(0);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function test_launchNoLongerRevertsWithoutARoute() public {
        _tracker(address(stock)); // no pool at all: construction used to revert NoRouteFound
    }

    function test_convertsThroughADiscoveredV4Pool() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        (,, bytes memory path) = t.basketLeg(0);
        assertEq(path.length, 160, "basketLeg reports the live V4 key");
        vm.prank(alice);
        t.claimWithMinOuts(_one(0.9e18));
        assertGt(stock.balanceOf(alice), 0.9e18, "paid in the stock");
        assertEq(quote.balanceOf(alice), 0, "not in the quote");
    }

    function test_picksTheDeepestPool() public {
        _pool(address(quote), address(stock), 10000, 200, 1e20);
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        (,, bytes memory path) = t.basketLeg(0);
        (,, uint24 fee, int24 spacing,) = abi.decode(path, (address, address, uint24, int24, address));
        assertEq(fee, 2500);
        assertEq(spacing, 25);
    }

    function test_aPoolCreatedAfterLaunchIsUsed() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        (,, bytes memory before) = t.basketLeg(0);
        assertEq(before.length, 0);
        _pool(address(quote), address(stock), 100, 1, 1e24);
        vm.prank(alice);
        t.claimWithMinOuts(_one(0.9e18));
        assertGt(stock.balanceOf(alice), 0.9e18);
    }

    function test_noRoute_claimAtAnyPricePaysTheQuote() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        vm.prank(alice);
        t.claimAtAnyPrice();
        assertApproxEqAbs(quote.balanceOf(alice), 1e18, 1, "fallback to the raw quote");
    }

    function test_noRoute_withAFloorReverts() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        vm.prank(alice);
        vm.expectRevert();
        t.claimWithMinOuts(_one(1));
    }

    function test_floorAboveTheFillReverts() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        vm.prank(alice);
        vm.expectRevert();
        t.claimWithMinOuts(_one(2e18));
    }

    function test_poolManagerIsNotAValidRecipient() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        vm.prank(alice);
        vm.expectRevert(RealmAnyPairsDividendTrackerBasket.ZeroRecipient.selector);
        t.claimToWithMinOuts(address(pm), _one(0));
    }

    function test_unlockCallbackRefusesStrangers() public {
        RealmAnyPairsDividendTrackerBasket t = _tracker(address(stock));
        vm.prank(address(pm));
        vm.expectRevert(RealmAnyPairsDividendTrackerBasket.OnlySelf.selector);
        t.unlockCallback("");
    }
}

contract MockWethR106 is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract Round106EthBasketTest is V4Fixture {
    R106Token stock;
    MockWethR106 weth;

    function setUp() public {
        _pm();
        stock = new R106Token("xSTOCK");
        stock.mint(address(this), 1e36);
        weth = new MockWethR106();
    }

    function test_convertsEthThroughANativeV4Pool() public {
        _pool(address(0), address(stock), 2500, 25, 1e22);
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
        vm.prank(alice);
        t.claimWithMinOuts(mins);
        assertGt(stock.balanceOf(alice), 0.9e18, "ETH rewards arrive as the stock");
    }
}

contract Round106MultiBasketTest is V4Fixture {
    R106Token quote;
    R106Token stock;

    function setUp() public {
        _pm();
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
    }

    function test_denominationConvertsThroughADiscoveredV4Pool() public {
        _pool(address(quote), address(stock), 2500, 25, 1e24);
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
        vm.prank(alice);
        t.claimToWithMinOuts(alice, mins);
        assertGt(stock.balanceOf(alice), 0.9e18);
    }
}
