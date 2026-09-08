// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";

/// @notice Stand-in for the universal router on its no-fill branch: it takes nothing from the pool and
///         sweeps the whole native input back to the caller. A real pool reaches this with an amount too
///         small to move the tick, so the branch is mocked rather than contrived.
contract RefundingUniversalRouterStub {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        (bool sent,) = msg.sender.call{value: msg.value}("");
        require(sent, "refund failed");
    }
}

/// @notice Claims a native dividend and re-enters `processBurn` from its `receive()`. The token has
///         already sent the payout at that point but has not yet reduced `dividendsOwed`, so the
///         contract reads as fully reserved from the inside.
contract ReentrantDividendClaimer {
    RealmTaxableTokenUniV4 public token;
    bool public reentered;

    function setToken(RealmTaxableTokenUniV4 t) external {
        token = t;
    }

    function claim() external {
        token.claimDividends();
    }

    receive() external payable {
        if (address(token) == address(0) || reentered) return;
        reentered = true;
        token.processBurn(0);
    }
}

/// @notice Integration tests for the V4 buy-back-and-burn earnings-allocation leg.
contract BurnTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    /// @dev Creates a taxable V4 token with a `burnBps` earnings allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createBurnTaxToken(uint16 sellTaxBps, uint16 burnBps) internal returns (address token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "BurnToken",
            symbol: "BURN",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: burnBps, dividendsBps: 0, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_burnBps_storedAtCreation() public {
        address token = _createBurnTaxToken(400, 5000);
        assertEq(RealmTaxableTokenUniV4(payable(token)).burnBps(), 5000, "burnBps stored via new overload");
    }

    function test_v4Burn_accruesThenProcessBurnReducesSupply() public {
        address token = _createBurnTaxToken(400, 5000); // 4% sell tax; 50% of earnings → burn
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // Sell to accrue tax: hook -> accrueFees -> _allocateEthEarnings -> burn slice buffered as ETH.
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 pending = burnToken.burnPendingEth();
        assertGt(pending, 0, "burn ETH should accrue from the sell tax");

        uint256 supplyBefore = IERC20(token).totalSupply();
        burnToken.processBurn(0);

        // The buy-back itself pays LP fee (and tax, window open), a fraction of which re-accrues; so the
        // buffer is drained well below `pending`, not necessarily to exactly 0.
        assertLt(burnToken.burnPendingEth(), pending, "burn buffer drained");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "total supply reduced by the buy-back-and-burn");
    }

    /// @dev Native the router sweeps back must stay on the burn ledger. `burnPendingEth` is debited by the
    ///      full `ethIn` up front, so without the credit-back the returned native becomes stray and the
    ///      permissionless `sweepStrayEth` re-splits an allocation earmarked for burning into the
    ///      dividend / liquidity / fund buckets. Mirrors `processLiquidity`'s own re-earmark, except the
    ///      measure has to be `_sweepableNative()`: a buy-back is a SWAP, so the hook's `accrueFees` can
    ///      land native here mid-call and a raw balance delta would count it as an unspent refund.
    function test_v4ProcessBurn_unspentEthStaysEarmarked() public {
        address token = _createBurnTaxToken(400, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();
        _swapSell(buyer, IERC20(token).balanceOf(buyer) / 2, 0, true);

        uint256 pending = burnToken.burnPendingEth();
        assertGt(pending, 0, "burn ETH should accrue from the sell tax");

        vm.etch(burnToken.UNIV4_UNIVERSAL_ROUTER(), address(new RefundingUniversalRouterStub()).code);

        uint256 ethBefore = token.balance;
        burnToken.processBurn(0);

        assertEq(burnToken.burnPendingEth(), pending, "swept-back ETH stays earmarked for burning");
        assertEq(token.balance, ethBefore, "and never left the token");
    }

    /// @dev Same as `_createBurnTaxToken`, plus a NATIVE dividends leg, so the token holds both a burn
    ///      buffer and a payout that hands control to a holder.
    function _createBurnAndDividendToken(uint16 burnBps, uint16 dividendsBps) internal returns (address token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "BurnDivToken",
            symbol: "BDIV",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: burnBps, dividendsBps: dividendsBps, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    /// @dev `processBurn` must measure its spend from the RAW balance and the UNCLAMPED reserves, never
    ///      from `_sweepableNative()`. Re-entered from inside a native dividend payout — the ETH already
    ///      sent, `dividendsOwed` not yet reduced — the clamp pins the stray reading to zero on both
    ///      sides of the buy-back, so the call concludes it spent nothing and hands the whole `ethIn`
    ///      back to `burnPendingEth`. Repeat once per block and the burn budget becomes phantom, spent
    ///      out of the dividend and liquidity reserves until holders' claims start failing.
    function test_v4ProcessBurn_reenteredFromADividendPayout_doesNotRefillTheBuffer() public {
        address token = _createBurnAndDividendToken(2500, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // The attacker needs a real, dividend-eligible balance to have anything to claim.
        ReentrantDividendClaimer claimer = new ReentrantDividendClaimer();
        claimer.setToken(burnToken);
        // `processBurn` is keeper-gated, so the re-entry is only REACHABLE for a keeper. The gate is not
        // what this test is about: the accounting must hold on its own, because a keeper key is hot and
        // the buffer must not depend on it staying uncompromised.
        vm.prank(admin);
        keepersRegistry.setKeeper(address(claimer), true);
        uint256 stake = IERC20(token).balanceOf(buyer) / 2;
        vm.prank(buyer);
        IERC20(token).transfer(address(claimer), stake);

        // Earnings fill both buffers at once: 25% to burn, half the remainder to holders.
        vm.deal(address(this), 4 ether);
        burnToken.accrueFees{value: 4 ether}();

        burnToken.processDividends(0, new address[](0));
        skip(burnToken.DIVIDEND_DRIP_DURATION());
        vm.roll(block.number + 1);

        uint256 burnPending = burnToken.burnPendingEth();
        assertGt(burnPending, 0, "burn buffer funded");
        assertGt(burnToken.previewDividend(address(claimer)), 0, "attacker has a payout to trigger on");

        uint256 supplyBefore = IERC20(token).totalSupply();
        claimer.claim();

        assertTrue(claimer.reentered(), "the payout did re-enter processBurn");
        assertLt(IERC20(token).totalSupply(), supplyBefore, "the buy-back really spent the ETH and burned");
        assertLt(burnToken.burnPendingEth(), burnPending, "and the buffer was debited for it, not refilled");
    }

    /// @dev The caller picks `minTokensOut`, so a permissionless caller could set it to zero around
    ///      their own price manipulation and keep almost the whole spend. The cap and the cooldown bound
    ///      that per block; only the gate bounds the fraction. See `RealmKeepersRegistry`.
    function test_v4ProcessBurn_refusesANonKeeper() public {
        address token = _createBurnTaxToken(400, 5000);
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        RealmTaxableTokenUniV4(payable(token)).processBurn(0);
    }

    function test_v4ProcessBurn_revertsWhenNothingPending() public {
        address token = _createBurnTaxToken(400, 5000);
        vm.expectRevert(RealmTaxableTokenUniV4.NothingToBurn.selector);
        RealmTaxableTokenUniV4(payable(token)).processBurn(0);
    }

    /// @dev Sandwich-extraction bound: at most `MAX_EARNINGS_PER_PROCESS` spent per call, once per block.
    function test_v4ProcessBurn_cappedPerCallAndOncePerBlock() public {
        address token = _createBurnTaxToken(400, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        // Overfill the buffer past the per-call cap via a stray-ETH sweep (50% burn allocation).
        vm.deal(address(burnToken), 1 ether);
        burnToken.sweepStrayEth();
        uint256 pending = burnToken.burnPendingEth();
        uint256 cap = burnToken.MAX_EARNINGS_PER_PROCESS();
        assertGt(pending, cap, "setup: buffer must exceed the cap");

        burnToken.processBurn(0);
        // At most `cap` spent; the remainder (plus any re-accrual from the buy-back's own fees) stays.
        assertGe(burnToken.burnPendingEth(), pending - cap, "spend capped per call");

        vm.expectRevert(RealmTaxableTokenUniV4.ProcessCooldown.selector);
        burnToken.processBurn(0);

        vm.roll(block.number + 1);
        burnToken.processBurn(0); // next block processes again
    }

    /// @dev The router's `amountOutMinimum` is a `uint128`, so a floor above that must fail the buy-back
    ///      rather than truncate into `uint128(2**128) == 0`. Belt and braces: the encoding's `TAKE_ALL`
    ///      minimum is the UNtruncated value and would reject the take anyway; the explicit guard is what
    ///      makes the property independent of that, and matches `UniversalRouterVenue.swapNativeToAssetV4`.
    function test_v4ProcessBurn_unrepresentableMinOutFailsInsteadOfTruncating() public {
        address token = _createBurnTaxToken(400, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();
        _swapSell(buyer, IERC20(token).balanceOf(buyer) / 2, 0, true);

        uint256 pending = burnToken.burnPendingEth();
        assertGt(pending, 0, "burn ETH should accrue from the sell tax");

        vm.expectRevert(RealmTaxableTokenUniV4.BuyBackFailed.selector);
        burnToken.processBurn(uint256(type(uint128).max) + 1);

        assertEq(burnToken.burnPendingEth(), pending, "the buffer is untouched by the rejected call");
    }

    function test_v4SweepStrayEth_routesStrayToBurnBuffer() public {
        address token = _createBurnTaxToken(400, 5000);
        testToken = token;
        RealmTaxableTokenUniV4 burnToken = RealmTaxableTokenUniV4(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 2 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.deal(address(burnToken), 1 ether); // stray ETH
        uint256 pendingBefore = burnToken.burnPendingEth();

        burnToken.sweepStrayEth();

        // 50% burn allocation → ~half the stray becomes burn buffer; the rest routes to the fund wallets.
        assertApproxEqAbs(burnToken.burnPendingEth() - pendingBefore, 0.5 ether, 1, "half of stray -> burn buffer");
    }

    function test_createToken_revertsOnAllocationForDecayOnlyToken() public {
        // The V4 factory carries its own copy of the gate: decay-only tokens (no long-term static tax)
        // cannot configure an earnings allocation.
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "DecayOnly",
            symbol: "DEC",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 0,
            taxDurationSeconds: 0,
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 1000,
            sellTaxDecayStartBps: 1000,
            taxDecayDuration: 20 minutes,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 5000, dividendsBps: 0, liquidityBps: 0, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.EarningsAllocationRequiresTax.selector);
        factoryTax.createToken(
            setup,
            cfg,
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }
}
