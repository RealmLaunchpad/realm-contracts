// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithMultiAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {RealmDividendLogicUniV2} from "src/tokens/RealmDividendLogicUniV2.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";

/// @notice Integration tests for holder dividends on Uniswap V2. Two things are V2-specific and get the
///         attention here: a leg paying the TOKEN ITSELF must be carved in token space (a V2 pair reverts
///         `INVALID_TO` when asked to deliver a token to its own address), and the automatic swap-back —
///         which fires on ordinary sells, with no attacker and no privilege — must not sweep the dividend
///         money back into the fund/burn/liquidity split.
contract DividendsTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    address internal holder2 = makeAddr("holder2");

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
        // Robinhood's xStock/WETH V2 pairs hold ~0.005 ETH a side, under the default depth floor of
        // 10x MAX_EARNINGS_PER_PROCESS. The floor is per-chain configurable; drop it so the V2 route is
        // exercised rather than rejected as too shallow.
        vm.prank(admin);
        dividendSwapRegistry.setDefaultThreshold(0.001 ether);
    }

    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    function _createDividendToken(uint16 dividendsBps, address asset) internal returns (address token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "DivV2",
            symbol: "DV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: _multiAlloc(0, dividendsBps, 0, asset)
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

    /// @dev A token paying a third ERC20, bought on the direct WETH/MSFT Uniswap-V2 pair.
    function _thirdAssetToken() internal returns (RealmTaxableTokenUniV2) {
        return _graduated(MSFT);
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
        assertEq(token.dividendsOwed(), 0.5 ether, "the whole buffer was distributed");

        uint256 before = buyer.balance;
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processDividends(0, holders);
        assertApproxEqRel(buyer.balance - before, 0.5 ether, 1e12, "sole holder takes the whole distribution");
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
        assertEq(token.dividendsOwed(), buffered, "the token buffer was distributed, with no conversion");
        assertEq(token.dividendPendingTokens(), 0, "buffer consumed");

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
        assertGt(pot, 0, "a MSFT stream is funded");
        assertEq(token.committedDividends(MSFT), pot, "the whole of it is owed to holders");
        assertEq(IERC20(MSFT).balanceOf(address(token)), pot, "backed by a real MSFT balance");

        uint256 stray = 123e18;
        deal(MSFT, address(token), pot + stray);

        vm.prank(admin); // the launchpad owner; factory-deployed tokens have no token owner
        token.rescueTokens(MSFT);

        assertEq(IERC20(MSFT).balanceOf(address(token)), pot, "the stray left, the owed pot stayed");
    }

    ///////////////////////// the delegatecall extension /////////////////////////

    /// @dev The dividend entry points are stubs that `delegatecall` into a separate contract,
    ///      because their bodies do not fit in the clone's implementation alongside everything else.
    ///      What has to hold for that to be safe is that the extension writes the TOKEN's storage and
    ///      keeps none of its own — which is exactly what a distribution lets us observe.
    function test_extension_dividendStateLandsOnTheTokenNotTheExtension() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        RealmDividendLogicUniV2 extension = RealmDividendLogicUniV2(payable(token.dividendLogic()));

        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders());

        assertGt(token.dividendsOwed(), 0, "the token distributed through the delegatecall");
        assertGt(token.dividendRewardPerToken(0), 0, "and its accumulator moved");
        assertEq(extension.dividendsOwed(), 0, "the extension kept nothing of its own");
        assertEq(extension.dividendRewardPerToken(0), 0, "and its accumulator never moved");
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

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        extension.transfer(buyer, 1);

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        extension.getTaxConfig();

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        extension.markGraduated();

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        extension.accrueFees{value: 0}();

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        extension.rescueTokens(MSFT);
    }

    /// @dev A V2 token earns in native only, so the quote-routes overload has nothing to configure: it is
    ///      refused outright, on the extension and through a live token's delegatecall alike, before any
    ///      caller check — never silently accepted as an empty list.
    function test_extension_refusesTheQuoteRoutesOverload() public {
        RealmDividendLogicUniV2 extension = RealmDividendLogicUniV2(payable(realmTaxTokenV2.DIVIDEND_LOGIC()));
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        extension.initializeEarningsAllocation(
            0, 5_000, 0, new address[](0), new uint16[](0), new bytes[](0), new bytes[](0)
        );

        RealmTaxableTokenUniV2 token = RealmTaxableTokenUniV2(payable(_createDividendToken(5_000, address(0))));
        vm.expectRevert(RealmToken.InvalidQuotes.selector);
        token.initializeEarningsAllocation(
            0, 5_000, 0, new address[](0), new uint16[](0), new bytes[](0), new bytes[](0)
        );
    }

    ///////////////////////// dust cannot force a distribution /////////////////////////

    /// @dev `accrueFees` and `sweepStrayEth` are both permissionless, so anyone can push dust into the
    ///      buffer at any time — including after the tax window has closed and no honest earnings can
    ///      ever arrive again. What stops that becoming a dust stream is the KEEPER GATE, not a size
    ///      floor: the griefer can fill the buffer but cannot make anyone convert it.
    /// @dev And if a keeper does convert it, nothing breaks. Credit is instant (the drip that a dust
    ///      distribution could once stall is long gone), so a dust distribution credits dust and ends.
    function test_aWeiPushedInAfterTheTaxWindowCannotForceADistribution() public {
        RealmTaxableTokenUniV2 token = _nativeToken();
        skip(uint256(token.taxDurationSeconds()) + 1); // no fresh tax can ever accrue

        vm.deal(address(token), address(token).balance + 2 wei);
        token.sweepStrayEth();
        assertGt(token.pendingNative(), 0, "the attacker's dust did reach the buffer");
        assertFalse(token.dividendsStale(0), "precondition: the hatch is shut on a live token");

        vm.prank(makeAddr("griefer"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), 0, "no dust stream was funded");
    }

    /// @dev The SELF-TOKEN counterpart: donate dust TOKENS to the contract and the post-window drain in
    ///      `_update` carves a dividend slice out of them. Same answer — the keeper gate, not a floor.
    function test_dustDonatedAfterTheTaxWindowCannotForceASelfTokenDistribution() public {
        RealmTaxableTokenUniV2 token = _selfToken();
        skip(uint256(token.taxDurationSeconds()) + 1); // no fresh tax can ever accrue

        // The griefer's dust, donated straight to the contract...
        vm.prank(buyer);
        IERC20(address(token)).transfer(address(token), 1e12);
        // ...and any sell drains it through the split, dividend slice included.
        _swapSellV2(buyer, address(token), IERC20(address(token)).balanceOf(buyer) / 100, 0, true);

        assertGt(token.dividendPendingTokens(), 0, "the dust did reach the dividend buffer");

        vm.prank(makeAddr("griefer"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
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
        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: _multiAlloc(0, 0, 0, MSFT)
        });
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.DividendAssetWithoutShare.selector);
        factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
    }
}
