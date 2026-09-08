// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {RealmDividendLogicUniV2} from "src/tokens/RealmDividendLogicUniV2.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {divRate, divLastUpdate} from "test/helpers/DividendViewHelpers.sol";

/// @notice Integration tests for holder dividends on Uniswap V2. Two things are V2-specific and get the
///         attention here: a leg paying the TOKEN ITSELF must be carved in token space (a V2 pair reverts
///         `INVALID_TO` when asked to deliver a token to its own address), and the automatic swap-back —
///         which fires on ordinary sells, with no attacker and no privilege — must not sweep the dividend
///         money back into the fund/burn/liquidity split.
contract DividendsTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    address internal holder2 = makeAddr("holder2");

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function _createDividendToken(uint16 dividendsBps, address asset) internal returns (address token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "DivV2",
            symbol: "DV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
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
                burnBps: 0, dividendsBps: dividendsBps, liquidityBps: 0, dividendToken: asset
            })
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
    }

    /// @dev A graduated dividend token with `buyer` holding the whole float.
    function _graduated(address asset) internal returns (RealmTaxableTokenUniV2 token) {
        address addr = _createDividendToken(5_000, asset);
        testToken = addr;
        _launchpadBuy(addr, 1 ether);
        _graduateToken();
        return RealmTaxableTokenUniV2(payable(addr));
    }

    function _nativeToken() internal returns (RealmTaxableTokenUniV2) {
        return _graduated(address(0));
    }

    function _selfToken() internal returns (RealmTaxableTokenUniV2) {
        return _graduated(address(type(uint160).max));
    }

    /// @dev A token paying a third ERC20, bought on the direct WETH/DAI Uniswap-V2 pair.
    function _thirdAssetToken() internal returns (RealmTaxableTokenUniV2) {
        return _graduated(DAI);
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _accrue(RealmTaxableTokenUniV2 token, uint256 amount) internal {
        vm.deal(address(this), amount);
        token.accrueFees{value: amount}();
    }

    receive() external payable {}

    ///////////////////////// stray native /////////////////////////

    /// @dev V2 used to have no way out for stray native at all: `rescueTokens(address(0))` was removed
    ///      with the ETH branch, and the only sweep left was inside the swap-back — which needs tax
    ///      tokens to run. Past the tax window, with the tax pool drained, anything sitting here was
    ///      stuck forever. `sweepStrayEth` is that exit, and it is shared with V4 rather than V4-only.
    function test_sweepStrayEth_recoversStrayNativeOnV2() public {
        RealmTaxableTokenUniV2 token = _nativeToken();

        // Past the tax window: no fresh tax can ever accrue, so no swap-back will ever fire again.
        skip(uint256(token.taxDurationSeconds()) + 1);
        assertEq(token.pendingNative(), 0, "nothing buffered yet");

        vm.deal(address(token), address(token).balance + 1 ether);
        token.sweepStrayEth();

        // Half to the dividend buffer, half to the fund wallets: the burn and liquidity shares are zero
        // for this token, so the split is the plain dividends/fund one.
        assertEq(token.pendingNative(), 0.5 ether, "stray native became holder earnings");
    }

    /// @dev The reason the swap-back stopped sweeping the whole balance. Router refunds from an earlier
    ///      `processLiquidity` had no token-space burn/liquidity peel, so folding them into the swap's
    ///      own split renormalizes them over a denominator that already excludes those buckets — paying
    ///      the dividend pot a share earmarked for burning. They belong to `sweepStrayEth` instead.
    function test_swapBackRoutesOnlyItsOwnProceeds() public {
        RealmTaxableTokenUniV2 token = _nativeToken();

        // Accrue some sell tax as tokens, so there is a swap-back to run.
        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);
        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        assertGt(taxBalance, 0, "sell tax accrued as tokens");

        // Stray native sitting in the token, on top of the tax pool.
        vm.deal(address(token), address(token).balance + 1 ether);
        uint256 strayBefore = address(token).balance;

        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        // The swap-back routed its own proceeds — and only those. Under the old whole-balance sweep the
        // 1 ETH would have been split too, depositing half of it to the fund wallets and leaving the
        // balance BELOW what was already there.
        assertGt(token.pendingNative(), 0, "the swap-back routed its own proceeds");
        assertGe(address(token).balance, strayBefore, "the stray native was not swept into the swap-back");
    }

    ///////////////////////// native leg /////////////////////////

    function test_nativeDividends_accrueFundAndPay() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        assertEq(token.pendingNative(), 0.5 ether, "half the earnings buffered for holders");

        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), 0.5 ether, "the whole buffer funded the stream");
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 before = buyer.balance;
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processDividends(0, holders);
        assertApproxEqRel(buyer.balance - before, 0.5 ether, 1e12, "sole holder takes the whole stream");
    }

    /// @dev THE automatic leak. `_processCollectedTokens` fires on every sell that crosses the swap-back
    ///      threshold and used to route `address(this).balance` through the split — which would re-split
    ///      the dividend buffer into fund/burn/liquidity on every trade, forever, with nobody attacking.
    function test_autoSwapBackDoesNotRecycleTheDividendBuffer() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        uint256 buffered = token.pendingNative();
        assertGt(buffered, 0, "buffer funded");

        // A real sell large enough to trigger the automatic swap-back.
        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        // The buffer only ever GREW (the sell's own tax adds to it); nothing was swept out of it.
        assertGe(token.pendingNative(), buffered, "dividend buffer never shrinks on a swap-back");
        assertGe(address(token).balance, token.pendingNative(), "buffer backed by a real balance");
    }

    /// @dev Undelivered dividends are holders' money sitting in the token's balance. The swap-back's
    ///      ETH sweep must not see them either.
    function test_undeliveredDividendsSurviveTheSwapBack() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), 0.5 ether, "the stream is funded");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 2;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        assertEq(token.dividendsOwed(), 0.5 ether, "owed untouched");
        assertGe(address(token).balance, 0.5 ether, "and still fully backed");
    }

    ///////////////////////// self-token leg (token space) /////////////////////////

    function test_selfTokenLeg_carvedInTokenSpaceDuringTheSwapBack() public {
        RealmTaxableTokenUniV2 token = _selfToken();
        assertEq(token.dividendToken(), address(token), "self-token payout configured");

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);

        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        assertGt(taxBalance, 0, "sell tax accrued as tokens");

        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "dividend tokens set aside in token space");
        assertEq(token.pendingNative(), 0, "and nothing buffered as native for this leg");
        assertGe(IERC20(address(token)).balanceOf(address(token)), buffered, "buffer backed by real balance");
    }

    /// @dev The committed token buffer must be invisible to the tax pool, or the next swap-back sells the
    ///      holders' dividend out from under them.
    function test_selfTokenBuffer_isNotReprocessedAsTax() public {
        RealmTaxableTokenUniV2 token = _selfToken();

        uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 10;
        _swapSellV2(buyer, address(token), sellAmount, 0, true);
        uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
        vm.prank(admin);
        token.swapBack(taxBalance, 0);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "buffer funded");

        // A second swap-back asking for far more than is available must clamp to the uncommitted balance.
        vm.roll(block.number + 1);
        vm.prank(admin);
        token.swapBack(type(uint128).max, 0);
        assertEq(token.dividendPendingTokens(), buffered, "committed tokens untouched");
        assertGe(IERC20(address(token)).balanceOf(address(token)), buffered, "still backed");
    }

    function test_selfTokenLeg_fundsAndPaysInTokens() public {
        RealmTaxableTokenUniV2 token = _selfToken();

        // Sell repeatedly so the token-space buffer crosses SWAP_THRESHOLD.
        for (uint256 i; i < 4; ++i) {
            uint256 sellAmount = IERC20(address(token)).balanceOf(buyer) / 5;
            _swapSellV2(buyer, address(token), sellAmount, 0, true);
            vm.roll(block.number + 1);
            uint256 taxBalance = IERC20(address(token)).balanceOf(address(token));
            vm.prank(admin);
            token.swapBack(taxBalance, 0);
        }

        uint256 buffered = token.dividendPendingTokens();
        vm.assume(buffered >= token.SWAP_THRESHOLD());

        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), buffered, "the token buffer funded the stream, with no conversion");
        assertEq(token.dividendPendingTokens(), 0, "buffer consumed");
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 before = IERC20(address(token)).balanceOf(buyer);
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processDividends(0, holders);
        assertGt(IERC20(address(token)).balanceOf(buyer), before, "holder paid in the token itself");
    }

    ///////////////////////// rescue guard /////////////////////////

    /// @dev The token's own balance is never rescuable, which already covers the self-token pot; this
    ///      pins the behaviour so a future relaxation has to think about the dividend money too.
    function test_rescueTokens_cannotTakeTheSelfTokenPot() public {
        RealmTaxableTokenUniV2 token = _selfToken();
        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        vm.expectRevert(RealmTaxableToken.CannotRescueSelfToken.selector);
        token.rescueTokens(address(token));
    }

    /// @dev The self-token pot is protected by a blanket `CannotRescueSelfToken` guard, so it never
    ///      exercises the arithmetic. A THIRD-ASSET pot has no such guard: `rescueTokens` walks straight
    ///      into `_sweepableAsset`, and the only thing between the owner and holders' money is the
    ///      `committedDividends` subtraction. The stray balance dealt on top is what proves the
    ///      subtraction is exact rather than the rescue being a blanket no-op.
    function test_rescueTokens_cannotTakeUndeliveredThirdAssetDividends() public {
        RealmTaxableTokenUniV2 token = _thirdAssetToken();
        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders());

        uint256 pot = token.dividendsOwed();
        assertGt(pot, 0, "a DAI stream is funded");
        assertEq(token.committedDividends(DAI), pot, "the whole of it is owed to holders");
        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "backed by a real DAI balance");

        uint256 stray = 123e18;
        deal(DAI, address(token), pot + stray);

        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        token.rescueTokens(DAI);

        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "the stray left, the owed pot stayed");
    }

    ///////////////////////// the delegatecall extension /////////////////////////

    /// @dev The dividend entry points are stubs that `delegatecall` into a separate contract,
    ///      because their bodies do not fit in the clone's implementation alongside everything else.
    ///      What has to hold for that to be safe is that the extension writes the TOKEN's storage and
    ///      keeps none of its own — which is exactly what a funded stream lets us observe.
    function test_extension_streamStateLandsOnTheTokenNotTheExtension() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        RealmDividendLogicUniV2 extension = RealmDividendLogicUniV2(payable(token.dividendLogic()));

        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders());

        assertGt(token.dividendsOwed(), 0, "the token's stream was funded through the delegatecall");
        assertGt(divRate(address(token), 0), 0, "and its slope is set");
        assertEq(extension.dividendsOwed(), 0, "the extension kept nothing of its own");
        assertEq(divRate(address(extension), 0), 0, "and never ran a stream of its own");
        assertEq(address(extension).balance, 0, "the extension holds no money");
    }

    /// @dev Every clone of one implementation shares that implementation's extension: it is an
    ///      `immutable` on the implementation, so a clone reads it out of the implementation's code.
    function test_extension_isSharedByEveryCloneOfAnImplementation() public {
        RealmTaxableTokenUniV2 a = _nativeToken();
        RealmTaxableTokenUniV2 b = _nativeToken();

        address logic = realmTaxTokenV2.DIVIDEND_LOGIC();
        assertGt(logic.code.length, 0, "the implementation deployed its extension");
        assertEq(a.dividendLogic(), logic, "first clone");
        assertEq(b.dividendLogic(), logic, "second clone");
    }

    /// @dev An extension is an execution body, not a token. Reverting every token entry point is what
    ///      makes the machinery behind them unreachable — the saving that buys the cold half its room —
    ///      and it is also the honest answer to anyone who arrives at the wrong address.
    function test_extension_disownsTheTokenEntryPoints() public {
        RealmDividendLogicUniV2 extension = RealmDividendLogicUniV2(payable(realmTaxTokenV2.DIVIDEND_LOGIC()));

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.transfer(buyer, 1);

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.getTaxConfig();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.markGraduated();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.accrueFees{value: 0}();

        vm.expectRevert(DividendDistributionLogic.NotAToken.selector);
        extension.rescueTokens(DAI);
    }

    ///////////////////////// the threshold /////////////////////////

    /// @dev The threshold used to stop applying the moment the V2 tax window closed, on the theory that
    ///      no further earnings could arrive. They can: `accrueFees` and `sweepStrayEth` are both
    ///      permissionless. Staleness is the only bypass now, and reaching it costs 30 days of a
    ///      completely idle token.
    /// @dev Under the drip a dust distribution could no longer stall anything even if it went through —
    ///      it would just set a dust slope. The threshold is a gas floor now, not a safety one; this
    ///      pins that it still holds.
    function test_aWeiPushedInAfterTheTaxWindowCannotForceADistribution() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        skip(uint256(token.taxDurationSeconds()) + 1); // no fresh tax can ever accrue

        vm.deal(address(token), address(token).balance + 2 wei);
        token.sweepStrayEth();
        assertGt(token.pendingNative(), 0, "the attacker's dust did reach the buffer");

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), 0, "no dust stream was funded");
    }

    /// @dev The SELF-TOKEN counterpart of the grief above, which the native fix did not reach: the
    ///      token-space funding kept "the tax window has closed" as its bypass. Donate dust TOKENS to
    ///      the contract and the post-window drain in `_update` carves a dividend slice out of them.
    ///      Staleness is the only bypass here too.
    function test_dustDonatedAfterTheTaxWindowCannotForceASelfTokenDistribution() public {
        RealmTaxableTokenUniV2 token = _selfToken();
        skip(uint256(token.taxDurationSeconds()) + 1); // no fresh tax can ever accrue

        // The griefer's dust, donated straight to the contract...
        vm.prank(buyer);
        IERC20(address(token)).transfer(address(token), 1e12);
        // ...and any sell drains it through the split, dividend slice included.
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 100, 0, true);

        uint256 buffered = token.dividendPendingTokens();
        assertGt(buffered, 0, "the dust did reach the dividend buffer");
        assertLt(buffered, token.SWAP_THRESHOLD(), "and it is far below the threshold");

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), 0, "no dust stream was funded on the self-token leg either");
    }

    ///////////////////////// creation-time guard /////////////////////////

    /// @dev A payout asset with a zero share used to sail through creation: `hasAllocation` reads the
    ///      three bps only, so `initializeEarningsAllocation` never ran and the clone could never pay
    ///      dividends — silently, and with no way back, since that initializer only runs at creation.
    function test_createToken_rejectsAPayoutAssetWithNoDividendShare() public {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "DivV2",
            symbol: "DV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
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
                burnBps: 0, dividendsBps: 0, liquidityBps: 0, dividendToken: DAI
            })
        });
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.DividendAssetWithoutShare.selector);
        factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
    }
}
