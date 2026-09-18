// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {V4SwapHelpers} from "test/e2e/base/V4SwapHelpers.t.sol";
import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs, SniperProtection} from "src/tokens/SniperProtection.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {RealmLaunchPricing} from "src/libraries/RealmLaunchPricing.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

/// @notice The direct-launch venue end to end: pool created at a caller-supplied tick, the whole
///         circulating supply seeded as a single-sided band, the dev buy settled in the same
///         transaction, and the resulting token behaving like any other graduated Realm token.
contract DirectLaunchUniV4Tests is V4SwapHelpers {
    using stdStorage for StdStorage;
    using PoolIdLibrary for CorePoolKey;
    using StateLibrary for IPoolManager;

    RealmDirectGraduatorUniV4 internal directGraduator;
    RealmFactoryUniV4Direct internal directFactory;
    RealmAssetsWhitelist internal assetsWhitelist;

    /// @dev Launch price as QUOTE PER COIN: 1.0001^-184200 ≈ 1.0e-8 ETH/token, a ~10 ETH market cap
    ///      across the 1e27 supply. Spacing-aligned (200), well inside the usable band.
    int24 internal constant LAUNCH_TICK = -184_200;

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(admin);
        directGraduator = new RealmDirectGraduatorUniV4(
            poolManagerAddress, TEST_HOOK_ADDRESS, TEST_ANYPAIR_HOOK_ADDRESS, graduatorV4.LIQUIDITY_ADDER()
        );
        assetsWhitelist = new RealmAssetsWhitelist(admin, poolManagerAddress);
        address impl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxToken)}),
                address(directGraduator),
                address(feeHandler),
                address(creatorVaultFactory),
                address(WETH),
                address(assetsWhitelist)
            )
        );
        directFactory = RealmFactoryUniV4Direct(
            address(new ERC1967Proxy(impl, abi.encodeCall(RealmFactoryAbstract.initialize, ())))
        );
        vm.stopPrank();
    }

    /// @dev Whitelists `quote` at `unitsPerNativeX18` whole units per ETH by writing the rate a listing
    ///      would snapshot, so factory tests need no price pool per test quote. Listing itself is covered
    ///      in `realmAssetsWhitelist.t.sol`.
    function _whitelist(address quote, uint256 unitsPerNativeX18) internal {
        stdstore.target(address(assetsWhitelist)).sig(assetsWhitelist.unitsPerNativeX18.selector).with_key(quote)
            .checked_write(unitsPerNativeX18);
    }

    /////////////////////////// HELPERS ///////////////////////////

    function _setup(bool taxable) internal virtual returns (RealmFactoryUniV4Direct.DirectTokenSetup memory s) {
        s = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: "Direct",
            symbol: "DIR",
            salt: _nextValidSalt(address(directFactory), taxable ? address(realmTaxToken) : address(realmToken)),
            feeShares: _fs(creator),
            renounceOwnership: false,
            lpFeeBps: 100
        });
    }

    /// @dev A setup for the preview view, which ignores the identity fields.
    function _previewSetup() internal view returns (RealmFactoryUniV4Direct.DirectTokenSetup memory s) {
        s.feeShares = _fs(creator);
        s.lpFeeBps = 100;
    }

    function _pairs(address quote, int24 tick) internal pure returns (RealmFactoryUniV4Direct.DirectPair[] memory p) {
        p = new RealmFactoryUniV4Direct.DirectPair[](1);
        p[0] = RealmFactoryUniV4Direct.DirectPair({quote: quote, weightBps: 10_000, launchTick: tick});
    }

    function _noDevBuy() internal pure returns (RealmFactoryUniV4Direct.DevBuy memory d) {
        d = RealmFactoryUniV4Direct.DevBuy({
            pairIndex: 0,
            route: new CorePoolKey[](0),
            minQuoteOut: 0,
            quoteAmount: 0,
            recipients: new IRealmFactory.SupplyShare[](0)
        });
    }

    function _devBuyTo(address to) internal pure returns (RealmFactoryUniV4Direct.DevBuy memory d) {
        d = _noDevBuy();
        d.recipients = new IRealmFactory.SupplyShare[](1);
        d.recipients[0] = IRealmFactory.SupplyShare({account: to, shares: 10_000});
    }

    /// @dev The common no-tax, no-vault, no-sniper launch.
    function _launch(uint256 value, RealmFactoryUniV4Direct.DevBuy memory devBuy) internal returns (address token) {
        vm.prank(creator);
        token = directFactory.createToken{value: value}(
            _setup(false),
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    function _poolKey(address token) internal pure returns (CorePoolKey memory) {
        return UniswapV4PoolConstants.realmPoolKey(token, address(0), TEST_HOOK_ADDRESS);
    }

    /////////////////////////// TESTS ///////////////////////////

    function test_launch_createsPoolAtTheCallerSuppliedTick() public {
        address token = _launch(0, _noDevBuy());

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(poolManagerAddress).getSlot0(_poolKey(token).toId());
        // The pool's own orientation is the reciprocal of quote-per-coin, because the coin is currency1.
        assertEq(tick, -LAUNCH_TICK, "pool opened at the wrong tick");
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-LAUNCH_TICK), "pool opened at the wrong price");
    }

    function test_launch_graduatesImmediatelyAndPairsWithThePoolManager() public {
        address token = _launch(0, _noDevBuy());

        assertTrue(IRealmToken(token).graduated(), "direct launch must graduate in its creation tx");
        assertEq(IRealmToken(token).pair(), poolManagerAddress, "pair must be the pool manager");
        assertEq(address(RealmToken(token).launchpad()), address(0), "direct venue must carry no launchpad");
        assertEq(IRealmToken(token).graduator(), address(directGraduator));
    }

    /// @dev Everything not locked in a vault goes into the pool, bar the rounding remainder the band
    ///      could not absorb — which is burned, never held, so the graduator never becomes a holder.
    function test_launch_seedsTheWholeSupplyIntoThePool() public {
        address token = _launch(0, _noDevBuy());

        uint256 seeded = IERC20(token).balanceOf(poolManagerAddress);
        uint256 burned = IERC20(token).balanceOf(address(0xdEaD));
        assertEq(seeded + burned, TOTAL_SUPPLY, "supply must be seeded or burned, nothing else");
        assertLt(burned, 1e18, "seed remainder must be dust, not a share");
        assertEq(IERC20(token).balanceOf(address(directGraduator)), 0, "graduator must keep nothing");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory must keep nothing");
    }

    function test_launch_emitsPoolSeeded() public {
        vm.recordLogs();
        address token = _launch(0, _noDevBuy());

        bytes32 want = RealmDirectGraduatorUniV4.PoolSeeded.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == want) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "PoolSeeded token");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(0), "PoolSeeded quote");
                (bytes32 poolId, uint16 weightBps, int24 tick, uint128 liquidity) =
                    abi.decode(logs[i].data, (bytes32, uint16, int24, uint128));
                assertEq(poolId, PoolId.unwrap(_poolKey(token).toId()));
                assertEq(weightBps, 10_000);
                assertEq(tick, LAUNCH_TICK, "PoolSeeded reports the caller's tick, not the pool's");
                assertGt(liquidity, 0);
                (,,,, uint256 launchCap, uint256 targetCap) =
                    abi.decode(logs[i].data, (bytes32, uint16, int24, uint128, uint256, uint256));
                // Native has 18 decimals, so the raw (wei) market cap IS the whole-units X18 one, up to
                // `priceAtTick` flooring the per-coin price before scaling by the supply.
                (, uint256 capX18) = RealmLaunchPricing.priceAtTick(LAUNCH_TICK, 18);
                assertApproxEqAbs(launchCap, capX18, 1e9, "launch market cap in wei");
                assertEq(targetCap, launchCap * directGraduator.GRADUATION_TARGET_MULTIPLE(), "target = 5x launch");
                found = true;
            }
        }
        assertTrue(found, "PoolSeeded not emitted");
    }

    /// @dev Same order as `RealmGraduatorUniswapV4`, which indexers depend on.
    function test_launch_emitsPairInitializedBeforePoolIdRegistered() public {
        vm.recordLogs();
        _launch(0, _noDevBuy());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 pairAt = type(uint256).max;
        uint256 poolAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(directGraduator)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IRealmGraduator.PairInitialized.selector && pairAt == type(uint256).max) pairAt = i;
            if (topic == RealmDirectGraduatorUniV4.PoolIdRegistered.selector && poolAt == type(uint256).max) {
                poolAt = i;
            }
        }
        assertLt(poolAt, logs.length, "PoolIdRegistered not emitted");
        assertLt(pairAt, poolAt, "PairInitialized must precede PoolIdRegistered");
    }

    function test_devBuy_deliversTokensToTheRecipients() public {
        address token = _launch(0.05 ether, _devBuyTo(alice));

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered nothing");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory must keep nothing");
        assertEq(address(directGraduator).balance, 0, "graduator must keep no ETH");
    }

    function test_devBuy_splitsAcrossRecipientsByBps() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _noDevBuy();
        devBuy.recipients = new IRealmFactory.SupplyShare[](2);
        devBuy.recipients[0] = IRealmFactory.SupplyShare({account: alice, shares: 3_000});
        devBuy.recipients[1] = IRealmFactory.SupplyShare({account: bob, shares: 7_000});

        address token = _launch(0.05 ether, devBuy);

        uint256 total = IERC20(token).balanceOf(alice) + IERC20(token).balanceOf(bob);
        assertApproxEqRel(IERC20(token).balanceOf(alice), total * 3 / 10, 1e12);
        assertApproxEqRel(IERC20(token).balanceOf(bob), total * 7 / 10, 1e12);
    }

    /// @dev The seed remainder is burned on a launch WITH a dev buy too, not folded into what the buy
    ///      hands the recipients.
    function test_devBuy_seedRemainderIsBurnedNotPaidOut() public {
        address token = _launch(0.05 ether, _devBuyTo(alice));

        uint256 burned = IERC20(token).balanceOf(address(0xdEaD));
        assertGt(burned, 0, "the seed remainder was burned");
        assertEq(
            IERC20(token).balanceOf(poolManagerAddress) + burned + IERC20(token).balanceOf(alice),
            TOTAL_SUPPLY,
            "every token is in the pool, burned, or bought"
        );
    }

    /// @dev The graduator's launch markers live in transient storage, which a batched transaction
    ///      (multicall, account-abstraction bundle) shares across launches. A finished launch must not
    ///      block the next one.
    function test_twoLaunchesInOneTransaction() public {
        address first = _launch(0, _noDevBuy());
        address second = _launch(0.05 ether, _devBuyTo(alice));

        assertTrue(IRealmToken(first).graduated(), "first launched");
        assertTrue(IRealmToken(second).graduated(), "second launched");
        assertGt(IERC20(second).balanceOf(alice), 0, "second launch's dev buy delivered");
    }

    /// @dev ...and a later call in that transaction must not be able to drive a launch that already
    ///      finished: the graduator's hand-back is exempt from the sniper caps.
    function test_finishedLaunchCannotBeDrivenByALaterCall() public {
        address token = _launch(0, _noDevBuy());

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.devBuy{value: 1 ether}(token, address(0));
    }

    function test_afterLaunch_poolIsTradeableThroughTheHook() public {
        address token = _launch(0, _noDevBuy());

        _swapBuyV4(alice, token, 0.02 ether, 0, true);
        uint256 bought = IERC20(token).balanceOf(alice);
        assertGt(bought, 0, "post-launch buy delivered nothing");

        uint256 ethBefore = alice.balance;
        _swapSellV4(alice, token, bought / 2, 0, true);
        assertGt(alice.balance, ethBefore, "post-launch sell returned no ETH");
    }

    function test_creatorVaults_lockSupplyAndReduceTheSeed() public {
        IRealmFactory.CreatorVault[] memory vaults = new IRealmFactory.CreatorVault[](1);
        vaults[0] =
            IRealmFactory.CreatorVault({owner: creator, supplyBps: 1_000, cliffSeconds: 0, vestingSeconds: 30 days});

        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            vaults,
            _noDevBuy(),
            address(0)
        );

        uint256 locked = TOTAL_SUPPLY / 10;
        uint256 seeded = IERC20(token).balanceOf(poolManagerAddress);
        assertEq(
            seeded + IERC20(token).balanceOf(address(0xdEaD)), TOTAL_SUPPLY - locked, "seed must exclude the vault"
        );
        assertLt(TOTAL_SUPPLY - locked - seeded, 1e18, "seed remainder must be dust");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory must keep nothing");
    }

    function test_taxableToken_launchesAndTaxesPostLaunchSwaps() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);
        vm.prank(creator);
        address token = directFactory.createToken(
            setup,
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_taxCfg(300, 300, uint32(14 days))),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        IRealmToken.RealmTradeFees memory fees = IRealmToken(token).getSwapFees(true);
        assertEq(fees.taxBps, 300, "tax must be live from launch");
        assertEq(fees.lpFeeBps, 100);

        _swapBuyV4(alice, token, 0.02 ether, 0, true);
        assertGt(IERC20(token).balanceOf(alice), 0);
    }

    /// @dev D5: the window runs to its configured end, so a pool buy inside it is capped exactly as a
    ///      curve buy was. On this venue that is the ONLY thing the caps could mean — the token
    ///      graduates in its own creation transaction.
    function test_sniperCaps_applyToPostLaunchPoolBuys() public {
        address[] memory whitelist = new address[](0);
        AntiSniperConfigs memory cfg = AntiSniperConfigs({
            maxBuyPerTxBps: 10, // 0.1% of supply
            maxWalletBps: 10,
            protectionWindowSeconds: 1 hours,
            whitelist: whitelist
        });

        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            cfg,
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        // 0.05 ETH buys ~0.5% of supply out of a ~10 ETH-cap pool — five times the cap — so the
        // pool -> buyer leg is rejected.
        _swapBuyV4(alice, token, 0.05 ether, 0, false);
        assertEq(IERC20(token).balanceOf(alice), 0);

        // ...and the same buy goes through once the window closes.
        vm.warp(block.timestamp + 1 hours + 1);
        _swapBuyV4(alice, token, 0.05 ether, 0, true);
        assertGt(IERC20(token).balanceOf(alice), 0);
    }

    /////////////////////////// VALIDATION ///////////////////////////

    function test_revertsOnUnalignedLaunchTick() public {
        vm.prank(creator);
        vm.expectRevert(RealmDirectGraduatorUniV4.InvalidLaunchTick.selector);
        directFactory.createToken(
            _setup(false),
            _pairs(address(0), LAUNCH_TICK + 1),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev At no quote decimals (0-36) does the edge of the usable band imply a market cap inside the
    ///      launch-price bounds, so the factory's bound refuses it before the graduator's tick check.
    function test_revertsOnLaunchTickAtTheEdgeOfTheUsableBand() public {
        int24 maxUsable =
            (TickMath.MAX_TICK / UniswapV4PoolConstants.TICK_SPACING) * UniswapV4PoolConstants.TICK_SPACING;
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.LaunchPriceOutOfBounds.selector);
        directFactory.createToken(
            _setup(false),
            _pairs(address(0), maxUsable),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev The wrapped native token is the one quote the venue refuses outright: a pool holding it and
    ///      a pool holding native are the same market, so a token with both would split its own
    ///      liquidity across two pools for nothing.
    function test_revertsOnWrappedNativeQuote() public {
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.QuoteNotSupported.selector);
        directFactory.createToken(
            _setup(false),
            _pairs(address(WETH), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_revertsOnQuoteWithoutDecimals() public {
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.QuoteNotSupported.selector);
        directFactory.createToken(
            _setup(false),
            _pairs(address(directGraduator), LAUNCH_TICK), // a contract, but not an ERC20
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_revertsOnPartialPairWeight() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _pairs(address(0), LAUNCH_TICK);
        pairs[0].weightBps = 5_000;
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidPairs.selector);
        directFactory.createToken(
            _setup(false),
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    function test_revertsWhenDevBuyCarriesARouteOnANativePair() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.route = new CorePoolKey[](1);
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidDevBuy.selector);
        directFactory.createToken{value: 0.01 ether}(
            _setup(false),
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    function test_revertsOnUnsupportedLpFee() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        setup.lpFeeBps = 30;
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidLpFeeBps.selector);
        directFactory.createToken(
            setup,
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev This venue trades from the first second, so a decay start the hook's 20% cap cannot fit next
    ///      to the LP fee would make every buy revert `FeeTooHigh` until it decayed. Refused at creation;
    ///      exactly at the cap it launches and trades.
    function test_revertsWhenLpFeePlusDecayStartExceedsTheHookCap() public {
        TaxConfigs memory overCap = _decayCfg(1901, 0, 20 minutes, true); // + 100 bps LP fee = 2001
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        directFactory.createToken(
            setup,
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(overCap),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        vm.prank(creator);
        address token = directFactory.createToken(
            setup,
            _pairs(address(0), LAUNCH_TICK),
            _noDirectAlloc(_decayCfg(1900, 0, 20 minutes, true)),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        _swapBuyV4(alice, token, 0.02 ether, 0, true);
        assertGt(IERC20(token).balanceOf(alice), 0, "a buy at the cap goes through");
    }

    /// @dev The graduator authorises a launch by WHO calls `initialize` — the token, on itself. A
    ///      front-runner who staged a `prepare` cannot pre-create someone else's pool with it.
    function test_graduatorInitialize_rejectsAnyCallerButTheToken() public {
        address token = _launch(0, _noDevBuy());

        directGraduator.prepare(address(0), LAUNCH_TICK, 10_000);
        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.initialize(token);
    }

    /// @dev And `graduateToken` only ever works on the token the same transaction initialized, which
    ///      transient storage makes unreachable from any later one.
    function test_graduatorGraduate_rejectsAStaleToken() public {
        address token = _launch(0, _noDevBuy());

        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.graduateToken(token, 1);
    }
}
