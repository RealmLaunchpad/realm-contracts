// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
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
        registry = new RealmEtfAssets(owner, address(manager), Mainnet.UNIV3_FACTORY, USDG);
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
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
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
        manager.initialize(etfKey, uint160(1 << 96));
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
        etf.executeRebalance();
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
        etf.executeRebalance();
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
        etf.executeRebalance();
        assertGt(IERC20(NVDA).balanceOf(address(etf)), 0);
        vm.expectRevert(RealmEtf.NoPendingRebalance.selector);
        etf.executeRebalance();
        vm.stopPrank();
    }

    function test_rebalance_creatorCancels() public {
        vm.startPrank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        etf.cancelRebalance();
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(RealmEtf.NoPendingRebalance.selector);
        etf.executeRebalance();
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
        etf.executeRebalance();
    }

    /// @dev The checks run again at execution: a listing that changed since the proposal blocks it.
    function test_rebalance_rechecksAtExecution() public {
        vm.prank(creator);
        etf.proposeRebalance(NVDA, 10_000, QQQ);
        vm.prank(approver);
        registry.setListed(QQQ, false);
        vm.prank(keeper);
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        etf.executeRebalance();
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
        uint256 shares = _swap(alice, USDG, 1_000e6);
        assertEq(etf.balanceOf(alice), shares);
        assertApproxEqRel(shares, 1_000e18, 0.03e18);
        _assertPoolUntouched();
    }

    function test_hook_sellThroughThePoolRedeemsForUsdg() public {
        uint256 shares = etf.balanceOf(creator) / 2;
        uint256 supply = etf.totalSupply();
        uint256 out = _swap(creator, address(etf), shares);
        // The sold shares sit in the pool manager behind the hook's claims, out of circulation.
        assertEq(etf.totalSupply(), supply - shares);
        assertEq(etf.balanceOf(address(manager)), shares);
        assertEq(IERC20(USDG).balanceOf(creator), out);
        assertApproxEqRel(out, 500e6, 0.03e18);
        _assertPoolUntouched();
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
        router.swap(etfKey, _params(USDG, 100e18, false), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        assertEq(etf.balanceOf(alice), 100e18);
        assertEq(etf.totalSupply(), supply + 100e18);
        assertApproxEqRel(1_000e6 - IERC20(USDG).balanceOf(alice), 100e6, 0.03e18);
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0);
        _assertPoolUntouched();
    }

    function test_hook_rejectsLiquidity() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        vm.expectRevert();
        lp.modifyLiquidity(etfKey, ModifyLiquidityParams(-60, 60, 1e18, 0), "");
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

    //////////////////////// helpers //////////////////////

    function _rebalance(address sellAsset, uint16 sellBps, address buyAsset) internal returns (uint256) {
        return _rebalanceOn(etf, sellAsset, sellBps, buyAsset);
    }

    /// @dev The creator proposes, a keeper executes.
    function _rebalanceOn(RealmEtf e, address sellAsset, uint16 sellBps, address buyAsset) internal returns (uint256) {
        vm.prank(creator);
        e.proposeRebalance(sellAsset, sellBps, buyAsset);
        vm.prank(keeper);
        return e.executeRebalance();
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

    function _assertPoolUntouched() internal view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(etfKey.toId());
        assertEq(sqrtPriceX96, uint160(1 << 96));
        assertEq(manager.getLiquidity(etfKey.toId()), 0);
    }
}
