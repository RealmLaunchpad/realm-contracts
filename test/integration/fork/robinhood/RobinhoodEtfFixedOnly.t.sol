// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfAssets} from "src/etf/RealmEtfAssets.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";
import {DeploymentAddressesRobinhoodMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";
import {DeploymentsRobinhoodMainnet as Manifest} from "src/config/manifest.robinhood.mainnet.sol";
import {WhitelistEtfAssets} from "script/WhitelistEtfAssets.s.sol";

/// @notice The fixed-only rollout on the LIVE proxies: both upgraded in place at a recent block, the real
///         `WhitelistEtfAssets` run against the real file, and a `FIXED` ETF holding SPY + OPENAI + ANTHROPIC
///         trading through the real `RealmHookAnyPair` pools.
contract RobinhoodEtfFixedOnlyTests is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 103_700_000;

    address internal constant OWNER = 0x8de64782f04F8528E3C88094F9a6AFc8B741B078;
    address internal constant USDG = Mainnet.USDG;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant OPENAI = 0xC73b24a207C4eaE3686edf6A3Fcf21843bDbE7C0;
    address internal constant ANTHROPIC = 0xF33507De3aa3C1386cee1eCFa2882b0b2930b305;
    address internal constant ANY_PAIR_HOOK = 0x24d9308561c322a603370A0c3BeAD39E05DA00CC;
    bytes32 internal constant OPENAI_POOL_ID = 0x13e5ad3f92c2a798663fe40d48b80a2dc5c72086c27a75b599db83eaa8378671;

    /// @dev Live ETFs: "AI" (`FIXED`) and "BALANCED" (`REBALANCE`, SPY + GLD + VTI + USO), with BALANCED's creator.
    RealmEtf internal constant LIVE_FIXED = RealmEtf(0x6A50881aCD6C3c73199Acce30AAe831483A391F2);
    RealmEtf internal constant LIVE_REBALANCE = RealmEtf(0x03FAF0F5D0D8612b369b57655D6A487f96eC6a92);
    address internal constant LIVE_CREATOR = 0xb9318b65648fDAfc5614917fe2C13402B06F542c;

    RealmEtfAssets internal constant REGISTRY = RealmEtfAssets(Manifest.ETF_ASSETS);
    RealmEtfFactory internal constant FACTORY = RealmEtfFactory(Manifest.ETF_FACTORY);

    uint256 internal constant SEED = 300e6;

    WhitelistEtfAssets internal script;
    PoolSwapTest internal router;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), FORK_BLOCK);
        script = new WhitelistEtfAssets();
        router = new PoolSwapTest(REGISTRY.POOL_MANAGER());
    }

    //////////////////////// modifiers //////////////////////

    modifier assetsUpgraded() {
        _upgradeAssets();
        _;
    }

    modifier factoryUpgraded() {
        _upgradeFactory();
        _;
    }

    /// @dev The whitelist script's signer is an approver, as `realm.deployer` is live.
    modifier scriptIsApprover() {
        vm.prank(OWNER);
        REGISTRY.setApprover(DEFAULT_SENDER, true);
        _;
    }

    /// @dev Runs the real script on the real file: the two thin assets end fixed-listed.
    modifier whitelisted() {
        script.run();
        _;
    }

    //////////////////////// upgrade //////////////////////

    /// @dev when both live proxies are upgraded, then every listing, route, approver, ETF and piece of wiring survives
    function test_upgrade_assertStorageSurvives() public {
        address[] memory assets = vm.parseJsonAddressArray(_file(), ".assets");
        uint256 listedAssets = 34;
        bytes32[] memory routes = new bytes32[](listedAssets);
        for (uint256 i; i < listedAssets; ++i) {
            assertTrue(REGISTRY.isListed(assets[i]), "precondition: listed");
            routes[i] = keccak256(abi.encode(REGISTRY.routeOf(assets[i])));
        }
        address hook = FACTORY.hook();
        uint256 minSeed = FACTORY.minSeedAssets();
        address whitelist = address(FACTORY.ASSETS_WHITELIST());
        uint256 nav = LIVE_FIXED.totalAssets();
        uint256 oldAssetsImpl = _impl(address(REGISTRY));
        uint256 oldFactoryImpl = _impl(address(FACTORY));

        _upgradeAssets();
        _upgradeFactory();

        assertTrue(_impl(address(REGISTRY)) != oldAssetsImpl && _impl(address(FACTORY)) != oldFactoryImpl, "impl");
        assertEq(REGISTRY.VERSION(), 2, "registry version");
        assertEq(FACTORY.VERSION(), 4, "factory version");
        assertEq(REGISTRY.owner(), OWNER, "registry owner");
        assertEq(FACTORY.owner(), OWNER, "factory owner");
        assertTrue(REGISTRY.isApprover(OWNER), "approver");
        for (uint256 i; i < listedAssets; ++i) {
            assertTrue(REGISTRY.isListed(assets[i]), "listing lost");
            assertFalse(REGISTRY.isFixedListed(assets[i]), "new slot not empty");
            assertEq(keccak256(abi.encode(REGISTRY.routeOf(assets[i]))), routes[i], "route moved");
        }
        assertEq(FACTORY.hook(), hook, "hook");
        assertEq(FACTORY.minSeedAssets(), minSeed, "min seed");
        assertEq(address(FACTORY.ASSETS_WHITELIST()), whitelist, "whitelist");
        assertEq(address(FACTORY.REGISTRY()), address(REGISTRY), "registry");
        assertTrue(FACTORY.isEtf(address(LIVE_FIXED)) && FACTORY.isEtf(address(LIVE_REBALANCE)), "isEtf");
        assertEq(LIVE_FIXED.totalAssets(), nav, "NAV moved");
    }

    /// @dev when a live `FIXED` ETF is used after the upgrade, then it still deposits and redeems
    function test_upgrade_assertLiveEtfStillTrades() public assetsUpgraded factoryUpgraded {
        deal(USDG, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(LIVE_FIXED), 100e6);
        uint256 shares = LIVE_FIXED.deposit(100e6, alice);
        assertGt(LIVE_FIXED.redeem(shares, alice, alice), 95e6, "exit paid");
        vm.stopPrank();
    }

    /// @dev when only the factory is upgraded (the wrong order), then listed assets still create: the constructor
    ///      reads the new getter only for an asset `isListed` refuses
    function test_upgrade_assertWrongOrderDoesNotBreakListedAssets() public factoryUpgraded {
        address[] memory assets = new address[](1);
        assets[0] = SPY;
        RealmEtf e = _create(RealmEtf.Mode.FIXED, assets);
        assertEq(e.getAssets().length, 1, "created");

        assets[0] = OPENAI;
        vm.expectRevert();
        FACTORY.createEtf("X", "X", RealmEtf.Mode.FIXED, assets, _evenWeights(1), SEED, new uint256[](1));
    }

    //////////////////////// whitelist script //////////////////////

    /// @dev when the script runs before the registry upgrade, then it refuses
    function test_script_assertNeedsTheUpgradedRegistry() public scriptIsApprover {
        vm.expectRevert("fixedOnly entries: upgrade ETF_ASSETS first");
        script.run();
    }

    /// @dev when the script runs on the real file, then only the two thin assets change, fixed-listed and not
    ///      listed, `verify()` passes, and a second run touches nothing
    function test_script_assertListsTheFixedOnlyEntriesOnceAndOnlyThem() public assetsUpgraded scriptIsApprover {
        vm.recordLogs();
        script.run();
        // The dry run's logs stay recorded through its state revert, so each event counts twice.
        assertEq(_registryLogs(), 8, "RouteSet + FixedListedSet, for each of the two entries");

        _assertFixedOnly(OPENAI);
        _assertFixedOnly(ANTHROPIC);
        assertEq(PoolId.unwrap(_routeKey(OPENAI).toId()), OPENAI_POOL_ID, "file's key is the real pool");
        assertEq(keccak256(abi.encode(REGISTRY.routeOf(OPENAI).key)), keccak256(abi.encode(_routeKey(OPENAI))), "key");
        assertEq(
            keccak256(abi.encode(REGISTRY.routeOf(ANTHROPIC).key)), keccak256(abi.encode(_routeKey(ANTHROPIC))), "key"
        );
        script.verify();

        vm.recordLogs();
        script.run();
        assertEq(_registryLogs(), 0, "idempotent");
    }

    /// @dev when a fixed-only entry's live route differs, then the script replaces it with `setRoute`: nothing but
    ///      `RouteSet`, the asset stays fixed-only
    function test_script_assertADifferingRouteGoesThroughSetRoute() public assetsUpgraded scriptIsApprover whitelisted {
        // Flips the fee in `_routes[OPENAI].key` (slot 3's mapping; fee, tick spacing and hooks share a word).
        bytes32 word = bytes32(uint256(keccak256(abi.encode(OPENAI, uint256(3)))) + 3);
        vm.store(address(REGISTRY), word, bytes32(uint256(vm.load(address(REGISTRY), word)) ^ 1));

        vm.recordLogs();
        script.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_registryLogs(logs), 2, "RouteSet alone (dry run, then for real)");
        assertEq(logs[logs.length - 1].topics[0], RealmEtfAssets.RouteSet.selector, "RouteSet");
        _assertFixedOnly(OPENAI);
        script.verify();
    }

    /// @dev when a fixed-only entry is also in `isListed`, then `verify()` refuses and the script delists it
    function test_script_assertAFixedOnlyEntryLeakedIntoIsListedIsCaughtAndClosed()
        public
        assetsUpgraded
        scriptIsApprover
        whitelisted
    {
        vm.prank(DEFAULT_SENDER);
        REGISTRY.setListed(OPENAI, true);
        vm.expectRevert("a fixedOnly entry is not as the file says");
        script.verify();

        script.run();
        _assertFixedOnly(OPENAI);
        script.verify();
    }

    //////////////////////// a live FIXED ETF of thin assets //////////////////////

    /// @dev when a `FIXED` ETF holds SPY + OPENAI + ANTHROPIC, then deposit, `mint`, `redeem`, `redeemInKind` and a
    ///      hook buy and sell all work through the real `RealmHookAnyPair` pools
    function test_fixedEtf_assertTradesThroughTheRealPools()
        public
        assetsUpgraded
        factoryUpgraded
        scriptIsApprover
        whitelisted
    {
        RealmEtf e = _create(RealmEtf.Mode.FIXED, _thinMix());
        address[] memory held = e.getAssets();
        assertEq(held.length, 3, "three holdings");
        for (uint256 i; i < 3; ++i) {
            assertGt(IERC20(held[i]).balanceOf(address(e)), 0, "seed bought");
        }
        assertApproxEqRel(e.totalAssets(), SEED, 0.1e18, "NAV near the seed");

        deal(USDG, alice, 100e6);
        vm.startPrank(alice);
        IERC20(USDG).approve(address(e), type(uint256).max);
        uint256 shares = e.deposit(50e6, alice);
        assertGt(shares, 0, "deposit");
        assertGt(e.redeem(shares / 2, alice, alice), 20e6, "redeem");
        assertGt(e.mint(1e18, alice), 0, "mint");
        e.redeemInKind(1e18, alice, alice);
        assertGt(IERC20(OPENAI).balanceOf(alice), 0, "in kind");
        assertGt(IERC20(ANTHROPIC).balanceOf(alice), 0, "in kind");
        vm.stopPrank();

        (PoolKey memory key, bool usdgIs0) = _etfKey(e);
        uint256 bought = _swap(e, key, usdgIs0, alice, USDG, 20e6);
        assertGt(bought, 0, "hook buy");
        assertGt(_swap(e, key, usdgIs0, alice, address(e), bought), 18e6, "hook sell");
    }

    /// @dev when any other mode tries a fixed-only asset, then creation reverts `AssetNotListed`
    function test_createOtherModes_assertRefuseTheThinAssets()
        public
        assetsUpgraded
        factoryUpgraded
        scriptIsApprover
        whitelisted
    {
        address[] memory assets = _thinMix();
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        FACTORY.createEtf("X", "X", RealmEtf.Mode.REBALANCE, assets, _evenWeights(3), SEED, new uint256[](3));
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        FACTORY.createEtf("X", "X", RealmEtf.Mode.FLEXIBLE, assets, _evenWeights(3), SEED, new uint256[](3));
    }

    /// @dev when a live `REBALANCE` ETF proposes buying a thin asset, then it reverts: `isListed` is what it reads,
    ///      with no upgrade of that ETF
    function test_liveEtf_assertCannotRebalanceIntoTheThinAssets()
        public
        assetsUpgraded
        factoryUpgraded
        scriptIsApprover
        whitelisted
    {
        vm.expectRevert(RealmEtf.AssetNotListed.selector);
        vm.prank(LIVE_CREATOR);
        LIVE_REBALANCE.proposeRebalance(SPY, 10_000, OPENAI);
    }

    //////////////////////// helpers //////////////////////

    function _file() internal view returns (string memory) {
        return vm.readFile("script/operations/etf-assets/etf-assets.robinhood.mainnet.json");
    }

    function _impl(address proxy) internal view returns (uint256) {
        return uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT));
    }

    function _upgradeAssets() internal {
        address impl = address(
            new RealmEtfAssets(
                address(REGISTRY.POOL_MANAGER()), REGISTRY.UNIV3_FACTORY(), REGISTRY.UNIV2_FACTORY(), REGISTRY.USDG()
            )
        );
        vm.prank(OWNER);
        UUPSUpgradeable(address(REGISTRY)).upgradeToAndCall(impl, "");
    }

    function _upgradeFactory() internal {
        address impl = address(new RealmEtfFactory(FACTORY.REGISTRY(), FACTORY.ASSETS_WHITELIST()));
        vm.prank(OWNER);
        UUPSUpgradeable(address(FACTORY)).upgradeToAndCall(impl, "");
    }

    function _assertFixedOnly(address asset) internal view {
        assertTrue(REGISTRY.isFixedListed(asset), "not fixed-listed");
        assertFalse(REGISTRY.isListed(asset), "open to every mode");
    }

    function _registryLogs() internal returns (uint256) {
        return _registryLogs(vm.getRecordedLogs());
    }

    function _registryLogs(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(REGISTRY)) ++count;
        }
    }

    function _routeKey(address asset) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(asset), 2000, 60, IHooks(ANY_PAIR_HOOK));
    }

    function _thinMix() internal pure returns (address[] memory assets) {
        assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (SPY, OPENAI, ANTHROPIC);
    }

    function _evenWeights(uint256 n) internal pure returns (uint16[] memory weights) {
        weights = new uint16[](n);
        uint16 share = uint16(10_000 / n);
        for (uint256 i; i < n; ++i) {
            weights[i] = i == 0 ? uint16(10_000 - share * (n - 1)) : share;
        }
    }

    function _create(RealmEtf.Mode mode, address[] memory assets) internal returns (RealmEtf) {
        deal(USDG, creator, SEED);
        vm.startPrank(creator);
        IERC20(USDG).approve(address(FACTORY), SEED);
        address e = FACTORY.createEtf(
            "Thin", "THIN", mode, assets, _evenWeights(assets.length), SEED, new uint256[](assets.length)
        );
        vm.stopPrank();
        return RealmEtf(e);
    }

    function _etfKey(RealmEtf e) internal view returns (PoolKey memory key, bool usdgIs0) {
        usdgIs0 = USDG < address(e);
        (address c0, address c1) = usdgIs0 ? (USDG, address(e)) : (address(e), USDG);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(FACTORY.hook()));
    }

    /// @dev Exact-input swap of `amount` `tokenIn` on the ETF's pool.
    function _swap(RealmEtf e, PoolKey memory key, bool usdgIs0, address who, address tokenIn, uint256 amount)
        internal
        returns (uint256 out)
    {
        if (tokenIn == USDG) deal(USDG, who, amount);
        address tokenOut = tokenIn == USDG ? address(e) : USDG;
        bool zeroForOne = (tokenIn == USDG) == usdgIs0;
        uint256 before = IERC20(tokenOut).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(router), amount);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        out = IERC20(tokenOut).balanceOf(who) - before;
    }
}
