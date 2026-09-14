// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RealmAnyPairsPlatformFeeConverter} from "src/RealmAnyPairsPlatformFeeConverter.sol";
import {RealmAnyPairsTokenPlain} from "src/RealmAnyPairsTokenPlain.sol";
import {RealmAnyPairsTokenDividend} from "src/RealmAnyPairsTokenDividend.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev A hook with only BEFORE_INITIALIZE, and no constructor-time address validation, so it can be etched at a flag address.
contract NoopInitHook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
}

contract MockWeth is ERC20 {
    constructor() ERC20("WETH", "WETH") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "eth");
    }
}

contract Round105ConverterV4Test is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager pm;
    PoolModifyLiquidityTest lp;
    PoolSwapTest swapper;
    MockToken quote;
    MockWeth weth;
    RealmAnyPairsPlatformFeeConverter conv;
    address treasury = makeAddr("treasury");
    PoolKey key;

    uint256 constant AMOUNT = 1e18;
    /// @dev History is written at FIXED absolute times. Under via_ir the optimizer may treat a local holding
    /// `block.timestamp` as the TIMESTAMP opcode and re-read it after each `vm.warp`, so relative warps compound.
    /// On chain that substitution is correct (the timestamp is constant within a call); it only breaks warping tests.
    uint256 constant T0 = 1_000_000;
    uint256 constant HISTORY_END = T0 + 1350;

    receive() external payable {}

    function setUp() public {
        pm = IPoolManager(deployCode("artifacts/TestPoolManager.json", abi.encode(address(this))));
        lp = new PoolModifyLiquidityTest(pm);
        swapper = new PoolSwapTest(pm);
        quote = new MockToken("Q");
        weth = new MockWeth();
        vm.deal(address(weth), 1_000_000 ether);

        key = _key(Currency.wrap(address(quote)), Currency.wrap(address(weth)), IHooks(address(0)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        quote.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        quote.approve(address(lp), type(uint256).max);
        weth.approve(address(lp), type(uint256).max);
        quote.approve(address(swapper), type(uint256).max);
        weth.approve(address(swapper), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1e24, bytes32(0)), "");

        conv = new RealmAnyPairsPlatformFeeConverter(
            address(weth), address(0xdead1), address(0xdead2), address(0), address(this), treasury, 0, 0, address(pm)
        );
        conv.setV4Route(address(quote), _one(key), 1e21);
    }

    // ── helpers ──

    function _key(Currency a, Currency b, IHooks h) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey(c0, c1, 3000, 60, h);
    }

    function _one(PoolKey memory k) internal pure returns (PoolKey[] memory hops) {
        hops = new PoolKey[](1);
        hops[0] = k;
    }

    /// @dev Four samples, 450 s apart: the minimum history that prices.
    function _buildHistory(address q) internal {
        // Absolute times, computed from one read taken before the loop: under via_ir a `block.timestamp` read inside the
        // loop can be hoisted out of it, so `warp(block.timestamp + 450)` would warp to the same second every iteration.
        vm.warp(T0);
        conv.poke(q);
        vm.warp(T0 + 450);
        conv.poke(q);
        vm.warp(T0 + 900);
        conv.poke(q);
        vm.warp(HISTORY_END);
        conv.poke(q);
    }

    /// @dev Sells currency0 into the pool, pushing its price (and tick) down.
    function _pushPrice(PoolKey memory k, int256 amount) internal {
        swapper.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _spotTick(PoolKey memory k) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(k.toId());
    }

    function _abs(int24 x) internal pure returns (int256) {
        return x < 0 ? -int256(x) : int256(x);
    }

    // ── V4 conversion ──

    function test_skipsWithoutHistory_andStillRecordsTheSample() public {
        quote.mint(address(conv), AMOUNT);
        vm.expectEmit(address(conv));
        emit RealmAnyPairsPlatformFeeConverter.ConvertSkipped(address(quote), 3);
        assertEq(conv.convert(address(quote)), 0);
        (, uint8 count,) = conv.samplesOf(key.toId());
        assertEq(count, 1, "convert samples before it skips");
        assertEq(quote.balanceOf(address(conv)), AMOUNT, "nothing swapped");
    }

    function test_convertsOnceSamplesSpanTheWindow() public {
        _buildHistory(address(quote));
        (uint256 live, uint32 span,, bool ready) = conv.sampleStatus(key.toId());
        assertEq(live, 4);
        assertEq(span, 1350);
        assertTrue(ready);

        quote.mint(address(conv), AMOUNT);
        uint256 floorOut = conv.quoteFloor(address(quote), AMOUNT);
        assertGt(floorOut, 0);
        uint256 out = conv.convert(address(quote));
        assertGe(out, floorOut, "output honours the floor");
        assertEq(treasury.balance, out, "no gas price, no tip: all of it to the treasury");
        assertEq(quote.balanceOf(address(conv)), 0);
        assertEq(weth.balanceOf(address(conv)), 0, "WETH unwrapped");
    }

    function test_oneSamplePerSpacingWindow() public {
        assertEq(conv.poke(address(quote)), 1);
        assertEq(conv.poke(address(quote)), 0, "same block");
        vm.warp(block.timestamp + 449);
        assertEq(conv.poke(address(quote)), 0, "inside the spacing");
        vm.warp(block.timestamp + 1);
        assertEq(conv.poke(address(quote)), 1);
    }

    function test_priceMovingSkips() public {
        _buildHistory(address(quote));
        _pushPrice(key, -5e22);
        assertGt(_abs(_spotTick(key)), 300, "fixture moved the price past the band");

        quote.mint(address(conv), AMOUNT);
        vm.expectEmit(address(conv));
        emit RealmAnyPairsPlatformFeeConverter.ConvertSkipped(address(quote), 6);
        assertEq(conv.convert(address(quote)), 0);
        assertEq(treasury.balance, 0);
    }

    function test_pushedSampleIsRefusedOnceHistoryExists() public {
        _buildHistory(address(quote));
        vm.warp(HISTORY_END + 450);
        _pushPrice(key, -5e22);
        assertEq(conv.poke(address(quote)), 0, "refused");
        (, uint8 count,) = conv.samplesOf(key.toId());
        assertEq(count, 4, "ring unchanged");
    }

    function test_staleHistorySkips() public {
        _buildHistory(address(quote));
        vm.warp(HISTORY_END + 3601);
        quote.mint(address(conv), AMOUNT);
        vm.expectEmit(address(conv));
        emit RealmAnyPairsPlatformFeeConverter.ConvertSkipped(address(quote), 3);
        conv.convert(address(quote));
    }

    function test_nativeEthRoute() public {
        MockToken q2 = new MockToken("Q2");
        PoolKey memory nk = _key(Currency.wrap(address(0)), Currency.wrap(address(q2)), IHooks(address(0)));
        pm.initialize(nk, TickMath.getSqrtPriceAtTick(0));
        q2.mint(address(this), 1e30);
        q2.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
        lp.modifyLiquidity{value: 100_000 ether}(nk, ModifyLiquidityParams(-60000, 60000, 1e22, bytes32(0)), "");

        conv.setV4Route(address(q2), _one(nk), 1e21);
        _buildHistory(address(q2));
        q2.mint(address(conv), AMOUNT);
        uint256 out = conv.convert(address(q2));
        assertGt(out, 0);
        assertEq(treasury.balance, out, "native ETH straight to the treasury");
    }

    // ── route validation ──

    function test_routeRejectsBadShapes() public {
        MockToken other = new MockToken("O");
        PoolKey memory notEndingInEth =
            _key(Currency.wrap(address(quote)), Currency.wrap(address(other)), IHooks(address(0)));
        pm.initialize(notEndingInEth, TickMath.getSqrtPriceAtTick(0));
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.BadRoute.selector);
        conv.setV4Route(address(quote), _one(notEndingInEth), 1e21);

        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.BadRoute.selector);
        conv.setV4Route(address(other), _one(key), 1e21); // first hop does not contain the quote

        PoolKey memory uninit = PoolKey(key.currency0, key.currency1, 500, 10, IHooks(address(0)));
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.BadRoute.selector);
        conv.setV4Route(address(quote), _one(uninit), 1e21);

        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.BadRoute.selector);
        conv.setV4Route(address(quote), _one(key), 0);
    }

    function test_routeRejectsAPoolCarryingTheRealmHook() public {
        address hookAddr = address(uint160(1 << 13)); // BEFORE_INITIALIZE flag only
        vm.etch(hookAddr, address(new NoopInitHook()).code);
        PoolKey memory hooked = _key(Currency.wrap(address(quote)), Currency.wrap(address(weth)), IHooks(hookAddr));
        pm.initialize(hooked, TickMath.getSqrtPriceAtTick(0));
        RealmAnyPairsPlatformFeeConverter c2 = new RealmAnyPairsPlatformFeeConverter(
            address(weth), address(0xdead1), address(0xdead2), hookAddr, address(this), treasury, 0, 0, address(pm)
        );
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.BadRoute.selector);
        c2.setV4Route(address(quote), _one(hooked), 1e21);
    }

    function test_v4DisabledWithoutPoolManager() public {
        RealmAnyPairsPlatformFeeConverter c3 = new RealmAnyPairsPlatformFeeConverter(
            address(weth), address(0xdead1), address(0xdead2), address(0), address(this), treasury, 0, 0, address(0)
        );
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.V4Disabled.selector);
        c3.setV4Route(address(quote), _one(key), 1e21);
    }

    function test_removingTheRouteStopsConversion() public {
        conv.setV4Route(address(quote), new PoolKey[](0), 0);
        assertEq(conv.v4RouteOf(address(quote)).length, 0);
        assertEq(conv.maxInPerCall(address(quote)), 0);
        quote.mint(address(conv), AMOUNT);
        vm.expectEmit(address(conv));
        emit RealmAnyPairsPlatformFeeConverter.ConvertSkipped(address(quote), 1);
        conv.convert(address(quote));
    }

    function test_unlockCallbackRefusesStrangers() public {
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.NotPoolManager.selector);
        conv.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(RealmAnyPairsPlatformFeeConverter.UnexpectedUnlock.selector);
        conv.unlockCallback("");
    }
}

contract Round105TokenRescueTest is Test {
    MockToken foreign;
    address stranger = makeAddr("stranger");

    function setUp() public {
        foreign = new MockToken("F");
    }

    function _plain() internal returns (RealmAnyPairsTokenPlain) {
        return new RealmAnyPairsTokenPlain("T", "T", 1e24, address(this), address(this), 0, 0, new address[](0));
    }

    function _dividend() internal returns (RealmAnyPairsTokenDividend) {
        return new RealmAnyPairsTokenDividend("D", "D", 1e24, address(this), address(this), 0, 0, new address[](0));
    }

    function test_plain_rescuesItsOwnCoinToTheLauncher() public {
        RealmAnyPairsTokenPlain t = _plain();
        t.transfer(address(t), 1_000);
        uint256 before = t.balanceOf(address(this));
        vm.prank(stranger);
        assertEq(t.rescue(address(t)), 1_000);
        assertEq(t.balanceOf(address(t)), 0);
        assertEq(t.balanceOf(address(this)), before + 1_000, "launcher got it, not the caller");
        assertEq(t.balanceOf(stranger), 0);
    }

    function test_plain_rescuesAForeignToken() public {
        RealmAnyPairsTokenPlain t = _plain();
        foreign.mint(address(t), 777);
        vm.prank(stranger);
        vm.expectEmit(address(t));
        emit RealmAnyPairsTokenPlain.Rescued(address(foreign), address(this), 777);
        t.rescue(address(foreign));
        assertEq(foreign.balanceOf(address(this)), 777);
    }

    function test_plain_nothingToRescueReverts() public {
        RealmAnyPairsTokenPlain t = _plain();
        vm.expectRevert(RealmAnyPairsTokenPlain.NothingToRescue.selector);
        t.rescue(address(t));
        vm.expectRevert(RealmAnyPairsTokenPlain.NothingToRescue.selector);
        t.rescue(address(foreign));
    }

    function test_dividend_rescuesBoth() public {
        RealmAnyPairsTokenDividend t = _dividend();
        t.transfer(address(t), 5);
        foreign.mint(address(t), 9);
        uint256 before = t.balanceOf(address(this));
        vm.startPrank(stranger);
        t.rescue(address(t));
        t.rescue(address(foreign));
        vm.stopPrank();
        assertEq(t.balanceOf(address(this)), before + 5);
        assertEq(foreign.balanceOf(address(this)), 9);
    }

    function test_rescueCannotTouchAHolder() public {
        RealmAnyPairsTokenPlain t = _plain();
        t.transfer(stranger, 50);
        vm.expectRevert(RealmAnyPairsTokenPlain.NothingToRescue.selector);
        t.rescue(address(t));
        assertEq(t.balanceOf(stranger), 50);
    }
}
