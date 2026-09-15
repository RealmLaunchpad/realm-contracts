// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RealmAnyPairsTaxHookPairImmutable} from "src/RealmAnyPairsTaxHookPairImmutable.sol";
import {RealmAnyPairsTokenPlain} from "src/RealmAnyPairsTokenPlain.sol";

contract R106HookQuote is ERC20 {
    constructor() ERC20("USDG", "USDG") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice Drives real swaps through the hook: the platform fee is INSIDE what the trader pays, the rates are snapshotted
/// per pool, and the creator (only) may raise a rate.
contract Round106HookTest is Test {
    using PoolIdLibrary for PoolKey;

    // BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    uint160 constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 constant FLAG_MASK = (1 << 14) - 1;
    uint256 constant TRADE = 1e18;

    IPoolManager pm;
    PoolModifyLiquidityTest lp;
    PoolSwapTest swapper;
    RealmAnyPairsTaxHookPairImmutable hook;
    R106HookQuote quote;
    address platform = makeAddr("platform");

    function setUp() public {
        pm = IPoolManager(deployCode("artifacts/TestPoolManager.json", abi.encode(address(this))));
        lp = new PoolModifyLiquidityTest(pm);
        swapper = new PoolSwapTest(pm);
        quote = new R106HookQuote();
        quote.mint(address(this), 1e36);
        quote.approve(address(lp), type(uint256).max);
        quote.approve(address(swapper), type(uint256).max);

        bytes memory init = abi.encodePacked(
            type(RealmAnyPairsTaxHookPairImmutable).creationCode, abi.encode(pm, address(this), platform)
        );
        bytes32 initHash = keccak256(init);
        uint256 salt;
        address predicted;
        for (;; ++salt) {
            predicted = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (uint160(predicted) & FLAG_MASK == FLAGS) break;
        }
        hook = new RealmAnyPairsTaxHookPairImmutable{salt: bytes32(salt)}(pm, address(this), platform);
        assertEq(address(hook), predicted);
        hook.setLauncher(address(this), true);
    }

    /// @dev Launch a coin paired with `quote` through the hook at `rate` bps per side, with deep liquidity.
    function _launch(uint16 rate) internal returns (PoolKey memory key, RealmAnyPairsTokenPlain coin) {
        coin = new RealmAnyPairsTokenPlain("C", "C", 1e30, address(this), address(this), 0, 0, new address[](0));
        coin.approve(address(lp), type(uint256).max);
        coin.approve(address(swapper), type(uint256).max);
        (address c0, address c1) =
            address(coin) < address(quote) ? (address(coin), address(quote)) : (address(quote), address(coin));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(hook)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory p;
        p.creator = address(this);
        p.buyBps = rate;
        p.sellBps = rate;
        p.autoThreshold = type(uint80).max; // keep the pot accruing so it can be read
        hook.configurePool(key, p);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1e25, bytes32(0)), "");
    }

    /// @dev Buy the coin with exactly TRADE quote; returns (fee taken, platform slice) from the hook's own ledger.
    function _buy(PoolKey memory key) internal returns (uint256 fee, uint256 plat) {
        PoolId id = key.toId();
        uint256 f0 = hook.accruedQuote(id);
        uint256 p0 = hook.accruedPlatformQuote(id);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(TRADE),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        fee = hook.accruedQuote(id) - f0;
        plat = hook.accruedPlatformQuote(id) - p0;
    }

    function test_fivePercentCoinChargesFiveNotSix() public {
        (PoolKey memory key,) = _launch(500);
        (uint256 fee, uint256 plat) = _buy(key);
        assertEq(fee, TRADE * 5 / 100, "trader pays 5.00%");
        assertEq(plat, TRADE * 1 / 100, "platform's 1.00% is inside it");
        assertEq(hook.totalFeeBpsOf(key.toId(), true), 500);
        assertEq(hook.platformFeeBpsOf(key.toId(), true), 100);
    }

    function test_zeroPercentCoinPaysOnlyTheFloor() public {
        (PoolKey memory key,) = _launch(0);
        (uint256 fee, uint256 plat) = _buy(key);
        assertEq(fee, TRADE * 20 / 10_000, "0.20% floor");
        assertEq(plat, fee, "all of it to the platform");
        assertEq(hook.creatorPoolBpsOf(key.toId(), true), 0);
    }

    function test_threePercentSplit() public {
        (PoolKey memory key,) = _launch(300);
        (uint256 fee, uint256 plat) = _buy(key);
        assertEq(fee, TRADE * 3 / 100);
        assertEq(plat, TRADE * 60 / 10_000, "20% of 3% = 0.60%");
    }

    function test_creatorCanRaiseTheRate() public {
        (PoolKey memory key,) = _launch(100);
        hook.setRates(key.toId(), 400, 400);
        (uint256 fee,) = _buy(key);
        assertEq(fee, TRADE * 4 / 100, "the raise prices the very next swap");
    }

    function test_creatorCannotExceedTheHardCap() public {
        (PoolKey memory key,) = _launch(100);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.SideCapExceeded.selector);
        hook.setRates(key.toId(), 501, 100);
    }

    function test_adminStillCannotRaise() public {
        (PoolKey memory key,) = _launch(100);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.RateNotLowered.selector);
        hook.adminSetRates(key.toId(), 200, 200);
        hook.adminSetRates(key.toId(), 50, 50); // lowering still works
    }

    function test_platformRatesAreSnapshottedPerPool() public {
        (PoolKey memory oldKey,) = _launch(500);
        hook.setPlatformRates(3000, 50, 200);

        (uint256 feeOld, uint256 platOld) = _buy(oldKey);
        assertEq(feeOld, TRADE * 5 / 100);
        assertEq(platOld, TRADE * 1 / 100, "a live coin keeps its launch schedule");

        (PoolKey memory newKey,) = _launch(500);
        (, uint256 platNew) = _buy(newKey);
        assertEq(platNew, TRADE * 150 / 10_000, "30% of 5% = 1.50% under the new rates");
        RealmAnyPairsTaxHookPairImmutable.TaxConfig memory c = hook.configOf(newKey.toId());
        assertEq(c.platformShareBps, 3000);
        assertEq(c.platformFloorBps, 50);
        assertEq(c.platformCapBps, 200);
    }

    function test_platformRateBounds() public {
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.BadPlatformRates.selector);
        hook.setPlatformRates(999, 20, 100);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.BadPlatformRates.selector);
        hook.setPlatformRates(3001, 20, 100);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.BadPlatformRates.selector);
        hook.setPlatformRates(2000, 101, 200);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.BadPlatformRates.selector);
        hook.setPlatformRates(2000, 20, 301);
        vm.expectRevert(RealmAnyPairsTaxHookPairImmutable.BadPlatformRates.selector);
        hook.setPlatformRates(2000, 50, 40); // cap below floor
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        hook.setPlatformRates(2000, 20, 100);
    }
}
