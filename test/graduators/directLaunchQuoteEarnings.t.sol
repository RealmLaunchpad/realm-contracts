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
import {Currency} from "lib/v4-core/src/types/Currency.sol";

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

/// @notice The burn and liquidity earnings legs on an ERC20-quoted direct-launch pool, with the quote
///         placed on BOTH sides of the token's address: which side of the pair the quote sorts on flips
///         every orientation-dependent branch (wall side, top-up candidate check, refund leg).
contract DirectLaunchQuoteEarningsTests is DirectLaunchQuotesTests {
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
}
