// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets, IEtfV3Pool} from "src/etf/RealmEtfAssets.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";
import {RealmEtfHook} from "src/etf/RealmEtfHook.sol";
import {DeploymentAddressesRobinhoodMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";

interface IV2FactoryCreate {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IV2PairMint {
    function mint(address to) external returns (uint256 liquidity);
}

interface IV3FactoryCreate {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolMint {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @notice ETF ETFs on a Robinhood mainnet fork: real rStocks on their real USDG pools (SPY and META on
///         V4, NVDA and QQQ on V3).
contract RealmEtfTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant BLOCKNUMBER = 92_800_000;
    address constant USDG = Mainnet.USDG;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant NVDA_V3 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant QQQ_V3 = 0xD60A5d14dB690B7Afad71F76B108071D7175597d;
    /// @dev The USDG/WETH V3 pool: a real Uniswap pool, but not against SPY.
    address constant USDG_WETH_V3 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    uint256 constant SEED = 1_000e6;

    IPoolManager manager = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    RealmEtfAssets registry;
    RealmEtfFactory factory;
    RealmEtfHook hook;
    RealmEtf etf;
    PoolKey etfKey;
    PoolSwapTest router;

    address owner = makeAddr("owner");
    address approver = makeAddr("approver");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        installKeepersRegistry(owner, keeper);
        registry = new RealmEtfAssets(owner, address(manager), Mainnet.UNIV3_FACTORY, Mainnet.UNIV2_FACTORY, USDG);
        vm.prank(owner);
        registry.setApprover(approver, true);
        vm.startPrank(approver);
        registry.setRoute(SPY, _v4Route(SPY));
        registry.setRoute(META, _v4Route(META));
        registry.setRoute(NVDA, _v3Route(NVDA_V3));
        registry.setRoute(QQQ, _v3Route(QQQ_V3));
        vm.stopPrank();

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) | (uint160(0x4444) << 144)
        );
        factory = RealmEtfFactory(
            address(
                new ERC1967Proxy(
                    address(new RealmEtfFactory(registry)), abi.encodeCall(RealmEtfFactory.initialize, (owner))
                )
            )
        );
        deployCodeTo("RealmEtfHook.sol:RealmEtfHook", abi.encode(manager, factory), hookAddress);
        hook = RealmEtfHook(hookAddress);
        vm.prank(owner);
        factory.setHook(address(hook));

        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (SPY, META, NVDA);
        uint16[] memory weights = new uint16[](3);
        (weights[0], weights[1], weights[2]) = (5_000, 3_000, 2_000);
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        etf = RealmEtf(factory.createEtf("Tech ETF", "TECH", RealmEtf.Mode.FLEXIBLE, assets, weights, SEED, 0));
        vm.stopPrank();

        etfKey = _key(address(etf), USDG, 0, 1, address(hook));
        router = new PoolSwapTest(manager);
    }

    //////////////////////// creation //////////////////////

    function test_createEtf_seedsByWeightsAndMintsDeadShares() public view {
        assertEq(etf.owner(), creator);
        assertEq(etf.balanceOf(etf.DEAD()), etf.DEAD_SHARES());
        assertEq(etf.balanceOf(creator), 1_000e18 - etf.DEAD_SHARES());
        assertTrue(factory.isEtf(address(etf)));
        // Bought at market: worth the seed, less fees and impact.
        assertApproxEqRel(etf.totalAssets(), SEED, 0.03e18);
    }

    function test_createEtf_rejectsUnlistedAsset() public {
        address[] memory assets = new address[](1);
        assets[0] = USDG;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        factory.createEtf("X", "X", RealmEtf.Mode.FIXED, assets, weights, SEED, 0);
    }

    function test_createEtf_enforcesOwnerSetMinSeed() public {
        assertEq(factory.minSeedAssets(), 1_000e6);
        address[] memory assets = new address[](1);
        assets[0] = SPY;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(RealmEtfFactory.SeedTooSmall.selector);
        factory.createEtf("X", "X", RealmEtf.Mode.FIXED, assets, weights, SEED - 1, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setMinSeedAssets(0);

        vm.prank(owner);
        factory.setMinSeedAssets(SEED + 1);
        vm.expectRevert(RealmEtfFactory.SeedTooSmall.selector);
        factory.createEtf("X", "X", RealmEtf.Mode.FIXED, assets, weights, SEED, 0);
    }

    //////////////////////// deposit / redeem //////////////////////

    function test_deposit_mintsTheSmallestFractionAdded() public {
        address[] memory assets = etf.getAssets();
        uint256[] memory before = _balances(assets);
        uint256 supply = etf.totalSupply();

        uint256 shares = _deposit(alice, 1_000e6);

        assertEq(etf.balanceOf(alice), shares);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        // Every holding grew by at least the fraction of supply minted.
        uint256[] memory afterBalances = _balances(assets);
        for (uint256 i; i < assets.length; ++i) {
            assertGe(afterBalances[i] * supply, before[i] * (supply + shares));
        }
    }

    function test_deposit_revertsBelowMinShares() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(etf), 1_000e6);
        vm.expectRevert(RealmEtf.Slippage.selector);
        etf.deposit(1_000e6, alice, 1_100e18);
        vm.stopPrank();
    }

    /// @dev An asset priced at ~0 gets a 0-USDG fair slice. Skipping it would mint shares that claim its
    ///      holding for free; bought with `MIN_SLICE` at the crashed price instead, it grows by at least the
    ///      fraction minted, like every other holding, so the holders lose nothing to the crash.
    function test_deposit_buysACrashedAssetSoHoldersAreNotDiluted() public {
        _crashV4Price(META, 1e24);
        address[] memory assets = etf.getAssets();
        uint256[] memory before = _balances(assets);
        uint256 supply = etf.totalSupply();

        uint256 shares = _deposit(alice, 1_000e6);

        uint256[] memory afterBalances = _balances(assets);
        for (uint256 i; i < assets.length; ++i) {
            assertGe(afterBalances[i] * supply, before[i] * (supply + shares));
        }
    }

    /// @dev Two 1-bps rebalances leave QQQ at ~1e-8 of NAV: a 1 USDG deposit's fair slice of it rounds to 0.
    ///      It is bought with `MIN_SLICE` instead, so the deposit neither reverts nor skips it.
    function test_deposit_buysADustHoldingWithTheMinimumSlice() public {
        _rebalance(NVDA, 1, QQQ);
        _rebalance(QQQ, 9_999, NVDA);
        uint256 qqqBefore = IERC20(QQQ).balanceOf(address(etf));
        assertEq(1e6 * registry.usdgValueOf(QQQ, qqqBefore) / etf.totalAssets(), 0);

        uint256 shares = _deposit(alice, 1e6);

        assertGt(shares, 0);
        assertGt(IERC20(QQQ).balanceOf(address(etf)), qqqBefore);
    }

    function test_deposit_revertsBelowTheMinimumSlicePerHolding() public {
        uint256 tooSmall = etf.getAssets().length * etf.MIN_SLICE() - 1;
        _expectDepositRevert(etf, tooSmall, RealmEtf.ZeroAmount.selector);
    }

    /// @dev A slice bigger than its route pool can take would fill partially and strand the rest of the USDG
    ///      in the vault, uncounted. Real pools hold full-range positions, which take more than `deal` can
    ///      hand out, so this uses thin pools: one position of ±600 ticks, on V4 and on V3.
    function test_deposit_revertsWhenARoutePoolCannotFillTheSlice() public {
        _expectDepositRevert(_singleAssetEtf(_thinRouteAsset(false)), 1e18, RealmEtf.InsufficientLiquidity.selector);
        _expectDepositRevert(_singleAssetEtf(_thinRouteAsset(true)), 1e18, RealmEtf.InsufficientLiquidity.selector);
    }

    function test_redeem_paysUsdgForAProRataSlice() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        uint256 out = etf.redeem(shares, alice, alice, 0);
        assertEq(IERC20(USDG).balanceOf(alice), out);
        assertApproxEqRel(out, 1_000e6, 0.03e18);
        assertEq(etf.balanceOf(alice), 0);
    }

    function test_redeem_revertsBelowMinAssets() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(RealmEtf.Slippage.selector);
        etf.redeem(shares, alice, alice, 1_000e6);
    }

    function test_redeemInKind_sendsEveryAssetProRata() public {
        address[] memory assets = etf.getAssets();
        uint256[] memory held = _balances(assets);
        uint256 supply = etf.totalSupply();
        uint256 shares = etf.balanceOf(creator) / 2;

        vm.prank(creator);
        uint256[] memory amounts = etf.redeemInKind(shares, alice, creator);

        for (uint256 i; i < assets.length; ++i) {
            assertEq(amounts[i], held[i] * shares / supply);
            assertEq(IERC20(assets[i]).balanceOf(alice), amounts[i]);
        }
    }

    function test_withdraw_isUnsupported() public {
        assertEq(etf.maxWithdraw(alice), 0);
        vm.expectRevert(RealmEtf.NotSupported.selector);
        etf.withdraw(1, alice, alice);
    }

    //////////////////////// rebalance //////////////////////

    function test_rebalance_onlyCreatorProposes() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        etf.proposeRebalance(NVDA, 10_000, QQQ);
    }

    function test_rebalance_onlyKeeperExecutes() public {
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        vm.prank(creator);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        etf.executeRebalance(NVDA, 10_000, QQQ);
    }

    function test_rebalance_sellingAllRemovesAndBuyingNewAdds() public {
        uint256 valueBefore = etf.totalAssets();
        uint256 bought = _rebalance(NVDA, 10_000, QQQ);

        address[] memory assets = etf.getAssets();
        assertEq(assets.length, 3);
        assertEq(IERC20(NVDA).balanceOf(address(etf)), 0);
        assertEq(IERC20(QQQ).balanceOf(address(etf)), bought);
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(assets[i] != NVDA);
        }
        assertApproxEqRel(etf.totalAssets(), valueBefore, 0.03e18);
    }

    /// @dev The intent is a share of the holding AT EXECUTION, so a deposit in between does not make it stale.
    function test_rebalance_sellsBpsOfTheHoldingAtExecution() public {
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 5_000, QQQ);
        _deposit(alice, 1_000e6);
        uint256 nvda = IERC20(NVDA).balanceOf(address(etf));
        vm.prank(keeper);
        etf.executeRebalance(NVDA, 5_000, QQQ);
        assertEq(IERC20(NVDA).balanceOf(address(etf)), nvda - nvda * 5_000 / 10_000);
    }

    function test_rebalance_aProposalReplacesTheLastAndExecutesOnce() public {
        vm.startPrank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        etf.proposeRebalance(META, 1_000, QQQ);
        vm.stopPrank();
        (address sellAsset, uint16 sellBps,) = etf.pendingRebalance();
        assertEq(sellAsset, META);
        assertEq(sellBps, 1_000);

        vm.startPrank(keeper);
        etf.executeRebalance(META, 1_000, QQQ);
        assertGt(IERC20(NVDA).balanceOf(address(etf)), 0);
        vm.expectRevert(RealmEtf.NoPendingRebalance.selector);
        etf.executeRebalance(META, 1_000, QQQ);
        vm.stopPrank();
    }

    /// @dev The keeper vetted one intent; the creator swapped in another before execution landed.
    function test_rebalance_revertsWhenTheIntentChangedSinceTheKeeperVettedIt() public {
        vm.prank(creator);
        etf.proposeRebalance(META, 1_000, QQQ);
        (address sellAsset, uint16 sellBps, address buyAsset) = etf.pendingRebalance();
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);

        vm.prank(keeper);
        vm.expectRevert(RealmEtf.RebalanceIntentChanged.selector);
        etf.executeRebalance(sellAsset, sellBps, buyAsset);
    }

    function test_rebalance_creatorCancels() public {
        vm.startPrank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        etf.cancelRebalance();
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(RealmEtf.NoPendingRebalance.selector);
        etf.executeRebalance(NVDA, 10_000, QQQ);
    }

    function test_rebalance_rejectsBpsAboveTheWholeHolding() public {
        vm.prank(creator);
        vm.expectRevert(RealmEtf.InvalidWeights.selector);
        etf.proposeRebalance(NVDA, 10_001, QQQ);
    }

    /// @dev 1 wei of NVDA sells for 0 USDG. Adding QQQ with a zero balance would make every deposit divide by 0.
    function test_rebalance_revertsWhenNothingIsBought() public {
        deal(NVDA, address(etf), 1);
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        vm.prank(keeper);
        vm.expectRevert(RealmEtf.ZeroAmount.selector);
        etf.executeRebalance(NVDA, 10_000, QQQ);
    }

    /// @dev The checks run again at execution: a listing that changed since the proposal blocks it.
    function test_rebalance_rechecksAtExecution() public {
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        vm.prank(approver);
        registry.setListed(QQQ, false);
        vm.prank(keeper);
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        etf.executeRebalance(NVDA, 10_000, QQQ);
    }

    function test_mode_fixedRejectsEveryRebalance() public {
        RealmEtf fixedEtf = _modeEtf(RealmEtf.Mode.FIXED);
        assertEq(uint8(fixedEtf.MODE()), uint8(RealmEtf.Mode.FIXED));
        vm.prank(creator);
        vm.expectRevert(RealmEtf.NotSupported.selector);
        fixedEtf.proposeRebalance(NVDA, 10_000, SPY);
    }

    /// @dev A `REBALANCE` ETF never buys a new asset, but can buy back an original one it sold out of.
    function test_mode_rebalanceStaysWithinTheOriginalAssets() public {
        RealmEtf e = _modeEtf(RealmEtf.Mode.REBALANCE);
        assertTrue(e.isOriginal(SPY) && e.isOriginal(NVDA) && !e.isOriginal(QQQ));
        vm.prank(creator);
        vm.expectRevert(RealmEtf.NotOriginalAsset.selector);
        e.proposeRebalance(NVDA, 10_000, QQQ);

        _rebalanceOn(e, NVDA, 10_000, SPY);
        assertEq(e.getAssets().length, 1);
        _rebalanceOn(e, SPY, 2_000, NVDA);
        assertEq(e.getAssets().length, 2);
        assertGt(IERC20(NVDA).balanceOf(address(e)), 0);
    }

    function test_mode_flexibleBuysAnyListedAsset() public {
        _rebalance(NVDA, 5_000, QQQ);
        assertEq(etf.getAssets().length, 4);
    }

    //////////////////////// hook //////////////////////

    function test_hook_buyThroughThePoolMintsShares() public {
        vm.recordLogs();
        uint256 shares = _swap(alice, USDG, 1_000e6);
        assertEq(etf.balanceOf(alice), shares);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        _assertJit(1_000e6, shares);
    }

    function test_hook_sellThroughThePoolRedeemsForUsdg() public {
        uint256 shares = etf.balanceOf(creator) / 2;
        uint256 supply = etf.totalSupply();
        vm.recordLogs();
        uint256 out = _swap(creator, address(etf), shares);
        // The sold shares sit in the pool manager behind the hook's claims, out of circulation, but for the
        // few raw units the JIT position's removal rounded away.
        assertApproxEqAbs(etf.totalSupply(), supply - shares, 1e6);
        assertEq(etf.balanceOf(address(manager)), shares);
        assertEq(IERC20(USDG).balanceOf(creator), out);
        assertApproxEqRel(out, 500e6, 0.03e18);
        _assertJit(shares, out);
    }

    function test_redeemOnCredit_onlyTheHook() public {
        vm.prank(creator);
        vm.expectRevert(RealmEtf.Unauthorized.selector);
        etf.redeemOnCredit(1e18, creator);
    }

    /// @dev Exact USDG out has no one-pass solution; only exact-output BUYS are filled.
    function test_hook_rejectsExactOutputSells() public {
        uint256 shares = etf.balanceOf(creator);
        vm.startPrank(creator);
        etf.approve(address(router), shares);
        vm.expectRevert();
        router.swap(etfKey, _params(address(etf), 1e6, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    function test_hook_exactOutputBuyMintsExactlyTheShares() public {
        deal(USDG, alice, 1_000e6);
        uint256 supply = etf.totalSupply();
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.recordLogs();
        router.swap(etfKey, _params(USDG, 100e18, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        assertEq(etf.balanceOf(alice), 100e18);
        // The extra shares minted for the JIT rounding are locked as claims, but for what the removal rounded away.
        assertApproxEqAbs(etf.totalSupply(), supply + 100e18, 1e6);
        uint256 paid = 1_000e6 - IERC20(USDG).balanceOf(alice);
        assertApproxEqRel(paid, 100e6, 0.03e18);
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0);
        _assertJit(paid, 100e18);
    }

    function test_hook_rejectsLiquidity() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.expectRevert();
        lp.modifyLiquidity(etfKey, ModifyLiquidityParams(-60, 60, 1e18, 0), "");
    }

    function test_hook_poolOpensAtTheSeedPrice() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(etfKey.toId());
        uint256 usdgPerShareX18 = Currency.unwrap(etfKey.currency0) == USDG
            ? 1e36 / Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 192) / 1e6
            : Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), 1e30, 1 << 96);
        assertApproxEqRel(usdgPerShareX18, 1e18, 0.001e18);
    }

    function test_hook_successiveTradesEachGoThroughTheCurve() public {
        vm.recordLogs();
        uint256 shares = _swap(alice, USDG, 2_000e6);
        _assertJit(2_000e6, shares);
        vm.recordLogs();
        uint256 out = _swap(alice, address(etf), shares / 3);
        _assertJit(shares / 3, out);
        vm.recordLogs();
        uint256 more = _swap(alice, USDG, 50e6);
        _assertJit(50e6, more);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_hook_buyAndSellThroughTheCurve(uint256 usdg, uint256 sellBps) public {
        usdg = bound(usdg, 1e6, 20_000e6);
        vm.recordLogs();
        uint256 shares = _swap(alice, USDG, usdg);
        _assertJit(usdg, shares);
        uint256 sold = shares * bound(sellBps, 1, 10_000) / 10_000;
        vm.assume(sold != 0);
        vm.recordLogs();
        uint256 out = _swap(alice, address(etf), sold);
        _assertJit(sold, out);
    }

    function test_hook_buyFillsTheSameFromEveryStartingPrice() public {
        _assertEveryStartingPrice(alice, USDG, 1_000e6);
    }

    function test_hook_sellFillsTheSameFromEveryStartingPrice() public {
        _assertEveryStartingPrice(creator, address(etf), etf.balanceOf(creator) / 4);
    }

    /// @dev The other orientation: USDG is token0, so buys move the price down and sells up.
    function test_hook_usdgAsToken0_buyFillsTheSameFromEveryStartingPrice() public {
        _useEtfAboveUsdg();
        _assertEveryStartingPrice(alice, USDG, 1_000e6);
    }

    function test_hook_usdgAsToken0_sellFillsTheSameFromEveryStartingPrice() public {
        _useEtfAboveUsdg();
        _assertEveryStartingPrice(creator, address(etf), etf.balanceOf(creator) / 4);
    }

    function test_hook_usdgAsToken0_exactOutputBuy() public {
        _useEtfAboveUsdg();
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.recordLogs();
        router.swap(etfKey, _params(USDG, 100e18, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        assertEq(etf.balanceOf(alice), 100e18);
        _assertJit(1_000e6 - IERC20(USDG).balanceOf(alice), 100e18);
    }

    /// @dev A price limit inside the JIT range stops the curve short of what the position was sized for.
    function test_hook_revertsWhenAPriceLimitCutsTheCurveShort() public {
        uint256 snap = vm.snapshotState();
        _swap(alice, USDG, 1_000e6);
        (uint160 end,,,) = manager.getSlot0(etfKey.toId());
        vm.revertToState(snap);

        deal(USDG, alice, 1_000e6);
        SwapParams memory params = _params(USDG, 1_000e6, true);
        params.sqrtPriceLimitX96 = params.zeroForOne ? end + 1 : end - 1;
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(RealmEtfHook.JitMismatch.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(etfKey, params, PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    /// @dev With a protocol fee on the pool the curve would charge it, so the hook fills the whole trade itself.
    function test_hook_protocolFeeFallsBackToTheHookFill() public {
        vm.prank(manager.protocolFeeController());
        manager.setProtocolFee(etfKey, (uint24(500) << 12) | 500);
        uint256 shares = _swap(alice, USDG, 1_000e6);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        assertEq(manager.getLiquidity(etfKey.toId()), 0);
    }

    function test_hook_rejectsPoolsOfNonEtfs() public {
        vm.expectRevert();
        manager.initialize(_key(SPY, USDG, 0, 1, address(hook)), uint160(1 << 96));
    }

    //////////////////////// mint //////////////////////

    /// @dev Every holding grows by at least the fraction of supply minted; the payer pays only what it spent.
    function test_mint_buysExactlyTheProRataGrowth() public {
        address[] memory assets = etf.getAssets();
        uint256[] memory before = _balances(assets);
        uint256 supply = etf.totalSupply();
        uint256 estimate = etf.previewMint(100e18);
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(etf), 1_000e6);
        uint256 paid = etf.mint(100e18, alice);
        vm.stopPrank();

        assertEq(etf.balanceOf(alice), 100e18);
        assertEq(IERC20(USDG).balanceOf(alice), 1_000e6 - paid);
        assertEq(IERC20(USDG).balanceOf(address(etf)), 0);
        assertApproxEqRel(paid, estimate, 0.03e18);
        uint256[] memory afterBalances = _balances(assets);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(afterBalances[i] - before[i], (100e18 * before[i] + supply - 1) / supply);
        }
    }

    function test_mint_revertsAboveMaxAssets() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(etf), 1_000e6);
        vm.expectRevert(RealmEtf.Slippage.selector);
        etf.mint(100e18, alice, 50e6);
        vm.stopPrank();
    }

    /// @dev An exact-output swap the route pool cannot fill buys less than the mint needs: it reverts.
    function test_mint_revertsWhenARoutePoolCannotFillTheOutput() public {
        _expectMintRevert(_singleAssetEtf(_thinRouteAsset(false)));
        _expectMintRevert(_singleAssetEtf(_thinRouteAsset(true)));
    }

    //////////////////////// in-kind redemption //////////////////////

    function test_redeemInKind_revertsWhenATransferFails() public {
        vm.mockCallRevert(META, abi.encodeWithSelector(IERC20.transfer.selector), "paused");
        vm.prank(creator);
        vm.expectRevert();
        etf.redeemInKind(1e18, alice, creator);
    }

    /// @dev The redeemer forfeits META explicitly: its slice stays in the vault, the rest is sent.
    function test_redeemInKind_skipMaskForfeitsTheMaskedAssets() public {
        vm.mockCallRevert(META, abi.encodeWithSelector(IERC20.transfer.selector), "paused");
        address[] memory assets = etf.getAssets();
        uint256 metaIndex = assets[0] == META ? 0 : assets[1] == META ? 1 : 2;
        uint256 metaBefore = IERC20(META).balanceOf(address(etf));
        uint256 shares = etf.balanceOf(creator) / 2;

        vm.prank(creator);
        uint256[] memory amounts = etf.redeemInKind(shares, alice, creator, 1 << metaIndex);

        vm.clearMockedCalls();
        assertEq(amounts[metaIndex], 0);
        assertEq(IERC20(META).balanceOf(address(etf)), metaBefore);
        for (uint256 i; i < assets.length; ++i) {
            if (i != metaIndex) assertGt(IERC20(assets[i]).balanceOf(alice), 0);
        }
    }

    //////////////////////// sunset //////////////////////

    function test_sunset_onlyOwner() public {
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, approver));
        registry.sunset(META);
    }

    /// @dev A sunset asset is neither valued, bought, nor sold, but still goes out in kind.
    function test_sunset_excludesTheAssetFromEverythingButInKind() public {
        uint256 metaValue = registry.usdgValueOf(META, IERC20(META).balanceOf(address(etf)));
        uint256 navBefore = etf.totalAssets();
        vm.prank(owner);
        registry.sunset(META);
        assertApproxEqAbs(etf.totalAssets(), navBefore - metaValue, 1);

        uint256 meta = IERC20(META).balanceOf(address(etf));
        uint256 shares = _deposit(alice, 1_000e6);
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(etf), 1_000e6);
        etf.mint(10e18, alice);
        etf.redeem(shares, alice, alice);
        vm.stopPrank();
        _swap(alice, USDG, 100e6);
        _swap(creator, address(etf), 1e18);
        assertEq(IERC20(META).balanceOf(address(etf)), meta);

        vm.prank(creator);
        etf.redeemInKind(1e18, alice, creator);
        assertGt(IERC20(META).balanceOf(alice), 0);
    }

    function test_sunset_blocksRebalancesAndCreation() public {
        vm.prank(owner);
        registry.sunset(META);
        vm.startPrank(creator);
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        etf.proposeRebalance(META, 10_000, QQQ);
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        etf.proposeRebalance(NVDA, 10_000, META);
        vm.stopPrank();

        address[] memory assets = new address[](1);
        assets[0] = META;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        factory.createEtf("X", "X", RealmEtf.Mode.FIXED, assets, weights, SEED, 0);
    }

    //////////////////////// reinvest //////////////////////

    /// @dev USDG airdropped to the ETF buys the live holdings and mints nothing: NAV per share rises.
    function test_reinvest_buysTheLiveHoldingsWithStrayUsdg() public {
        vm.prank(owner);
        registry.sunset(META);
        uint256 meta = IERC20(META).balanceOf(address(etf));
        uint256 supply = etf.totalSupply();
        uint256 navBefore = etf.totalAssets();
        deal(USDG, address(etf), 100e6);

        vm.prank(keeper);
        assertEq(etf.reinvest(), 100e6);

        assertEq(IERC20(USDG).balanceOf(address(etf)), 0);
        assertEq(IERC20(META).balanceOf(address(etf)), meta);
        assertEq(etf.totalSupply(), supply);
        assertApproxEqRel(etf.totalAssets(), navBefore + 100e6, 0.01e18);
    }

    function test_reinvest_onlyKeeper() public {
        vm.prank(alice);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        etf.reinvest();
    }

    //////////////////////// registry //////////////////////

    function test_registry_onlyApproverSetsRoutes() public {
        RealmEtfAssets.Route memory route = _v4Route(SPY);
        vm.prank(alice);
        vm.expectRevert(RealmEtfAssets.NotApprover.selector);
        registry.setRoute(SPY, route);
    }

    function test_registry_rejectsPoolNotAgainstUsdg() public {
        RealmEtfAssets.Route memory route = _v3Route(USDG_WETH_V3);
        vm.prank(approver);
        vm.expectRevert(RealmEtfAssets.InvalidRoute.selector);
        registry.setRoute(SPY, route);
    }

    /// @dev The ETF treats every asset as an ERC20; a native-currency pool would brick it.
    function test_registry_rejectsNativeCurrencyAsAsset() public {
        PoolKey memory key = _key(address(0), USDG, 3000, 60, address(0));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) manager.initialize(key, uint160(1 << 96));
        RealmEtfAssets.Route memory route;
        route.venue = RealmEtfAssets.Venue.V4;
        route.key = key;
        vm.prank(approver);
        vm.expectRevert(RealmEtfAssets.InvalidRoute.selector);
        registry.setRoute(address(0), route);
    }

    function test_registry_rejectsUnfundedV2Pair() public {
        address asset = address(new ERC20Mock());
        RealmEtfAssets.Route memory route;
        route.venue = RealmEtfAssets.Venue.V2;
        route.pool = IV2FactoryCreate(Mainnet.UNIV2_FACTORY).createPair(asset, USDG);
        vm.prank(approver);
        vm.expectRevert(RealmEtfAssets.InvalidRoute.selector);
        registry.setRoute(asset, route);
    }

    /// @dev A V2-routed asset goes through every swap path: exact-input deposit, exact-output mint, redeem.
    function test_v2Route_depositMintRedeem() public {
        address asset = _v2RouteAsset();
        // 1M whole tokens against 1M USDG: one token is worth one USDG.
        assertEq(registry.usdgValueOf(asset, 1e18), 1e6);
        RealmEtf e = _singleAssetEtf(asset);

        deal(USDG, alice, 2_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(e), 2_000e6);
        uint256 shares = e.deposit(1_000e6, alice);
        uint256 held = IERC20(asset).balanceOf(address(e));
        uint256 supply = e.totalSupply();
        e.mint(100e18, alice);
        assertGe(IERC20(asset).balanceOf(address(e)) - held, Math.mulDiv(held, 100e18, supply));
        uint256 out = e.redeem(shares + 100e18, alice, alice, 0);
        vm.stopPrank();

        assertEq(IERC20(USDG).balanceOf(address(e)), 0);
        assertApproxEqRel(out, 1_100e6, 0.02e18);
    }

    function test_registry_valuesAtRouteSpotPrice() public view {
        // A whole SPY, in raw USDG (6 decimals): an index fund share trades in the hundreds of dollars.
        uint256 value = registry.usdgValueOf(SPY, 1e18);
        assertGt(value, 100e6);
        assertLt(value, 2_000e6);
    }

    //////////////////////// factory //////////////////////

    function test_factory_onlyOwnerSetsHook() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setHook(alice);
    }

    function test_factory_onlyOwnerUpgradesAndStateSurvives() public {
        address impl = address(new RealmEtfFactory(registry));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.upgradeToAndCall(impl, "");

        vm.prank(owner);
        factory.upgradeToAndCall(impl, "");
        assertTrue(factory.isEtf(address(etf)));
        assertEq(factory.hook(), address(hook));
    }

    function test_hook_rejectsEtfsCreatedWithAnotherHook() public {
        vm.prank(owner);
        factory.setHook(address(0));
        address[] memory assets = new address[](1);
        assets[0] = SPY;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        address other = factory.createEtf("No Hook", "NOHK", RealmEtf.Mode.FIXED, assets, weights, SEED, 0);
        vm.stopPrank();
        vm.expectRevert();
        manager.initialize(_key(other, USDG, 0, 1, address(hook)), uint160(1 << 96));
    }

    function test_registry_delistingBlocksBuyingInButNotExiting() public {
        vm.prank(approver);
        registry.setListed(QQQ, false);
        vm.prank(creator);
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        etf.proposeRebalance(NVDA, 10_000, QQQ);

        vm.prank(approver);
        registry.setListed(NVDA, false);
        uint256 shares = etf.balanceOf(creator);
        vm.prank(creator);
        assertGt(etf.redeem(shares, creator, creator), 0);
    }

    //////////////////////// NavUpdated //////////////////////

    function test_nav_seed() public {
        vm.recordLogs();
        RealmEtf e = _modeEtf(RealmEtf.Mode.FIXED);
        assertEq(_assertNav(e, RealmEtf.Seeded.selector).totalSupply, e.totalSupply());
    }

    function test_nav_deposit() public {
        vm.recordLogs();
        _deposit(alice, 1_000e6);
        assertEq(_assertNav(etf, IERC4626.Deposit.selector).totalSupply, etf.totalSupply());
    }

    function test_nav_mint() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(etf), 1_000e6);
        vm.recordLogs();
        etf.mint(100e18, alice);
        vm.stopPrank();
        assertEq(_assertNav(etf, IERC4626.Deposit.selector).totalSupply, etf.totalSupply());
    }

    function test_nav_redeem() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.recordLogs();
        etf.redeem(shares, alice, alice);
        assertEq(_assertNav(etf, IERC4626.Withdraw.selector).totalSupply, etf.totalSupply());
    }

    function test_nav_hookBuy() public {
        vm.recordLogs();
        _swap(alice, USDG, 1_000e6);
        assertEq(_assertNav(etf, IERC4626.Deposit.selector).totalSupply, etf.totalSupply());
    }

    /// @dev The sold shares leave `totalSupply` only when the hook locks them, after `redeemOnCredit` returns:
    ///      the event already reports the supply without them. Settled, the supply is higher only by the raw
    ///      shares the JIT removal rounded away, which stay in circulation (126 here).
    function test_nav_hookSellReportsTheSettledSupply() public {
        uint256 supply = etf.totalSupply();
        uint256 shares = etf.balanceOf(creator) / 2;
        vm.recordLogs();
        _swap(creator, address(etf), shares);
        uint256 reported = _assertNav(etf, IERC4626.Withdraw.selector).totalSupply;
        assertEq(reported, supply - shares);
        assertLe(reported, etf.totalSupply());
        assertApproxEqAbs(reported, etf.totalSupply(), 1e6);
    }

    /// @dev Without JIT (a protocol fee on the pool) no rounding dust stays in circulation either.
    function test_nav_hookSellWithoutJitReportsTheSettledSupply() public {
        vm.prank(manager.protocolFeeController());
        manager.setProtocolFee(etfKey, (uint24(500) << 12) | 500);
        uint256 shares = etf.balanceOf(creator) / 2;
        vm.recordLogs();
        _swap(creator, address(etf), shares);
        assertEq(_assertNav(etf, IERC4626.Withdraw.selector).totalSupply, etf.totalSupply());
    }

    /// @dev An exact-output buy mints the hook's share buffer too; what the JIT rounding does not use is locked
    ///      after `mint` returns, so the event counts at most the buffer more than the settled supply.
    function test_nav_hookExactOutputBuyOvercountsAtMostTheShareBuffer() public {
        deal(USDG, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), 1_000e6);
        vm.recordLogs();
        router.swap(etfKey, _params(USDG, 100e18, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        uint256 reported = _assertNav(etf, IERC4626.Deposit.selector).totalSupply;
        assertGe(reported, etf.totalSupply());
        assertLe(reported - etf.totalSupply(), hook.SHARES_BUFFER() + (100e18 >> 40));
    }

    /// @dev Selling all of NVDA for QQQ drops NVDA from the event's assets and adds QQQ.
    function test_nav_rebalanceRemovesAndAddsAssets() public {
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        vm.prank(keeper);
        vm.recordLogs();
        etf.executeRebalance(NVDA, 10_000, QQQ);
        Nav memory nav = _assertNav(etf, RealmEtf.Rebalanced.selector);
        assertEq(nav.totalSupply, etf.totalSupply());
        address[] memory assets = nav.assets;
        bool hasQqq;
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(assets[i] != NVDA);
            hasQqq = hasQqq || assets[i] == QQQ;
        }
        assertTrue(hasQqq);
    }

    /// @dev A sunset asset keeps its balance in the event, valued at 0.
    function test_nav_reinvestValuesSunsetAssetsAtZero() public {
        vm.prank(owner);
        registry.sunset(META);
        deal(USDG, address(etf), 100e6);
        vm.prank(keeper);
        vm.recordLogs();
        etf.reinvest();
        Nav memory nav = _assertNav(etf, RealmEtf.Reinvested.selector);
        assertEq(nav.totalSupply, etf.totalSupply());
        uint256 metaIndex = nav.assets[0] == META ? 0 : nav.assets[1] == META ? 1 : 2;
        assertGt(nav.balances[metaIndex], 0);
        assertEq(nav.usdgValues[metaIndex], 0);
    }

    function test_nav_redeemInKind() public {
        uint256 shares = etf.balanceOf(creator) / 2;
        vm.prank(creator);
        vm.recordLogs();
        etf.redeemInKind(shares, alice, creator);
        assertEq(_assertNav(etf, RealmEtf.RedeemedInKind.selector).totalSupply, etf.totalSupply());
    }

    //////////////////////// helpers //////////////////////

    struct Nav {
        uint256 totalAssets;
        uint256 totalSupply;
        address[] assets;
        uint256[] balances;
        uint256[] usdgValues;
    }

    /// @dev Checks `e`'s one recorded `NavUpdated` against the state now, and that `e`'s log just before it is
    ///      `prior`. The caller checks `totalSupply`: through the hook it can differ by dust.
    function _assertNav(RealmEtf e, bytes32 prior) internal returns (Nav memory nav) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 last;
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(e)) continue;
            if (logs[i].topics[0] == RealmEtf.NavUpdated.selector) {
                assertEq(last, prior, "NavUpdated follows the call's event");
                (nav.totalAssets, nav.totalSupply, nav.assets, nav.balances, nav.usdgValues) =
                    abi.decode(logs[i].data, (uint256, uint256, address[], uint256[], uint256[]));
                ++count;
            }
            last = logs[i].topics[0];
        }
        assertEq(count, 1, "one NavUpdated");

        assertEq(nav.totalAssets, e.totalAssets(), "totalAssets");
        address[] memory held = e.getAssets();
        assertEq(nav.assets, held, "assets");
        uint256 sum;
        for (uint256 i; i < held.length; ++i) {
            assertEq(nav.balances[i], IERC20(held[i]).balanceOf(address(e)), "balance");
            uint256 value = registry.isSunset(held[i]) ? 0 : registry.usdgValueOf(held[i], nav.balances[i]);
            assertEq(nav.usdgValues[i], value, "usdgValue");
            sum += value;
        }
        assertEq(sum, nav.totalAssets, "values sum to totalAssets");
    }

    function _rebalance(address sellAsset, uint16 sellBps, address buyAsset) internal returns (uint256) {
        return _rebalanceOn(etf, sellAsset, sellBps, buyAsset);
    }

    /// @dev The creator proposes, a keeper executes.
    function _rebalanceOn(RealmEtf e, address sellAsset, uint16 sellBps, address buyAsset) internal returns (uint256) {
        vm.prank(creator);
        e.proposeRebalance(sellAsset, sellBps, buyAsset);
        vm.prank(keeper);
        return e.executeRebalance(sellAsset, sellBps, buyAsset);
    }

    /// @dev A SPY + NVDA ETF in `mode`.
    function _modeEtf(RealmEtf.Mode mode) internal returns (RealmEtf) {
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (SPY, NVDA);
        uint16[] memory weights = new uint16[](2);
        (weights[0], weights[1]) = (5_000, 5_000);
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        address e = factory.createEtf("Mode", "MODE", mode, assets, weights, SEED, 0);
        vm.stopPrank();
        return RealmEtf(e);
    }

    /// @dev Mints far more than the thin route pool holds (~3e16 raw of the asset, vs ~1e9 in the ETF).
    function _expectMintRevert(RealmEtf e) internal {
        deal(USDG, alice, 1e18);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(e), type(uint256).max);
        uint256 shares = e.totalSupply() * 1e8;
        vm.expectRevert(RealmEtf.InsufficientLiquidity.selector);
        e.mint(shares, alice);
        vm.stopPrank();
    }

    function _key(address a, address b, uint24 fee, int24 spacing, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(hooks));
    }

    function _v4Route(address asset) internal pure returns (RealmEtfAssets.Route memory r) {
        r.venue = RealmEtfAssets.Venue.V4;
        r.key = _key(asset, USDG, 3000, 60, address(0));
    }

    function _v3Route(address pool) internal pure returns (RealmEtfAssets.Route memory r) {
        r.venue = RealmEtfAssets.Venue.V3;
        r.pool = pool;
    }

    function _balances(address[] memory assets) internal view returns (uint256[] memory b) {
        b = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            b[i] = IERC20(assets[i]).balanceOf(address(etf));
        }
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        deal(USDG, who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(etf), amount);
        shares = etf.deposit(amount, who);
        vm.stopPrank();
    }

    function _expectDepositRevert(RealmEtf e, uint256 amount, bytes4 selector) internal {
        deal(USDG, alice, amount);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(e), amount);
        vm.expectRevert(selector);
        e.deposit(amount, alice);
        vm.stopPrank();
    }

    function _singleAssetEtf(address asset) internal returns (RealmEtf) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(factory), SEED);
        address e = factory.createEtf("One", "ONE", RealmEtf.Mode.FIXED, assets, weights, SEED, 0);
        vm.stopPrank();
        return RealmEtf(e);
    }

    /// @dev A fresh mock asset listed on a fresh USDG pool (V3 or V4) at 1:1 raw, whose only position is
    ///      1e18 liquidity over ±600 ticks: it takes ~3e16 raw of either token before running dry.
    function _thinRouteAsset(bool v3) internal returns (address asset) {
        ERC20Mock tkn = new ERC20Mock();
        asset = address(tkn);
        tkn.mint(address(this), 1e18);
        deal(USDG, address(this), 1e18);
        RealmEtfAssets.Route memory route;
        if (v3) {
            address pool = IV3FactoryCreate(Mainnet.UNIV3_FACTORY).createPool(asset, USDG, 3000);
            IV3PoolMint(pool).initialize(uint160(1 << 96));
            IV3PoolMint(pool).mint(address(this), -600, 600, 1e18, "");
            route.venue = RealmEtfAssets.Venue.V3;
            route.pool = pool;
        } else {
            PoolKey memory key = _key(asset, USDG, 3000, 60, address(0));
            manager.initialize(key, uint160(1 << 96));
            PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
            tkn.approve(address(lp), type(uint256).max);
            IERC20(USDG).approve(address(lp), type(uint256).max);
            lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
            route.venue = RealmEtfAssets.Venue.V4;
            route.key = key;
        }
        vm.prank(approver);
        registry.setRoute(asset, route);
    }

    /// @dev A fresh mock asset listed on a fresh USDG V2 pair holding 1M of each, in whole units.
    function _v2RouteAsset() internal returns (address asset) {
        ERC20Mock tkn = new ERC20Mock();
        asset = address(tkn);
        address pair = IV2FactoryCreate(Mainnet.UNIV2_FACTORY).createPair(asset, USDG);
        tkn.mint(pair, 1_000_000e18);
        deal(USDG, pair, 1_000_000e6);
        IV2PairMint(pair).mint(address(this));
        RealmEtfAssets.Route memory route;
        route.venue = RealmEtfAssets.Venue.V2;
        route.pool = pair;
        vm.prank(approver);
        registry.setRoute(asset, route);
    }

    /// @dev Pays the V3 pool for `_thinRouteAsset`'s mint.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (amount0Owed != 0) IERC20(IEtfV3Pool(msg.sender).token0()).transfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(IEtfV3Pool(msg.sender).token1()).transfer(msg.sender, amount1Owed);
    }

    /// @dev Dumps `amount` of `asset` through its V4 route until the pool runs out of liquidity, which parks
    ///      the price at the limit: `asset` then values at ~0 USDG.
    function _crashV4Price(address asset, uint256 amount) internal {
        PoolKey memory key = _key(asset, USDG, 3000, 60, address(0));
        bool zeroForOne = Currency.unwrap(key.currency0) == asset;
        deal(asset, alice, amount);
        vm.startPrank(alice);
        IERC20(asset).approve(address(router), amount);
        router.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        assertEq(registry.usdgValueOf(asset, IERC20(asset).balanceOf(address(etf))), 0);
    }

    function _params(address tokenIn, uint256 amount, bool exactIn) internal view returns (SwapParams memory) {
        bool zeroForOne = Currency.unwrap(etfKey.currency0) == tokenIn;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Exact-input swap of `amount` `tokenIn` on the ETF pool through a standard router.
    function _swap(address who, address tokenIn, uint256 amount) internal returns (uint256 out) {
        if (tokenIn == USDG) deal(USDG, who, amount);
        address tokenOut = tokenIn == USDG ? address(etf) : USDG;
        uint256 before = IERC20(tokenOut).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(router), amount);
        router.swap(etfKey, _params(tokenIn, amount, true), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(who) - before;
    }

    /// @dev Checks the recorded swap went through the curve: the pool manager's `Swap` carries all but a sliver of
    ///      the trade (`paid` in, `received` out), `HookSwap` the rest, they sum to the trade, the pool ends
    ///      empty and its price within 2 ticks of the trade's.
    function _assertJit(uint256 paid, uint256 received) internal {
        (int128 c0, int128 c1, int128 h0, int128 h1) = _swapEvents();
        (uint256 curveIn, uint256 curveOut) =
            c0 < 0 ? (uint256(int256(-c0)), uint256(int256(c1))) : (uint256(int256(-c1)), uint256(int256(c0)));
        (uint256 hookIn, uint256 hookOut) =
            c0 < 0 ? (uint256(int256(-h0)), uint256(int256(h1))) : (uint256(int256(-h1)), uint256(int256(h0)));
        assertEq(curveIn + hookIn, paid, "paid = curve + hook");
        assertEq(curveOut + hookOut, received, "received = curve + hook");
        assertGe(curveIn * 10_000, paid * 9_997, "curve fills >= 99.97% in");
        assertGe(curveOut * 10_000, received * 9_997, "curve fills >= 99.97% out");
        assertEq(manager.getLiquidity(etfKey.toId()), 0, "pool empty");

        _assertPriceNear(paid, received, c0 < 0);
    }

    /// @dev The pool ends within 2 ticks of the ETF's fill price. The swapper's realised price differs from it by
    ///      the few raw units of rounding dust, ~4e4 / amount ticks, which only shows on tiny trades.
    function _assertPriceNear(uint256 paid, uint256 received, bool inIs0) internal view {
        (, int24 tick,,) = manager.getSlot0(etfKey.toId());
        (uint256 amt1, uint256 amt0) = inIs0 ? (received, paid) : (paid, received);
        int24 tradeTick = TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(Math.mulDiv(amt1, 1 << 192, amt0))));
        int24 tolerance = int24(int256(2 + 40_000 / Math.min(paid, received)));
        assertLe(tick > tradeTick ? tick - tradeTick : tradeTick - tick, tolerance, "slot0 at trade price");
    }

    /// @dev Re-runs one trade from every starting price around the JIT range's starting edge, written straight into
    ///      `slot0`: on the edge with either tick the core can leave there (the edge's own, or the one below as a
    ///      downward swap leaves it), one raw sqrt-price unit above and below it, on the neighbouring edges, and
    ///      across bitmap words. The pool is empty, so the trade must fill identically through the curve each time.
    function _assertEveryStartingPrice(address who, address tokenIn, uint256 amount) internal {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        uint256 expected = _swap(who, tokenIn, amount);
        int24 tickLower = _jitTickLower();
        vm.revertToState(snap);

        bool up = !_params(tokenIn, amount, true).zeroForOne;
        int24 startTick = up ? tickLower : tickLower + 1;
        int24[9] memory offsets = [int24(0), 1, -1, 2, -2, 255, -256, 1000, -1000];
        for (uint256 i; i < offsets.length; ++i) {
            for (uint256 k; k < 4; ++k) {
                uint256 s = vm.snapshotState();
                int24 tick = startTick + offsets[i];
                uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
                if (k == 1) tick -= 1; // on the edge, as a downward swap leaves it
                else if (k == 2) sqrtPriceX96 += 1; // just above the edge
                else if (k == 3) (sqrtPriceX96, tick) = (sqrtPriceX96 - 1, tick - 1); // just below it
                _setSlot0(sqrtPriceX96, tick);

                vm.recordLogs();
                assertEq(_swap(who, tokenIn, amount), expected, "same fill");
                _assertJit(amount, expected);
                vm.revertToState(s);
            }
        }
    }

    /// @dev Creates ETFs like the setUp one until one's address sorts above USDG, and switches the tests to it.
    function _useEtfAboveUsdg() internal {
        address[] memory assets = etf.getAssets();
        uint16[] memory weights = new uint16[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            weights[i] = uint16(10_000 / assets.length);
        }
        weights[0] += uint16(10_000 % assets.length);
        vm.startPrank(creator);
        for (uint256 i; i < 32 && address(etf) < USDG; ++i) {
            deal(USDG, creator, SEED);
            IERC20(USDG).approve(address(factory), SEED);
            etf = RealmEtf(factory.createEtf("Tech ETF", "TECH", RealmEtf.Mode.FLEXIBLE, assets, weights, SEED, 0));
        }
        vm.stopPrank();
        assertTrue(address(etf) > USDG, "no ETF above USDG");
        etfKey = _key(address(etf), USDG, 0, 1, address(hook));
    }

    function _setSlot0(uint160 sqrtPriceX96, int24 tick) internal {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(etfKey.toId()), StateLibrary.POOLS_SLOT));
        vm.store(address(manager), slot, bytes32(uint256(sqrtPriceX96) | uint256(uint24(tick)) << 160));
        (uint160 p, int24 t,,) = manager.getSlot0(etfKey.toId());
        assertEq(p, sqrtPriceX96);
        assertEq(t, tick);
    }

    /// @dev The JIT position's lower tick, from the hook's recorded `ModifyLiquidity`.
    function _jitTickLower() internal returns (int24 tickLower) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == sig) {
                (tickLower,,,) = abi.decode(logs[i].data, (int24, int24, int256, bytes32));
                return tickLower;
            }
        }
        revert("no JIT position");
    }

    /// @dev The last `Swap` of the ETF pool (the curve) and the hook's `HookSwap`, from the recorded logs.
    function _swapEvents() internal returns (int128 c0, int128 c1, int128 h0, int128 h1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(etfKey.toId());
        bytes32 swapSig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length < 2 || logs[i].topics[1] != id) continue;
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == swapSig) {
                (c0, c1) = abi.decode(logs[i].data, (int128, int128));
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == RealmEtfHook.HookSwap.selector) {
                (h0, h1) = abi.decode(logs[i].data, (int128, int128));
            }
        }
        assertTrue(c0 != 0 && c1 != 0, "curve swapped");
    }
}
