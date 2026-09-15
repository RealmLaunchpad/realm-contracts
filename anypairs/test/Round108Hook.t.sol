// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {RealmAnyPairsTaxHookPairImmutable} from "src/RealmAnyPairsTaxHookPairImmutable.sol";
import {RealmAnyPairsTokenPlain} from "src/RealmAnyPairsTokenPlain.sol";
import {RealmAnyPairsDividendTrackerAutoBasket as AB} from "src/RealmAnyPairsDividendTrackerAutoBasket.sol";
import {R106Token} from "./Round106.t.sol";

/// @dev A quote that reverts `balanceOf` for one address, as a compliance-gated token does for a blacklisted one.
contract BlockingQuote is R106Token {
    address public blocked;

    constructor() R106Token("BQ") {}

    function blockAddress(address a) external {
        blocked = a;
    }

    function balanceOf(address a) public view override returns (uint256) {
        require(a != blocked, "blocked");
        return super.balanceOf(a);
    }
}

/// @notice The tax hook converts an auto-basket tracker's pending pool, and then pushes the result, at the end of
/// ordinary swaps -- no keeper.
contract Round108HookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 constant FLAG_MASK = (1 << 14) - 1;

    IPoolManager pm;
    PoolModifyLiquidityTest lp;
    PoolSwapTest swapper;
    RealmAnyPairsTaxHookPairImmutable hook;
    R106Token quote;
    R106Token stock;
    address coinAddr = makeAddr("coin");
    address alice = makeAddr("alice");

    function setUp() public {
        pm = IPoolManager(deployCode("artifacts/TestPoolManager.json", abi.encode(address(this))));
        lp = new PoolModifyLiquidityTest(pm);
        swapper = new PoolSwapTest(pm);
        quote = new R106Token("USDG");
        stock = new R106Token("xSTOCK");
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
        quote.approve(address(lp), type(uint256).max);
        stock.approve(address(lp), type(uint256).max);
        quote.approve(address(swapper), type(uint256).max);

        bytes memory init = abi.encodePacked(
            type(RealmAnyPairsTaxHookPairImmutable).creationCode, abi.encode(pm, address(this), makeAddr("platform"))
        );
        bytes32 initHash = keccak256(init);
        uint256 salt;
        for (;; ++salt) {
            if (uint160(vm.computeCreate2Address(bytes32(salt), initHash, address(this))) & FLAG_MASK == FLAGS) {
                break;
            }
        }
        hook = new RealmAnyPairsTaxHookPairImmutable{salt: bytes32(salt)}(pm, address(this), makeAddr("platform"));
        hook.setLauncher(address(this), true);

        // The stock market the rewards convert through: hookless, so discoverable.
        (address s0, address s1) =
            address(quote) < address(stock) ? (address(quote), address(stock)) : (address(stock), address(quote));
        PoolKey memory sk = PoolKey(Currency.wrap(s0), Currency.wrap(s1), 2500, 25, IHooks(address(0)));
        pm.initialize(sk, TickMath.getSqrtPriceAtTick(0));
        lp.modifyLiquidity(sk, ModifyLiquidityParams(-60000, 60000, 1e24, bytes32(0)), "");
    }

    function _launch(address tracker) internal returns (PoolKey memory key) {
        RealmAnyPairsTokenPlain coin =
            new RealmAnyPairsTokenPlain("C", "C", 1e30, address(this), address(this), 0, 0, new address[](0));
        coin.approve(address(lp), type(uint256).max);
        (address c0, address c1) =
            address(coin) < address(quote) ? (address(coin), address(quote)) : (address(quote), address(coin));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(hook)));
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));
        RealmAnyPairsTaxHookPairImmutable.ConfigParams memory p;
        p.creator = address(this);
        p.buyBps = 300;
        p.sellBps = 300;
        p.autoThreshold = type(uint80).max;
        p.rewardsTracker = tracker;
        p.rewardsBps = tracker == address(0) ? 0 : 2000;
        hook.configurePool(key, p);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 1e25, bytes32(0)), "");
    }

    function _autoTracker() internal returns (AB t) {
        AB.Leg[] memory legs = new AB.Leg[](1);
        legs[0] = AB.Leg(address(stock), 10_000);
        AB.InputBasket[] memory ins = new AB.InputBasket[](1);
        ins[0] = AB.InputBasket(address(quote), legs);
        AB.Config memory c;
        c.token = coinAddr; // stands in for the coin: only `setBalance` is gated on it
        c.feeder = address(hook);
        c.poolManager = address(pm);
        c.minEligible = 1;
        c.excluded = new address[](0);
        c.inputs = ins;
        t = new AB(c);
        vm.prank(coinAddr);
        t.setBalance(alice, 1e18);
    }

    function _buy(PoolKey memory key) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(quote);
        swapper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e18),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_swapsConvertThenAutoSend() public {
        AB t = _autoTracker();
        PoolKey memory key = _launch(address(t));
        assertTrue(hook.configOf(key.toId()).rewardsAutoConvert, "configurePool detected the auto-converting tracker");

        quote.transfer(address(t), 1e18);
        t.sync();
        assertEq(t.buffered(address(quote)), 1e18);

        _buy(key);
        assertEq(t.buffered(address(quote)), 0, "the first swap's afterSwap converted it");
        assertGt(t.claimableOf(alice, address(stock)), 0.99e18, "alice's share is now the stock");
        assertEq(stock.balanceOf(alice), 0);

        _buy(key);
        assertGt(stock.balanceOf(alice), 0.99e18, "the next swap pushed it to her, in-swap");
    }

    function test_aQuoteWhoseBalanceOfRevertsForTheTrackerFallsBackToOwed() public {
        BlockingQuote bq = new BlockingQuote();
        quote = bq;
        quote.mint(address(this), 1e36);
        quote.approve(address(lp), type(uint256).max);
        quote.approve(address(swapper), type(uint256).max);
        AB t = _autoTracker();
        bq.blockAddress(address(t));
        PoolKey memory key = _launch(address(t));
        _buy(key);
        assertGt(hook.accruedQuote(key.toId()), 0);
        hook.distribute(key.toId()); // must not revert on the tracker's blocked `balanceOf`
        assertGt(hook.owed(address(t), address(quote)), 0, "the rewards slice fell back to the pull ledger");
    }

    function test_aPlainRewardsPoolIsNotFlagged() public {
        PoolKey memory key = _launch(address(0));
        assertFalse(hook.configOf(key.toId()).rewardsAutoConvert);
        _buy(key);
    }
}
