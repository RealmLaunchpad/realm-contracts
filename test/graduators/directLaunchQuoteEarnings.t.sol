// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DirectLaunchQuotesTests, QuoteCoin} from "test/graduators/directLaunchQuotes.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmUniV4LiquidityAdder, WallParams} from "src/liquidity/RealmUniV4LiquidityAdder.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigsWithDirectAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "lib/v4-core/src/types/Currency.sol";
import {Vm} from "forge-std/Vm.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "lib/v4-core/src/libraries/CustomRevert.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";

/// @notice An 18-decimal `QuoteCoin`, for prices where a 6-decimal quote would fall outside the venue's
///         launch-price bounds.
contract QuoteCoin18 is QuoteCoin {
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// @notice A 27-decimal `QuoteCoin`: the high-decimals end of what the launch-price bounds must handle.
contract QuoteCoin27 is QuoteCoin {
    function decimals() public pure override returns (uint8) {
        return 27;
    }
}

/// @notice A 36-decimal `QuoteCoin`: the most decimals the venue accepts.
contract QuoteCoin36 is QuoteCoin {
    function decimals() public pure override returns (uint8) {
        return 36;
    }
}

/// @notice A 37-decimal `QuoteCoin`: one past what the venue accepts.
contract QuoteCoin37 is QuoteCoin {
    function decimals() public pure override returns (uint8) {
        return 37;
    }
}

/// @notice The burn and liquidity earnings legs on an ERC20-quoted direct-launch pool, with the quote
///         placed on BOTH sides of the token's address: which side of the pair the quote sorts on flips
///         every orientation-dependent branch (wall side, top-up candidate check, refund leg).
contract DirectLaunchQuoteEarningsTests is DirectLaunchQuotesTests {
    using PoolIdLibrary for CorePoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Sorts below any mined token address, so the quote is `currency0`.
    address internal constant LOW_QUOTE = address(0x10000000);
    /// @dev Sorts above any mined token address, so the quote is `currency1`.
    address internal constant HIGH_QUOTE = address(type(uint160).max - 0xffff);

    /////////////////////////// HELPERS ///////////////////////////

    /// @dev A `QuoteCoin` at a chosen address. Etched rather than deployed so the sort order is fixed;
    ///      the name and symbol read empty, which nothing here uses.
    function _placeQuote(address where, bool eighteenDecimals) internal returns (address) {
        vm.etch(where, eighteenDecimals ? address(new QuoteCoin18()).code : address(new QuoteCoin()).code);
        return where;
    }

    /// @dev A plain launch against `quote` at `tick`, expecting `revertData` (empty for success).
    function _launchAt(address quote, int24 tick, bytes memory revertData) internal {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _pairs(quote, tick);
        vm.prank(creator);
        if (revertData.length > 0) vm.expectRevert(revertData);
        directFactory.createToken(
            setup,
            pairs,
            _toCfgs(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev No tax: half of every accrual to the burn buffer, half to the liquidity buffer.
    function _burnAndLiquidityAlloc() internal pure returns (TaxConfigsWithDirectAllocation memory c) {
        c.earningsAllocation.burnBps = 5_000;
        c.earningsAllocation.liquidityBps = 5_000;
    }

    function _launchEarning(address quote, int24 tick, AntiSniperConfigs memory caps)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        vm.prank(creator);
        token = RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    _setup(true),
                    _pairs(quote, tick),
                    _burnAndLiquidityAlloc(),
                    caps,
                    new IRealmFactory.CreatorVault[](0),
                    _noDevBuy(),
                    address(0)
                ))
        );
    }

    function _accrue(RealmTaxableTokenUniV4 token, address quote, uint256 amount) internal {
        QuoteCoin(quote).mintTo(address(this), amount);
        IERC20(quote).approve(address(token), amount);
        token.accrueFees(quote, amount);
    }

    function _adder() internal view returns (RealmUniV4LiquidityAdder) {
        return RealmUniV4LiquidityAdder(directGraduator.LIQUIDITY_ADDER());
    }

    /////////////////////////// processLiquidity(quote) ///////////////////////////

    /// @dev The first call mints a wall on the token's OWN ERC20 pool; the second, with the price
    ///      unmoved, tops that same wall up. Neither leaves quote behind in the adder.
    function _wallThenTopUp(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        IPositionManager posm = IPositionManager(positionManagerAddress);

        token.processLiquidity(quote);
        (uint256[2] memory ids,) = token.getLiquidityWalls(quote);
        assertGt(ids[0], 0, "a wall was minted");
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(ids[0]);
        assertEq(address(key.hooks), TEST_ANYPAIR_HOOK_ADDRESS, "on the token's own ERC20 pool");
        assertEq(IERC721(positionManagerAddress).ownerOf(ids[0]), address(token), "held by the token");
        assertEq(IERC20(quote).balanceOf(address(_adder())), 0, "the mint left no quote in the adder");
        uint128 minted = posm.getPositionLiquidity(ids[0]);

        vm.roll(block.number + 1);
        token.processLiquidity(quote);
        (uint256[2] memory idsAfter,) = token.getLiquidityWalls(quote);
        assertEq(idsAfter[0], ids[0], "the second deposit reused the wall");
        assertGt(posm.getPositionLiquidity(ids[0]), minted, "and deepened it");
        assertEq(IERC20(quote).balanceOf(address(_adder())), 0, "the top-up left no quote in the adder");
    }

    function test_processLiquidity_quoteAsCurrency0_mintsThenTopsUp() public {
        _wallThenTopUp(_placeQuote(LOW_QUOTE, false));
    }

    function test_processLiquidity_quoteAsCurrency1_mintsThenTopsUp() public {
        _wallThenTopUp(_placeQuote(HIGH_QUOTE, false));
    }

    /////////////////////////// processBurn(quote) ///////////////////////////

    function _buyBackAndBurn(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        uint256 supply = token.totalSupply();

        token.processBurn(quote, 1);

        assertLt(token.totalSupply(), supply, "bought back on the quote pool and burned");
        assertEq(token.balanceOf(address(token)), 0, "nothing bought is left unburned");
    }

    function test_processBurn_quoteAsCurrency0() public {
        _buyBackAndBurn(_placeQuote(LOW_QUOTE, false));
    }

    function test_processBurn_quoteAsCurrency1() public {
        _buyBackAndBurn(_placeQuote(HIGH_QUOTE, false));
    }

    /////////////////////////// liquidity adder, ERC20 edges ///////////////////////////

    /// @dev A deposit that sizes to zero liquidity comes back in the currency it was made in, including
    ///      an ERC20 sitting at `currency0` — the index native occupies on a native pool. At this price
    ///      (~7.4 raw quote per raw coin) one raw unit of quote is worth less than one unit of liquidity.
    function test_adder_zeroLiquidityErc20Currency0IsRefundedInKind() public {
        address quote = _placeQuote(LOW_QUOTE, true);
        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _pairs(quote, 20_000),
            _toCfgs(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        QuoteCoin(quote).mintTo(address(this), 1);
        IERC20(quote).approve(address(_adder()), 1);

        uint256[2] memory noIds;
        int24[2] memory noTicks;
        (uint128 liquidity, uint256 id,) = _adder()
            .addOrTopUpSingleSided(
                UniswapV4PoolConstants.realmPoolKey(token, quote, TEST_ANYPAIR_HOOK_ADDRESS),
                WallParams({
                    currency: Currency.wrap(quote),
                    amount: 1,
                    tickWidth: 14_000,
                    reuseMaxGap: 2_000,
                    receiver: address(this)
                }),
                noIds,
                noTicks
            );

        assertEq(liquidity, 0, "nothing was placed");
        assertEq(id, 0, "so no wall to remember");
        assertEq(IERC20(quote).balanceOf(address(this)), 1, "the deposit came back as the quote");
    }

    /////////////////////////// sniper window ///////////////////////////

    /// @dev The buy-back's pool -> token leg lands on the token's OWN balance. That is protocol plumbing,
    ///      not a sniper, so the caps must not apply to it inside the window.
    function test_sniperWindow_buyBackIntoTheTokenIsNotCapped() public {
        AntiSniperConfigs memory caps = AntiSniperConfigs({
            maxBuyPerTxBps: 10, maxWalletBps: 10, protectionWindowSeconds: 1 days, whitelist: new address[](0)
        });
        RealmTaxableTokenUniV4 token = _launchEarning(address(0), LAUNCH_TICK, caps);
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();
        uint256 supply = token.totalSupply();

        token.processBurn(0);

        assertLt(token.totalSupply(), supply, "the buy-back went through inside the window");
    }

    /////////////////////////// launch-price bounds ///////////////////////////
    // Market cap in WHOLE quote units must sit in [0.001, 1e20]. The ticks below straddle each bound by
    // one or two spacings; the comment on each is the market cap it implies.

    function _outOfBounds() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RealmFactoryUniV4Direct.LaunchPriceOutOfBounds.selector);
    }

    function test_launchPrice_nativeBounds() public {
        _launchAt(address(0), -270_000, ""); // 1.9e-3 ETH
        _launchAt(address(0), -280_000, _outOfBounds()); // 6.9e-4 ETH
        _launchAt(address(0), 250_000, ""); // 7.2e19 ETH
        _launchAt(address(0), 260_000, _outOfBounds()); // 2.0e20 ETH
    }

    /// @dev Six decimals: the same whole-unit bounds, twelve orders of magnitude away in ticks.
    function test_launchPrice_sixDecimalQuoteBounds() public {
        address quote = address(quoteCoin);
        _launchAt(quote, -552_600, ""); // 1.005e-3 QC
        _launchAt(quote, -552_800, _outOfBounds()); // 9.85e-4 QC
        _launchAt(quote, -23_200, ""); // 9.8e19 QC
        _launchAt(quote, -22_800, _outOfBounds()); // 1.02e20 QC
    }

    /// @dev The mistake the lower bound exists for: a 1e5 QC market cap (`QC_LAUNCH_TICK`) priced as if
    ///      QC had 18 decimals, i.e. 1e12 times too cheap.
    function test_launchPrice_decimalsSlipIsRejected() public {
        _launchAt(address(quoteCoin), QC_LAUNCH_TICK - 276_400, _outOfBounds()); // 1e-7 QC
    }

    /// @dev Twenty-seven decimals: the bounds hold, and near the top Uniswap's per-tick liquidity ceiling
    ///      binds before them, with its own named error.
    function test_launchPrice_27DecimalQuoteBounds() public {
        address quote = HIGH_QUOTE;
        vm.etch(quote, address(new QuoteCoin27()).code);
        _launchAt(quote, -69_000, ""); // 1.008e-3
        _launchAt(quote, -69_200, _outOfBounds()); // 9.9e-4
        _launchAt(quote, 460_400, abi.encodeWithSelector(RealmDirectGraduatorUniV4.SeedLiquidityOutOfRange.selector)); // 9.9e19: in bounds, but the seed exceeds max liquidity per tick
        _launchAt(quote, 460_800, _outOfBounds()); // 1.03e20
    }

    /////////////////////////// direct factory input validation ///////////////////////////

    /// @dev A no-tax creator launch with `value` attached, expecting `err`. The salt is mined first, so
    ///      the expectation binds to `createToken` itself.
    function _expectCreateRevert(
        RealmFactoryUniV4Direct.DirectPair[] memory pairs,
        RealmFactoryUniV4Direct.DevBuy memory devBuy,
        uint256 value,
        bytes4 err
    ) internal {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.prank(creator);
        vm.expectRevert(err);
        directFactory.createToken{value: value}(
            setup,
            pairs,
            _toCfgs(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    function test_directInputs_devBuyOnAPairThatDoesNotExistIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.pairIndex = 1;
        _expectCreateRevert(
            _pairs(address(0), LAUNCH_TICK), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector
        );
    }

    /// @dev No conversion happens, so a floor for one is a caller who believes something is configured
    ///      that is not.
    function test_directInputs_devBuyWithASlippageFloorIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.minQuoteOut = 1;
        _expectCreateRevert(
            _pairs(address(0), LAUNCH_TICK), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector
        );
    }

    /// @dev The ERC20 pair is where a native -> quote route would mean something, and it is still refused.
    function test_directInputs_devBuyRouteOnAnErc20PairIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.route = new CorePoolKey[](1);
        devBuy.quoteAmount = 100e6;
        _expectCreateRevert(_quotePairs(QC_LAUNCH_TICK), devBuy, 0, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev Crossing the two payment legs would strand one of them in the factory.
    function test_directInputs_quoteAmountOnANativePairIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;
        _expectCreateRevert(_pairs(address(0), LAUNCH_TICK), devBuy, 0, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    function test_directInputs_valueOnAnErc20PairIsRejected() public {
        _expectCreateRevert(
            _quotePairs(QC_LAUNCH_TICK), _devBuyTo(alice), 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector
        );
    }

    /// @dev Weights that DO sum to the whole, one of them zero: a pool with nothing to seed.
    function test_directInputs_zeroWeightPairIsRejected() public {
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _twoPairs();
        pairs[0].weightBps = 10_000;
        pairs[1].weightBps = 0;
        _expectCreateRevert(pairs, _noDevBuy(), 0, RealmFactoryUniV4Direct.InvalidPairs.selector);
    }

    function test_directInputs_quoteWithoutCodeIsRejected() public {
        _expectCreateRevert(
            _pairs(makeAddr("eoaQuote"), QC_LAUNCH_TICK),
            _noDevBuy(),
            0,
            RealmFactoryUniV4Direct.QuoteNotSupported.selector
        );
    }

    /// @dev 36 decimals is the last accepted; 37 is refused whatever the tick.
    function test_directInputs_quoteDecimalsCapAt36() public {
        _launchAt(address(new QuoteCoin36()), 207_200, ""); // ~1 whole unit market cap
        _expectCreateRevert(
            _pairs(address(new QuoteCoin37()), 207_200),
            _noDevBuy(),
            0,
            RealmFactoryUniV4Direct.QuoteNotSupported.selector
        );
    }

    function test_directAlloc_rejectsMoreQuoteRoutesThanPairs() public {
        TaxConfigsWithDirectAllocation memory cfg = _burnAndLiquidityAlloc();
        cfg.quoteRoutes = new bytes[](2);
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidQuoteRoutes.selector);
        directFactory.createToken(
            setup,
            _quotePairs(QC_LAUNCH_TICK),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev The tax-only preview: no allocation to consider, so the tax alone picks the implementation.
    function test_previewTokenImplementation_taxOnlyOverloadFollowsTheTax() public view {
        assertEq(
            directFactory.previewTokenImplementation(_toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()),
            address(realmToken),
            "no tax: base implementation"
        );
        assertEq(
            directFactory.previewTokenImplementation(
                _toCfgs(_taxCfg(300, 300, uint32(14 days))), _emptyAntiSniperCfg()
            ),
            address(realmTaxToken),
            "a tax: taxable implementation"
        );
    }

    /// @dev The creator picks the ERC20 pool of a native + ERC20 launch: the pulled quote is spent there in
    ///      full and neither the graduator nor the factory keeps anything.
    function test_devBuy_onTheSecondPairOfAMixedLaunch() public {
        quoteCoin.mintTo(creator, 1_000e6);
        vm.prank(creator);
        quoteCoin.approve(address(directFactory), type(uint256).max);
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.pairIndex = 1;
        devBuy.quoteAmount = 100e6;

        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.prank(creator);
        address token = directFactory.createToken(
            setup,
            _twoPairs(),
            _toCfgs(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered");
        assertEq(quoteCoin.balanceOf(creator), 900e6, "exactly quoteAmount was pulled");
        assertEq(quoteCoin.balanceOf(poolManagerAddress), 100e6, "and all of it went into the quote pool");
        assertEq(quoteCoin.balanceOf(address(directGraduator)), 0, "graduator keeps no quote");
        assertEq(quoteCoin.balanceOf(address(directFactory)), 0, "factory keeps no quote");
        assertEq(IERC20(token).balanceOf(address(directGraduator)), 0, "graduator keeps no tokens");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory keeps no tokens");
    }

    /// @dev The `MAX_PAIRS` launch: native plus two ERC20s, one `PoolSeeded` per pool in pair order with
    ///      its own weight, and the supply fully seeded or burned.
    function test_multiPair_threePoolsAreAllSeeded() public {
        address quote18 = address(new QuoteCoin18());
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](3);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000, launchTick: LAUNCH_TICK});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({
            quote: address(quoteCoin), weightBps: 3_000, launchTick: QC_LAUNCH_TICK
        });
        pairs[2] = RealmFactoryUniV4Direct.DirectPair({quote: quote18, weightBps: 2_000, launchTick: LAUNCH_TICK});

        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.recordLogs();
        vm.prank(creator);
        address token = directFactory.createToken(
            setup,
            pairs,
            _toCfgs(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != RealmDirectGraduatorUniV4.PoolSeeded.selector) {
                continue;
            }
            assertLt(found, 3, "no more than one PoolSeeded per pool");
            (, uint16 weightBps,, uint128 liquidity) = abi.decode(logs[i].data, (bytes32, uint16, int24, uint128));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), pairs[found].quote, "pools seeded in pair order");
            assertEq(weightBps, pairs[found].weightBps, "each with its own weight");
            assertGt(liquidity, 0, "and a non-empty band");
            ++found;
        }
        assertEq(found, 3, "one PoolSeeded per pool");
        assertEq(IRealmToken(token).quoteCount(), 3, "native plus both ERC20s");
        assertEq(
            IERC20(token).balanceOf(poolManagerAddress) + IERC20(token).balanceOf(address(0xdEaD)),
            TOTAL_SUPPLY,
            "supply seeded or burned"
        );
    }

    /////////////////////////// graduator entry points outside a launch ///////////////////////////

    /// @dev Even a caller that IS the named token is refused when nothing was staged.
    function test_graduatorInitialize_rejectsAnUnstagedLaunch() public {
        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.initialize(address(this));
    }

    /// @dev Every factory-driven entry point hangs off the transient launch markers, which the finished
    ///      launch cleared.
    function test_graduator_factoryEntryPointsRejectAFinishedLaunch() public {
        address token = _launch(0, _noDevBuy());

        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.initializePool(token, address(quoteCoin), QC_LAUNCH_TICK);
        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.seedPool(token, address(0), LAUNCH_TICK, 1e18, 10_000);
        vm.expectRevert(RealmDirectGraduatorUniV4.LaunchNotPrepared.selector);
        directGraduator.burnSeedDust(token);
    }

    function test_graduatorUnlockCallback_rejectsAnyCallerButThePoolManager() public {
        vm.expectRevert(RealmDirectGraduatorUniV4.OnlyPoolManager.selector);
        directGraduator.unlockCallback("");
    }

    /// @dev `prepare` is open, so it validates on its own: off the spacing grid, or AT the edge of the usable
    ///      band (where the seed range would be empty).
    function test_graduatorPrepare_rejectsAnUnusableTick() public {
        vm.expectRevert(RealmDirectGraduatorUniV4.InvalidLaunchTick.selector);
        directGraduator.prepare(address(0), LAUNCH_TICK + 1, 10_000);

        int24 maxUsable =
            (TickMath.MAX_TICK / UniswapV4PoolConstants.TICK_SPACING) * UniswapV4PoolConstants.TICK_SPACING;
        vm.expectRevert(RealmDirectGraduatorUniV4.InvalidLaunchTick.selector);
        directGraduator.prepare(address(0), maxUsable, 10_000);
        vm.expectRevert(RealmDirectGraduatorUniV4.InvalidLaunchTick.selector);
        directGraduator.prepare(address(0), -maxUsable, 10_000);
    }

    /// @dev A dev buy that buys out the whole band and still has quote left reverts rather than stranding
    ///      the remainder. At ~1e-18 raw QC per raw coin (a ~1,000 QC market cap) the full band costs
    ///      ~1.9e37 raw QC, so 1e38 cannot be filled.
    function test_devBuy_largerThanTheBandCanFillReverts() public {
        uint256 spend = 1e38;
        quoteCoin.mintTo(creator, spend);
        vm.prank(creator);
        quoteCoin.approve(address(directFactory), spend);
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = spend;

        _expectCreateRevert(_quotePairs(-414_400), devBuy, 0, RealmDirectGraduatorUniV4.DevBuyNotFilled.selector);
    }

    /////////////////////////// sniper caps on the direct venue ///////////////////////////

    function _caps(uint16 maxBuyPerTxBps, uint16 maxWalletBps) internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: maxBuyPerTxBps,
            maxWalletBps: maxWalletBps,
            protectionWindowSeconds: 1 hours,
            whitelist: new address[](0)
        });
    }

    /// @dev A launch into `pairs` under `caps`, with a dev buy of `spend` on `pairs[pairIndex]` (native value
    ///      or pulled QuoteCoin) split evenly between alice and bob.
    function _cappedLaunchWithDevBuy(
        RealmFactoryUniV4Direct.DirectPair[] memory pairs,
        uint8 pairIndex,
        uint256 spend,
        AntiSniperConfigs memory caps
    ) internal returns (address token) {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _noDevBuy();
        devBuy.pairIndex = pairIndex;
        devBuy.recipients = new IRealmFactory.SupplyShare[](2);
        devBuy.recipients[0] = IRealmFactory.SupplyShare({account: alice, shares: 5_000});
        devBuy.recipients[1] = IRealmFactory.SupplyShare({account: bob, shares: 5_000});
        bool native = pairs[pairIndex].quote == address(0);
        if (!native) {
            devBuy.quoteAmount = spend;
            quoteCoin.mintTo(creator, spend);
            vm.prank(creator);
            quoteCoin.approve(address(directFactory), spend);
        }
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.prank(creator);
        token = directFactory.createToken{value: native ? spend : 0}(
            setup, pairs, _toCfgs(_emptyTaxCfg()), caps, new IRealmFactory.CreatorVault[](0), devBuy, address(0)
        );
    }

    /// @dev The dev buy's hops (pool -> graduator -> factory -> recipients) are launch plumbing: the
    ///      tightest caps do not apply to them, and each recipient ends far above the wallet cap.
    function test_sniperCaps_devBuyFarAboveTheCapsIsDelivered() public {
        address token = _cappedLaunchWithDevBuy(_twoPairs(), 0, 1 ether, _caps(10, 10));
        uint256 maxWallet = TOTAL_SUPPLY * 10 / 10_000;

        assertGt(IERC20(token).balanceOf(alice), 10 * maxWallet, "alice holds many times the wallet cap");
        assertGt(IERC20(token).balanceOf(bob), 10 * maxWallet, "so does bob");
        assertEq(IERC20(token).balanceOf(address(directGraduator)), 0, "graduator keeps nothing");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory keeps nothing");
    }

    /// @dev The per-tx cap is a BUY cap: inside the window a sell of 5x it goes through whole. Each pool is
    ///      given quote to sell into by a dev buy on that same pool.
    function test_sniperCaps_sellAboveThePerTxCapIsNotCapped() public {
        uint256 sell = 5 * TOTAL_SUPPLY * 10 / 10_000;

        address nativeToken = _cappedLaunchWithDevBuy(_pairs(address(0), LAUNCH_TICK), 0, 1 ether, _caps(10, 10));
        uint256 bag = IERC20(nativeToken).balanceOf(alice);
        assertGt(_swapSellV4(alice, nativeToken, sell, 0, true), 0, "native-pool sell returned ETH");
        assertEq(bag - IERC20(nativeToken).balanceOf(alice), sell, "the whole native-pool sell went through");

        address quoteToken = _cappedLaunchWithDevBuy(_quotePairs(QC_LAUNCH_TICK), 0, 20_000e6, _caps(10, 10));
        bag = IERC20(quoteToken).balanceOf(alice);
        _swapQuotePool(alice, quoteToken, false, sell);
        assertGt(quoteCoin.balanceOf(alice), 0, "ERC20-pool sell returned the quote");
        assertEq(bag - IERC20(quoteToken).balanceOf(alice), sell, "the whole ERC20-pool sell went through");
    }

    /// @dev `_swapQuotePool`'s buy with the router call expected to revert with `revertData`. The approvals
    ///      go first, so the expectation binds to the swap.
    function _expectQuoteBuyRevert(address caller, address token, uint256 amountIn, bytes memory revertData) internal {
        CorePoolKey memory coreKey = _qcPoolKey(token);
        PoolKey memory key = abi.decode(abi.encode(coreKey), (PoolKey));
        bool quoteIsC0 = address(quoteCoin) < token;

        vm.startPrank(caller);
        quoteCoin.approve(permit2Address, type(uint256).max);
        IPermit2(permit2Address).approve(address(quoteCoin), universalRouter, type(uint160).max, type(uint48).max);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: quoteIsC0,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(quoteIsC0 ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(quoteIsC0 ? key.currency1 : key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );
        vm.expectRevert(revertData);
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        vm.stopPrank();
    }

    /// @dev On the ERC20 pool, with a wallet cap loose enough that only the per-tx cap can bind: ~5x the
    ///      per-tx cap reverts `MaxBuyPerTxExceeded` inside the window (wrapped by the pool manager's
    ///      `take`) and the same buy goes through once the window has closed.
    function test_sniperCaps_erc20PoolBuyAboveThePerTxCapRevertsUntilTheWindowCloses() public {
        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _quotePairs(QC_LAUNCH_TICK),
            _toCfgs(_emptyTaxCfg()),
            _caps(10, 300),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        // 500 QC at ~1e-4 QC per coin is ~5M coins: five times the 1M per-tx cap, a sixth of the wallet cap.
        uint256 spend = 500e6;
        quoteCoin.mintTo(alice, spend);

        _expectQuoteBuyRevert(
            alice,
            token,
            spend,
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                token,
                IERC20.transfer.selector,
                abi.encodeWithSelector(SniperProtection.MaxBuyPerTxExceeded.selector),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        assertEq(IERC20(token).balanceOf(alice), 0, "nothing bought inside the window");

        vm.warp(block.timestamp + 1 hours);
        _swapQuotePool(alice, token, true, spend);
        assertGt(IERC20(token).balanceOf(alice), TOTAL_SUPPLY * 10 / 10_000, "an above-cap buy once it closed");
    }

    /////////////////////////// token quote surface ///////////////////////////

    /// @dev The quote set is fixed at creation: nobody but the creating factory, inside the creation
    ///      transaction, may extend it — not the token's own owner.
    function test_registerQuotes_rejectsAnyCallerButTheCreatingFactory() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        address[] memory extra = new address[](1);
        extra[0] = address(new QuoteCoin18());

        vm.prank(creator);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(token).registerQuotes(extra);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(token).registerQuotes(extra);

        assertEq(IRealmToken(token).quoteCount(), 2, "the quote set is unchanged");
    }

    /// @dev A currency with no pool on this token has no buffer and no way out, so the gate runs before
    ///      anything is pulled — even for a zero amount.
    function test_accrueFees_unknownQuoteRevertsOnABaseToken() public {
        address token = _launchAgainstQuoteCoin(_noDevBuy());
        address stranger = address(new QuoteCoin18());

        vm.expectRevert(RealmToken.UnknownQuote.selector);
        IRealmToken(token).accrueFees(stranger, 1e18);
        vm.expectRevert(RealmToken.UnknownQuote.selector);
        IRealmToken(token).accrueFees(stranger, 0);
    }

    function test_accrueFees_unknownQuoteRevertsOnAnAllocationToken() public {
        RealmTaxableTokenUniV4 token =
            _launchEarning(_placeQuote(LOW_QUOTE, false), QC_LAUNCH_TICK, _emptyAntiSniperCfg());

        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.accrueFees(address(quoteCoin), 1e6);
        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.accrueFees(address(quoteCoin), 0);
    }

    /////////////////////////// earnings legs on ERC20 quotes, edges ///////////////////////////

    /// @dev Once the price has moved past `LIQUIDITY_WALL_REUSE_MAX_GAP` (2,000 ticks) away from the first
    ///      wall, the next deposit mints a SECOND wall, and the two-entry memory rotates: the new one
    ///      first, the old one second, untouched.
    function _newWallRotatesTheMemory(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        IPositionManager posm = IPositionManager(positionManagerAddress);

        token.processLiquidity(quote);
        (uint256[2] memory first, int24[2] memory firstLowers) = token.getLiquidityWalls(quote);
        uint128 firstLiquidity = posm.getPositionLiquidity(first[0]);

        // 20k QC into a ~1e5 QC market cap lifts the price ~44%, ~3,600 ticks.
        QuoteCoin(quote).mintTo(alice, 20_000e6);
        _swapQuotePool(alice, address(token), quote, true, 20_000e6);
        CorePoolKey memory key = UniswapV4PoolConstants.realmPoolKey(address(token), quote, TEST_ANYPAIR_HOOK_ADDRESS);
        (, int24 tick,,) = IPoolManager(poolManagerAddress).getSlot0(key.toId());
        // A quote-only wall sits above the tick when the quote is currency0, below it (14,000 wide) otherwise.
        int24 gap = quote < address(token) ? firstLowers[0] - tick : tick - (firstLowers[0] + 14_000);
        assertGt(gap, 2_000, "precondition: the first wall is past the reuse gap");

        vm.roll(block.number + 1);
        token.processLiquidity(quote);

        (uint256[2] memory ids, int24[2] memory lowers) = token.getLiquidityWalls(quote);
        assertGt(ids[0], first[0], "a fresh wall was minted");
        assertEq(IERC721(positionManagerAddress).ownerOf(ids[0]), address(token), "held by the token");
        assertTrue(lowers[0] != firstLowers[0], "at the moved price");
        assertEq(ids[1], first[0], "the first wall moved to the second entry");
        assertEq(lowers[1], firstLowers[0], "with its own lower tick");
        assertEq(posm.getPositionLiquidity(first[0]), firstLiquidity, "and was not topped up");
    }

    function test_processLiquidity_quoteAsCurrency0_newWallRotatesTheMemory() public {
        _newWallRotatesTheMemory(_placeQuote(LOW_QUOTE, false));
    }

    function test_processLiquidity_quoteAsCurrency1_newWallRotatesTheMemory() public {
        _newWallRotatesTheMemory(_placeQuote(HIGH_QUOTE, false));
    }

    /// @dev Once per block per quote, for each leg separately; the next block reopens both.
    function _secondProcessInABlockReverts(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);

        token.processBurn(quote, 1);
        vm.expectRevert(RealmTaxableTokenUniV4Base.ProcessCooldown.selector);
        token.processBurn(quote, 1);

        token.processLiquidity(quote);
        vm.expectRevert(RealmTaxableTokenUniV4Base.ProcessCooldown.selector);
        token.processLiquidity(quote);

        vm.roll(block.number + 1);
        token.processBurn(quote, 1);
        token.processLiquidity(quote);
        (,, uint48 lastBurn, uint48 lastLiquidity) = token.quoteBufferOf(quote);
        assertEq(lastBurn, block.number, "burn ran again in the next block");
        assertEq(lastLiquidity, block.number, "liquidity ran again in the next block");
    }

    function test_processQuote_quoteAsCurrency0_cooldownIsPerBlock() public {
        _secondProcessInABlockReverts(_placeQuote(LOW_QUOTE, false));
    }

    function test_processQuote_quoteAsCurrency1_cooldownIsPerBlock() public {
        _secondProcessInABlockReverts(_placeQuote(HIGH_QUOTE, false));
    }

    /// @dev An empty quote buffer has nothing to spend, even while the NATIVE buffers of the same token are
    ///      full: the buffers are per quote.
    function _emptyQuoteBuffersRevert(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();
        assertGt(token.burnPendingEth(), 0, "precondition: the native buffers are funded");

        vm.expectRevert(RealmTaxableTokenUniV4Base.NothingToBurn.selector);
        token.processBurn(quote, 0);
        vm.expectRevert(RealmTaxableTokenUniV4Base.NothingToAdd.selector);
        token.processLiquidity(quote);
    }

    function test_processQuote_quoteAsCurrency0_emptyBuffersRevert() public {
        _emptyQuoteBuffersRevert(_placeQuote(LOW_QUOTE, false));
    }

    function test_processQuote_quoteAsCurrency1_emptyBuffersRevert() public {
        _emptyQuoteBuffersRevert(_placeQuote(HIGH_QUOTE, false));
    }

    /// @dev The quote's burn and liquidity buffers are committed: the owner's `rescueTokens` sees only
    ///      what sits above them.
    function _rescueSweepsOnlyStrayQuote(address quote) internal {
        RealmTaxableTokenUniV4 token = _launchEarning(quote, QC_LAUNCH_TICK, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        (uint256 burnPending, uint256 liquidityPending,,) = token.quoteBufferOf(quote);
        assertEq(burnPending + liquidityPending, 4_000e6, "precondition: the whole accrual is buffered");

        vm.prank(creator);
        token.rescueTokens(quote);
        assertEq(IERC20(quote).balanceOf(creator), 0, "nothing above the buffers, nothing rescued");

        QuoteCoin(quote).mintTo(address(token), 123e6);
        vm.prank(creator);
        token.rescueTokens(quote);

        assertEq(IERC20(quote).balanceOf(creator), 123e6, "exactly the stray quote was rescued");
        assertEq(IERC20(quote).balanceOf(address(token)), 4_000e6, "the buffers' backing stayed");
        (uint256 burnAfter, uint256 liquidityAfter,,) = token.quoteBufferOf(quote);
        assertEq(burnAfter, burnPending, "burn buffer intact");
        assertEq(liquidityAfter, liquidityPending, "liquidity buffer intact");
    }

    function test_rescueTokens_quoteAsCurrency0_sweepsOnlyTheStrayQuote() public {
        _rescueSweepsOnlyStrayQuote(_placeQuote(LOW_QUOTE, false));
    }

    function test_rescueTokens_quoteAsCurrency1_sweepsOnlyTheStrayQuote() public {
        _rescueSweepsOnlyStrayQuote(_placeQuote(HIGH_QUOTE, false));
    }
}
