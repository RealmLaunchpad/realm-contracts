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
import {RealmLaunchPricing} from "src/libraries/RealmLaunchPricing.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {SniperProtection} from "src/tokens/SniperProtection.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "lib/v4-core/src/libraries/CustomRevert.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {HalfFillQuoteBuyBackRouterStub} from "test/graduators/directLaunchDividends.t.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "lib/v4-core/src/test/PoolModifyLiquidityTest.sol";

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

/// @notice An 18-decimal quote that burns 10% of every transfer. `accrueFees` must split what it
///         RECEIVED, not the nominal amount the caller named, or its buffers claim more than the token
///         actually holds.
contract QuoteCoin18FeeOnTransfer is QuoteCoin18 {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 10;
        super._update(from, address(0xdEaD), fee);
        super._update(from, to, value - fee);
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

    /// @dev A whitelisted `QuoteCoin` at a chosen address. Etched rather than deployed so the sort order
    ///      is fixed; the name and symbol read empty, which nothing here uses. The six-decimal one is priced
    ///      like `quoteCoin`, the eighteen-decimal one 1:1 with ETH.
    function _placeQuote(address where, bool eighteenDecimals) internal returns (address) {
        vm.etch(where, eighteenDecimals ? address(new QuoteCoin18()).code : address(new QuoteCoin()).code);
        _whitelist(where, eighteenDecimals ? 1e18 : QC_PER_ETH);
        return where;
    }

    /// @dev A fresh whitelisted eighteen-decimal `QuoteCoin`, priced 1:1 with ETH.
    function _newQuote18() internal returns (address quote) {
        quote = address(new QuoteCoin18());
        _whitelist(quote, 1e18);
    }

    /// @dev A plain launch against `quote`, expecting `revertData` (empty for success).
    function _launchAt(address quote, bytes memory revertData) internal {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = _pairs(quote);
        vm.prank(creator);
        if (revertData.length > 0) vm.expectRevert(revertData);
        directFactory.createToken(
            setup,
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
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

    function _launchEarning(address quote, AntiSniperConfigs memory caps)
        internal
        returns (RealmTaxableTokenUniV4 token)
    {
        vm.prank(creator);
        token = RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    _setup(true),
                    _pairs(quote),
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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        IPositionManager posm = IPositionManager(positionManagerAddress);

        // The wall's currency is on the event, so its amount is never read as native.
        vm.expectEmit(true, false, false, false, address(token));
        emit RealmTaxableToken.LiquidityAdded(quote, 0, 0, 0);
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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        uint256 supply = token.totalSupply();

        // Both the precursor and the burn name the quote the buy-back spent.
        vm.expectEmit(true, false, false, false, address(token));
        emit RealmTaxableTokenUniV4Base.BuyBackInitiated(quote, 0);
        vm.expectEmit(true, false, false, false, address(token));
        emit RealmTaxableToken.CreatorTaxBurn(quote, 0, 0);
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
    ///      (~22.5 raw quote per raw coin) one raw unit of quote is worth less than one unit of liquidity.
    function test_adder_zeroLiquidityErc20Currency0IsRefundedInKind() public {
        address quote = _placeQuote(LOW_QUOTE, true);
        // Worth 1e-10 ETH a unit, so the 2.25 ETH opening cap is ~2.25e10 units.
        _whitelist(quote, 1e28);
        vm.prank(creator);
        address token = directFactory.createToken(
            _setup(false),
            _pairs(quote),
            _noDirectAlloc(_emptyTaxCfg()),
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

    /////////////////////////// LP-FEE SHARE THROUGH THE ALLOCATION ///////////////////////////

    /// @dev The whole point of routing the LP-fee creator share through the TOKEN rather than straight to
    ///      the fee handler: an allocation-configured token must carve its burn / liquidity slices out of
    ///      that share too, not just out of the swap tax. Driven by a real swap through the hook and a
    ///      real `settleFees`, so the router's ERC20 leg is the thing under test, not a direct `accrueFees`.
    function test_erc20Quote_lpFeeCreatorShareIsCarvedByEarningsAllocation() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        QuoteCoin(quote).mintTo(alice, 1_000e6);

        _swapQuotePool(alice, address(token), quote, true, 100e6);
        uint256 lpFee = anyPairHook.pendingLpFees(address(token), quote);
        assertEq(lpFee, 100e6 / 100, "a 1% LP fee on the input");
        assertEq(anyPairHook.pendingTaxes(address(token), quote), 0, "and no tax: the LP fee is all there is");

        anyPairHook.settleFees(address(token), quote);

        uint256 creatorShare = lpFee - lpFee * LP_TREASURY_BPS / 10_000;
        (uint256 burnPending, uint256 liquidityPending,,) = token.quoteBufferOf(quote);
        assertEq(burnPending, creatorShare / 2, "half the LP-fee creator share was carved for the burn");
        assertEq(liquidityPending, creatorShare / 2, "and half for liquidity");

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        assertEq(
            feeHandler.getClaimable(tokens, quote, creator)[0],
            creatorShare - 2 * (creatorShare / 2),
            "nothing but the rounding dust reached the fund wallets"
        );
        assertEq(IERC20(quote).balanceOf(address(token)), creatorShare, "and the token holds what it booked");
    }

    /////////////////////////// per-call spend cap ///////////////////////////

    /// @dev `MAX_QUOTE_SPEND_BPS`: one call spends a QUARTER of the buffer, not the lot. The native leg
    ///      has an absolute ceiling instead, which means nothing in a currency nobody calibrated.
    function test_processBurn_quote_capsSpendAt25PercentOfBuffer() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);

        (uint256 buffered,,,) = token.quoteBufferOf(quote);
        assertEq(buffered, 2_000e6, "half the accrual is earmarked for burning");

        token.processBurn(quote, 1);

        (uint256 left,,,) = token.quoteBufferOf(quote);
        assertEq(left, buffered - buffered / 4, "three quarters stay buffered for later calls");
    }

    /// @dev The same cap on the liquidity leg, which reads `_maxSpend` through its own entry point.
    function test_processLiquidity_quote_capsSpendAt25PercentOfBuffer() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);

        (, uint256 buffered,,) = token.quoteBufferOf(quote);
        token.processLiquidity(quote);

        (, uint256 left,,) = token.quoteBufferOf(quote);
        assertEq(left, buffered - buffered / 4, "three quarters stay buffered");
    }

    /// @dev A pool that only half-fills the buy-back: the unspent quote must go back on the BURN buffer,
    ///      not fall into the stray pool where `sweepStrayEth` would re-split it into other buckets. The
    ///      native leg has this; the quote leg is a different path (orientation-dependent, Permit2-settled).
    function test_processBurn_quote_partialFillRefundsUnspentToBuffer() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
        _accrue(token, quote, 4_000e6);
        (uint256 buffered,,,) = token.quoteBufferOf(quote);
        uint256 spend = buffered / 4;

        address router = token.UNIV4_UNIVERSAL_ROUTER();
        deal(address(token), router, 1e18);
        vm.etch(router, address(new HalfFillQuoteBuyBackRouterStub(address(token), quote, token.PERMIT2())).code);

        uint256 supply = token.totalSupply();
        token.processBurn(quote, 1);

        (uint256 left,,,) = token.quoteBufferOf(quote);
        assertEq(left, buffered - spend / 2, "only the half the pool took left the buffer");
        assertEq(supply - token.totalSupply(), 1e18, "what the pool did deliver was burned");
        // The liquidity buffer is untouched, so the token's holdings back BOTH buffers exactly.
        (, uint256 liquidityPending,,) = token.quoteBufferOf(quote);
        assertEq(
            IERC20(quote).balanceOf(address(token)), left + liquidityPending, "the unspent half is backed and earmarked"
        );
    }

    /////////////////////////// fee-on-transfer quote ///////////////////////////

    /// @dev `accrueFees(asset, amount)` must book the balance delta, not the caller's nominal `amount` —
    ///      every other ERC20-spending path here (buy-back settlement, dividend acquisition) already
    ///      measures the delta; this is the one entry point that used to trust the caller instead.
    function test_accrueFees_feeOnTransferQuoteDoesNotOvercredit() public {
        address quote = address(new QuoteCoin18FeeOnTransfer());
        _whitelist(quote, 1e18);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());

        QuoteCoin(quote).mintTo(address(this), 4_000e18);
        IERC20(quote).approve(address(token), 4_000e18);
        token.accrueFees(quote, 4_000e18);

        uint256 received = 4_000e18 - 4_000e18 / 10; // 10% burned on the pull
        (uint256 burnPending, uint256 liquidityPending,,) = token.quoteBufferOf(quote);
        assertEq(burnPending, received / 2, "half of what ARRIVED, not of the nominal amount");
        assertEq(liquidityPending, received / 2, "and half for liquidity");
        assertEq(
            IERC20(quote).balanceOf(address(token)),
            burnPending + liquidityPending,
            "the buffers never claim more than the token actually holds"
        );
    }

    /////////////////////////// unregistered quote / cooldown independence ///////////////////////////

    /// @dev `accrueFees` and `processDividends` both refuse a currency this token has no pool for; so must
    ///      the two earnings processors, which would otherwise index a buffer that belongs to nobody.
    function test_processBurnAndLiquidity_unregisteredQuoteReverts() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());

        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.processBurn(address(quoteCoin), 1);
        vm.expectRevert(RealmToken.UnknownQuote.selector);
        token.processLiquidity(address(quoteCoin));
    }

    /// @dev The once-per-block cooldown is the QUOTE's, not the token's: a native buy-back and an ERC20
    ///      one in the same block must both go through. Same-quote-twice is what `_secondProcessInABlock`
    ///      already pins.
    function test_processBurn_nativeAndQuoteCooldownsAreIndependent() public {
        address quote = _placeQuote(LOW_QUOTE, false);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: quote, weightBps: 5_000});

        vm.prank(creator);
        RealmTaxableTokenUniV4 token = RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    _setup(true),
                    pairs,
                    _burnAndLiquidityAlloc(),
                    _emptyAntiSniperCfg(),
                    new IRealmFactory.CreatorVault[](0),
                    _noDevBuy(),
                    address(0)
                ))
        );
        _accrue(token, quote, 4_000e6);
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();

        uint256 supply = token.totalSupply();
        token.processBurn(quote, 1);
        uint256 afterQuote = token.totalSupply();
        assertLt(afterQuote, supply, "the ERC20 pool's buy-back ran");

        // No `vm.roll`: the native leg's cooldown slot is its own.
        token.processBurn(address(0), 1);
        assertLt(token.totalSupply(), afterQuote, "and the native one ran in the same block");
    }

    /////////////////////////// registerQuotes' own validation ///////////////////////////

    /// @dev The factory pre-checks the pair list, so these rules are only ever reached through the token's
    ///      own defence in depth. Exercised by pranking as the creating factory — the one caller the
    ///      function admits.
    /// @dev IN ONE EXTERNAL SELF-CALL because `tokenFactory` is transient: the factory is the admitted
    ///      caller only INSIDE the creation transaction, and under `--isolate` (which `--gas-report`
    ///      implies) every top-level call from a test is its own transaction, so a launch and a
    ///      `registerQuotes` made as two of them would see the slot already cleared. The salt is mined
    ///      OUTSIDE that call — the loop is memory-hungry enough to exhaust a single transaction's gas.
    function test_registerQuotes_rejectsAnInvalidSet() public {
        this.rejectsAnInvalidSetBody(_setup(false));
    }

    function rejectsAnInvalidSetBody(RealmFactoryUniV4Direct.DirectTokenSetup calldata setup) external {
        address token = _launchAgainstQuoteCoin(setup, _noDevBuy());
        address factory = address(directFactory);

        // `MAX_QUOTES` slots, of which index 0 is always native.
        address[] memory tooMany = new address[](RealmToken(payable(token)).MAX_QUOTES());
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = address(new QuoteCoin18());
        }
        vm.prank(factory);
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        IRealmToken(token).registerQuotes(tooMany);

        vm.prank(factory);
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        IRealmToken(token).registerQuotes(new address[](0));

        // Already registered at creation: a second slot for the same currency would give it two buffers.
        address[] memory duplicate = new address[](1);
        duplicate[0] = address(quoteCoin);
        vm.prank(factory);
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        IRealmToken(token).registerQuotes(duplicate);

        // Native is index 0's, implicitly.
        address[] memory native = new address[](1);
        native[0] = address(0);
        vm.prank(factory);
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        IRealmToken(token).registerQuotes(native);

        assertEq(IRealmToken(token).quoteCount(), 2, "the quote set is unchanged");
    }

    /////////////////////////// front-running a pending launch ///////////////////////////

    /// @dev ⚠️ A GRIEFING VECTOR, pinned rather than fixed. The graduator's caller guard stops anyone
    ///      driving `initialize` for someone else's token, but nothing stops them creating the exact pool
    ///      key straight on the pool manager: a pending `createToken` is public in the mempool, the salt
    ///      is namespaced by the creator so the token address is precomputable from it, and the real
    ///      launch then reverts inside `poolManager.initialize`. Cost to the griefer is one pool
    ///      initialization; cost to the creator is a wasted mined `0xeeaa` salt.
    function test_frontRun_preInitializedPoolBlocksTheRealLaunch() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        address predicted = _predictToken(address(directFactory), address(realmToken), creator, setup.salt);

        vm.prank(alice);
        IPoolManager(poolManagerAddress)
            .initialize(
                UniswapV4PoolConstants.realmPoolKey(predicted, address(quoteCoin), TEST_ANYPAIR_HOOK_ADDRESS),
                TickMath.getSqrtPriceAtTick(0)
            );

        vm.prank(creator);
        vm.expectRevert();
        directFactory.createToken(
            setup,
            _quotePairs(),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
        assertEq(predicted.code.length, 0, "the launch is dead: nothing was deployed at the mined address");
    }

    /////////////////////////// sniper window ///////////////////////////

    /// @dev The buy-back's pool -> token leg lands on the token's OWN balance. That is protocol plumbing,
    ///      not a sniper, so the caps must not apply to it inside the window.
    function test_sniperWindow_buyBackIntoTheTokenIsNotCapped() public {
        AntiSniperConfigs memory caps = AntiSniperConfigs({
            maxBuyPerTxBps: 10, maxWalletBps: 10, protectionWindowSeconds: 1 days, whitelist: new address[](0)
        });
        RealmTaxableTokenUniV4 token = _launchEarning(address(0), caps);
        vm.deal(address(this), 1 ether);
        token.accrueFees{value: 1 ether}();
        uint256 supply = token.totalSupply();

        token.processBurn(0);

        assertLt(token.totalSupply(), supply, "the buy-back went through inside the window");
    }

    /////////////////////////// launch price ///////////////////////////
    // Every pair opens at `LAUNCH_MARKET_CAP_X18` (2.25 ETH) of native value, an ERC20 quote converted at
    // its LIVE whitelist rate. The [1, 250] ETH bounds are checked at that same live rate, so drift from
    // the listed snapshot rate is not refused.

    /// @dev The opening market cap in whole `quote` units (X18) of a launch against it, read off the pool.
    function _openingCapInQuote(address quote, uint8 dec) internal returns (uint256 capX18) {
        vm.recordLogs();
        _launchAt(quote, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == RealmDirectGraduatorUniV4.PoolSeeded.selector) {
                (,, int24 tick,) = abi.decode(logs[i].data, (bytes32, uint16, int24, uint128));
                (, capX18) = RealmLaunchPricing.priceAtTick(tick, dec);
                return capX18;
            }
        }
        revert("PoolSeeded not emitted");
    }

    function test_launchPrice_nativeOpensAtTheFixedMarketCap() public {
        assertApproxEqRel(_openingCapInQuote(address(0), 18), 2.25 ether, 0.0101e18, "2.25 ETH");
    }

    /// @dev Six decimals at 3,500 QC per ETH: 2.25 ETH is 7,875 QC, and it follows the LIVE rate.
    function test_launchPrice_erc20OpensAtTheFixedMarketCapAtTheLiveRate() public {
        address quote = address(quoteCoin);
        assertApproxEqRel(_openingCapInQuote(quote, 6), 7_875e18, 0.0101e18, "7,875 QC at the snapshot rate");

        _mockLiveRate(quote, 2 * QC_PER_ETH);
        assertApproxEqRel(_openingCapInQuote(quote, 6), 15_750e18, 0.0101e18, "15,750 QC at twice the rate");
    }

    /// @dev A live rate 100x off the listed one either way still launches, at 2.25 ETH of the live rate,
    ///      and the preview agrees.
    function test_launchPrice_liveRateFarFromTheSnapshotStillLaunches() public {
        address quote = address(quoteCoin);
        _mockLiveRate(quote, QC_PER_ETH * 100);
        (,, uint256 previewAbove) = directFactory.previewLaunchTick(quote);
        assertApproxEqRel(previewAbove, 787_500e18, 0.0101e18, "preview: 2.25 ETH at 100x the rate");
        assertApproxEqRel(_openingCapInQuote(quote, 6), 787_500e18, 0.0101e18, "2.25 ETH at 100x the rate");

        _mockLiveRate(quote, QC_PER_ETH / 100);
        (,, uint256 previewBelow) = directFactory.previewLaunchTick(quote);
        assertApproxEqRel(previewBelow, 78.75e18, 0.0101e18, "preview: 2.25 ETH at 1/100 the rate");
        assertApproxEqRel(_openingCapInQuote(quote, 6), 78.75e18, 0.0101e18, "2.25 ETH at 1/100 the rate");
    }

    /// @dev Twenty-seven decimals at 1:1 with ETH: 2.25 units, as for native.
    function test_launchPrice_27DecimalQuote() public {
        address quote = HIGH_QUOTE;
        vm.etch(quote, address(new QuoteCoin27()).code);
        _whitelist(quote, 1e18);
        assertApproxEqRel(_openingCapInQuote(quote, 27), 2.25e18, 0.0101e18, "2.25 units");
    }

    /// @dev At an absurd rate (4.4e19 units per ETH, a ~9.9e19-unit cap) Uniswap's per-tick liquidity
    ///      ceiling binds first, with its own named error.
    function test_launchPrice_27DecimalSeedLiquidityCeiling() public {
        address quote = HIGH_QUOTE;
        vm.etch(quote, address(new QuoteCoin27()).code);
        _whitelist(quote, 4.4e37);
        _launchAt(quote, abi.encodeWithSelector(RealmDirectGraduatorUniV4.SeedLiquidityOutOfRange.selector));
    }

    /// @dev Only whitelisted ERC20 quotes launch, and delisting refuses new launches.
    function test_directInputs_quoteMustBeWhitelisted() public {
        address quote = address(new QuoteCoin());
        _expectCreateRevert(_pairs(quote), _noDevBuy(), 0, RealmFactoryUniV4Direct.QuoteNotSupported.selector);

        _whitelist(quote, QC_PER_ETH);
        _launchAt(quote, "");

        _whitelist(quote, 0);
        _expectCreateRevert(_pairs(quote), _noDevBuy(), 0, RealmFactoryUniV4Direct.QuoteNotSupported.selector);
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
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    function test_directInputs_devBuyOnAPairThatDoesNotExistIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.pairIndex = 1;
        _expectCreateRevert(_pairs(address(0)), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev No conversion happens, so a floor for one is a caller who believes something is configured
    ///      that is not.
    function test_directInputs_devBuyWithASlippageFloorIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.minQuoteOut = 1;
        _expectCreateRevert(_pairs(address(0)), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev The ERC20 pair is where a native -> quote route would mean something, and it is still refused.
    function test_directInputs_devBuyRouteOnAnErc20PairIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.route = new CorePoolKey[](1);
        devBuy.quoteAmount = 100e6;
        _expectCreateRevert(_quotePairs(), devBuy, 0, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev Crossing the two payment legs would strand one of them in the factory.
    function test_directInputs_quoteAmountOnANativePairIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;
        _expectCreateRevert(_pairs(address(0)), devBuy, 0, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev Native AND the quote: one of the two would be stranded.
    function test_directInputs_valueAndQuoteAmountTogetherAreRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;
        _expectCreateRevert(_quotePairs(), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev A quote-funded buy converts nothing, so a floor for it is refused.
    function test_directInputs_slippageFloorOnAQuoteFundedBuyIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = 100e6;
        devBuy.minQuoteOut = 1;
        _expectCreateRevert(_quotePairs(), devBuy, 0, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /// @dev The zap's route is the whitelist's: a caller-supplied one is refused even when zapping.
    function test_directInputs_devBuyRouteOnAZapIsRejected() public {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.route = new CorePoolKey[](1);
        _expectCreateRevert(_quotePairs(), devBuy, 0.01 ether, RealmFactoryUniV4Direct.InvalidDevBuy.selector);
    }

    /////////////////////////// dev-buy zap: native -> quote ///////////////////////////

    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    /// @dev Lists `asset` from `key` as a real approver would, then pins the rate to `QC_PER_ETH` so
    ///      `QC_LAUNCH_TICK` stays inside the launch bounds whatever the pool's spot.
    function _listV4(address asset, CorePoolKey memory key) internal {
        RealmAssetsWhitelist.PriceSource memory src;
        src.venue = RealmAssetsWhitelist.Venue.V4;
        src.key = key;
        vm.prank(admin);
        assetsWhitelist.setApprover(address(this), true);
        assetsWhitelist.setWhitelisted(asset, src);
        _whitelist(asset, QC_PER_ETH);
    }

    /// @dev AAPL's real native V4 pool on Robinhood: hookless, static 0.8% fee. The one native pool
    ///      among the chain's listable assets that is both hookless and actually holds liquidity at the
    ///      pinned block, which `RealmAssetsWhitelist` requires of a price source.
    function _aaplEthKey() internal pure returns (CorePoolKey memory) {
        return CorePoolKey(Currency.wrap(address(0)), Currency.wrap(AAPL), 8_000, 80, IHooks(address(0)));
    }

    /// @dev A funded no-hook V4 pool of two ERC20s opened at tick 0.
    function _erc20Pool(address a, address b) internal returns (CorePoolKey memory key) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = CorePoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        IPoolManager(poolManagerAddress).initialize(key, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(poolManagerAddress));
        deal(a, address(this), 1e30);
        deal(b, address(this), 1e30);
        IERC20(a).approve(address(lp), type(uint256).max);
        IERC20(b).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}),
            ""
        );
    }

    /// @dev A native-funded launch against `quote`, recording logs.
    function _zapLaunch(address quote, uint256 value, uint256 minQuoteOut) internal returns (address token) {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.minQuoteOut = minQuoteOut;
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.deal(creator, value);
        vm.recordLogs();
        vm.prank(creator);
        token = directFactory.createToken{value: value}(
            setup,
            _pairs(quote),
            _noDirectAlloc(_emptyTaxCfg()),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            devBuy,
            address(0)
        );
    }

    /// @dev `BuyOnDeploy.quoteSpent`, and what the graduator took out of `key`'s pool — the positive leg
    ///      of its `PoolManager.Swap` there.
    function _zapLogs(CorePoolKey memory key) internal returns (uint256 quoteSpent, uint256 converted) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(key.toId());
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (t0 == IRealmFactory.BuyOnDeploy.selector) {
                (quoteSpent,,,) = abi.decode(logs[i].data, (uint256, uint256, address[], uint256[]));
            } else if (t0 == IPoolManager.Swap.selector && logs[i].topics[1] == id) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(directGraduator), "swapper");
                (int128 a0, int128 a1) = abi.decode(logs[i].data, (int128, int128));
                // forge-lint: disable-next-line(unsafe-typecast)
                converted = uint256(uint128(a0 > 0 ? a0 : a1));
            }
        }
    }

    function _assertNoLeftovers(address quote) internal view {
        assertEq(IERC20(quote).balanceOf(address(directGraduator)), 0, "graduator keeps no quote");
        assertEq(IERC20(quote).balanceOf(address(directFactory)), 0, "factory keeps no quote");
        assertEq(address(directGraduator).balance, 0, "graduator keeps no native");
        assertEq(address(directFactory).balance, 0, "factory keeps no native");
    }

    function test_zap_nativeBuysOnAQuoteListedAgainstNative() public {
        _listV4(AAPL, _aaplEthKey());
        address token = _zapLaunch(AAPL, 0.1 ether, 1);
        (uint256 quoteSpent, uint256 converted) = _zapLogs(_aaplEthKey());

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered nothing");
        assertGt(converted, 0, "no conversion");
        assertEq(quoteSpent, converted, "quoteSpent is the converted quote, not the native sent");
        assertEq(IERC20(token).balanceOf(address(directFactory)), 0, "factory keeps no tokens");
        _assertNoLeftovers(AAPL);
    }

    /// @dev Two hops: native -> AAPL (the reference) -> QC, whose listing is against AAPL.
    function test_zap_nativeBuysThroughAReferenceListedQuote() public {
        _listV4(AAPL, _aaplEthKey());
        CorePoolKey memory qcUsdc = _erc20Pool(address(quoteCoin), AAPL);
        _listV4(address(quoteCoin), qcUsdc);
        assertEq(assetsWhitelist.referenceOf(address(quoteCoin)), AAPL, "listed against the reference");

        address token = _zapLaunch(address(quoteCoin), 0.1 ether, 0);
        (uint256 quoteSpent, uint256 converted) = _zapLogs(qcUsdc);

        assertGt(IERC20(token).balanceOf(alice), 0, "dev buy delivered nothing");
        assertGt(converted, 0, "no conversion");
        assertEq(quoteSpent, converted, "quoteSpent is the last hop's output");
        _assertNoLeftovers(address(quoteCoin));
        _assertNoLeftovers(AAPL);
    }

    function test_zap_floorAboveTheConversionReverts() public {
        _listV4(AAPL, _aaplEthKey());
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.minQuoteOut = 1e30;
        vm.deal(creator, 0.1 ether);
        _expectCreateRevert(_pairs(AAPL), devBuy, 0.1 ether, RealmDirectGraduatorUniV4.InsufficientQuoteOut.selector);
    }

    /// @dev `source` stands in for QC's whitelist listing; QC itself is whitelisted by rate in `setUp`.
    function _expectZapRouteUnavailable(RealmAssetsWhitelist.PriceSource memory source) internal {
        vm.mockCall(
            address(assetsWhitelist),
            abi.encodeCall(RealmAssetsWhitelist.priceSource, (address(quoteCoin))),
            abi.encode(source)
        );
        vm.deal(creator, 0.1 ether);
        _expectCreateRevert(
            _quotePairs(), _devBuyTo(alice), 0.1 ether, RealmFactoryUniV4Direct.DevBuyRouteUnavailable.selector
        );
    }

    function test_zap_quoteListedOnV2OrV3Reverts() public {
        RealmAssetsWhitelist.PriceSource memory src;
        src.venue = RealmAssetsWhitelist.Venue.V2;
        src.pool = makeAddr("v2Pair");
        _expectZapRouteUnavailable(src);
        src.venue = RealmAssetsWhitelist.Venue.V3;
        _expectZapRouteUnavailable(src);
    }

    /// @dev `referenceOf` reads WETH as native, but a WETH-side pool would need wrapping.
    function test_zap_quoteListedAgainstWethReverts() public {
        RealmAssetsWhitelist.PriceSource memory src;
        src.venue = RealmAssetsWhitelist.Venue.V4;
        (address c0, address c1) = address(quoteCoin) < address(WETH)
            ? (address(quoteCoin), address(WETH))
            : (address(WETH), address(quoteCoin));
        src.key = CorePoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        _expectZapRouteUnavailable(src);
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
            _pairs(makeAddr("eoaQuote")), _noDevBuy(), 0, RealmFactoryUniV4Direct.QuoteNotSupported.selector
        );
    }

    /// @dev 36 decimals is the last accepted; 37 is refused whatever the tick.
    function test_directInputs_quoteDecimalsCapAt36() public {
        // Both whitelisted at 0.1 per ETH, so ~1 whole unit is ~10 ETH and only the decimals decide.
        address quote36 = address(new QuoteCoin36());
        address quote37 = address(new QuoteCoin37());
        _whitelist(quote36, 0.1e18);
        _whitelist(quote37, 0.1e18);
        _launchAt(quote36, ""); // ~1 whole unit market cap
        _expectCreateRevert(_pairs(quote37), _noDevBuy(), 0, RealmFactoryUniV4Direct.QuoteNotSupported.selector);
    }

    function test_directAlloc_rejectsMoreQuoteRoutesThanPairs() public {
        TaxConfigsWithDirectAllocation memory cfg = _burnAndLiquidityAlloc();
        cfg.quoteRoutes = new bytes[](2);
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);
        vm.prank(creator);
        vm.expectRevert(RealmFactoryUniV4Direct.InvalidQuoteRoutes.selector);
        directFactory.createToken(
            setup,
            _quotePairs(),
            cfg,
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            _noDevBuy(),
            address(0)
        );
    }

    /// @dev With no allocation, the tax alone picks the implementation.
    function test_previewTokenImplementation_withoutAnAllocationFollowsTheTax() public view {
        assertEq(
            directFactory.previewTokenImplementation(
                _previewSetup(),
                _pairs(address(0)),
                _noDirectAlloc(_emptyTaxCfg()),
                _emptyAntiSniperCfg(),
                _noVaults(),
                _noDevBuy(),
                address(0)
            ),
            address(realmToken),
            "no tax: base implementation"
        );
        assertEq(
            directFactory.previewTokenImplementation(
                _previewSetup(),
                _pairs(address(0)),
                _noDirectAlloc(_taxCfg(300, 300, uint32(14 days))),
                _emptyAntiSniperCfg(),
                _noVaults(),
                _noDevBuy(),
                address(0)
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
            _noDirectAlloc(_emptyTaxCfg()),
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

    /// @dev Three ERC20 pairs and no native one: the token holds native at index 0 plus all three quotes,
    ///      each pool trades, and the LAST quote's earnings buffers work like the first's.
    function test_multiPair_threeErc20QuotesWithoutANativePair() public {
        address third = address(new QuoteCoin());
        _whitelist(third, QC_PER_ETH);
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](3);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(quoteCoin), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: _newQuote18(), weightBps: 3_000});
        pairs[2] = RealmFactoryUniV4Direct.DirectPair({quote: third, weightBps: 2_000});
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(true);

        vm.prank(creator);
        RealmTaxableTokenUniV4 token = RealmTaxableTokenUniV4(
            payable(directFactory.createToken(
                    setup,
                    pairs,
                    _burnAndLiquidityAlloc(),
                    _emptyAntiSniperCfg(),
                    new IRealmFactory.CreatorVault[](0),
                    _noDevBuy(),
                    address(0)
                ))
        );

        assertEq(token.quoteCount(), 4, "native plus three ERC20 quotes");
        assertEq(token.quotes(3), third, "the third ERC20 is the last quote");
        QuoteCoin(third).mintTo(alice, 1_000e6);
        _swapQuotePool(alice, address(token), third, true, 100e6);
        assertGt(token.balanceOf(alice), 0, "the third pool trades");

        _accrue(token, third, 4_000e6);
        token.processLiquidity(third);
        (uint256[2] memory ids,) = token.getLiquidityWalls(third);
        assertGt(ids[0], 0, "the last quote's liquidity buffer placed a wall");
    }

    /// @dev The `MAX_PAIRS` launch: native plus two ERC20s, one `PoolSeeded` per pool in pair order with
    ///      its own weight, and the supply fully seeded or burned.
    function test_multiPair_threePoolsAreAllSeeded() public {
        address quote18 = _newQuote18();
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](3);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: address(quoteCoin), weightBps: 3_000});
        pairs[2] = RealmFactoryUniV4Direct.DirectPair({quote: quote18, weightBps: 2_000});

        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _setup(false);
        vm.recordLogs();
        vm.prank(creator);
        address token = directFactory.createToken(
            setup,
            pairs,
            _noDirectAlloc(_emptyTaxCfg()),
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
    ///      the remainder. At ~7.9e-18 raw QC per raw coin (the 7,875 QC opening cap) the full band costs
    ///      ~7.9e37 raw QC, so 1e39 cannot be filled.
    function test_devBuy_largerThanTheBandCanFillReverts() public {
        uint256 spend = 1e39;
        quoteCoin.mintTo(creator, spend);
        vm.prank(creator);
        quoteCoin.approve(address(directFactory), spend);
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _devBuyTo(alice);
        devBuy.quoteAmount = spend;

        _expectCreateRevert(_quotePairs(), devBuy, 0, RealmDirectGraduatorUniV4.DevBuyNotFilled.selector);
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
            setup, pairs, _noDirectAlloc(_emptyTaxCfg()), caps, new IRealmFactory.CreatorVault[](0), devBuy, address(0)
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

        address nativeToken = _cappedLaunchWithDevBuy(_pairs(address(0)), 0, 1 ether, _caps(10, 10));
        uint256 bag = IERC20(nativeToken).balanceOf(alice);
        assertGt(_swapSellV4(alice, nativeToken, sell, 0, true), 0, "native-pool sell returned ETH");
        assertEq(bag - IERC20(nativeToken).balanceOf(alice), sell, "the whole native-pool sell went through");

        address quoteToken = _cappedLaunchWithDevBuy(_quotePairs(), 0, 20_000e6, _caps(10, 10));
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
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: quoteIsC0,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
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
            _quotePairs(),
            _noDirectAlloc(_emptyTaxCfg()),
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
        RealmTaxableTokenUniV4 token = _launchEarning(_placeQuote(LOW_QUOTE, false), _emptyAntiSniperCfg());

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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
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
        RealmTaxableTokenUniV4 token = _launchEarning(quote, _emptyAntiSniperCfg());
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
