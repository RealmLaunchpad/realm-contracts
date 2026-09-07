// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {
    TaxConfigsWithAllocation,
    EarningsAllocationConfig,
    TaxConfigsWithMultiAllocation,
    EarningsAllocationMultiConfig
} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {divRate, divLastUpdate} from "test/helpers/DividendViewHelpers.sol";

/// @notice Integration tests for the holder-dividends earnings-allocation leg on Uniswap V4: the
///         continuous accumulator, threshold-gated funding, the drip that makes a flash loan worthless,
///         the push payout, and the committed-funds guards that keep undelivered dividends away from
///         every sweep path.
/// @notice Stand-in for the universal router on a PARTIAL fill: the pool takes half the native, the rest
///         comes back with the router's `SWEEP`, and some token is delivered either way. A real V4 pool
///         reaches this when the swap cannot absorb the whole input, so the branch is mocked rather than
///         contrived.
contract PartialFillRouterStub {
    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        (bool sent,) = msg.sender.call{value: msg.value / 2}("");
        require(sent, "refund failed");
        IERC20(msg.sender).transfer(msg.sender, 1e18);
    }
}

contract DividendsTaxTokenV4Tests is TaxTokenUniV4BaseTests {
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address internal holder2 = makeAddr("holder2");

    /// @dev Creates a taxable V4 token routing `dividendsBps` of post-graduation earnings to holders,
    ///      paid in `asset`. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createDividendToken(uint16 dividendsBps, address asset) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivToken",
            symbol: "DIV",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
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
        token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _batch(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @dev A graduated, dividend-paying token with `buyer` as its only holder. Graduation itself
    ///      starts the accumulator.
    function _graduatedDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        address addr = _createDividendToken(5_000, address(0));
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return LivoTaxableTokenUniV4(payable(addr));
    }

    /// @dev A graduated, dividend-active token with 0.5 ETH buffered for holders.
    function _liveDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        token = _graduatedDividendToken();
        _accrue(token, 1 ether);
    }

    /// @dev The V4 graduator keeps a few thousand wei of the supply forever (measured: 7 328), and it
    ///      is an ordinary counted address, so a "sole holder" owns very slightly less than 100% of the
    ///      eligible supply and their accrual rounds down. Nothing is lost — it stays owed — but
    ///      exact-wei assertions have to allow for it.
    uint256 internal constant GRADUATOR_DUST_TOLERANCE = 1e9;

    /// @dev Pushes `amount` of native earnings through the allocation split, the same way the swap hook
    ///      and the LP-fee router do. Used instead of driving real swaps where the point of the test is
    ///      the dividend mechanics rather than the tax collection.
    function _accrue(LivoTaxableTokenUniV4 token, uint256 amount) internal {
        vm.deal(address(this), amount);
        token.accrueFees{value: amount}();
    }

    receive() external payable {}

    /// @dev Creates a taxable V4 token paying holders in a SET of assets, through the multi-allocation
    ///      `createToken` overload — the real creation path a frontend uses, not the token's initializer.
    function _createMultiAssetToken(address[] memory assets, uint16[] memory weights) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "MultiDiv",
            symbol: "MDIV",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
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
            earningsAllocation: EarningsAllocationMultiConfig({
                burnBps: 0,
                dividendsBps: 5_000,
                liquidityBps: 0,
                dividendTokens: assets,
                dividendWeightsBps: weights,
                dividendRoutes: new bytes[](0)
            })
        });
        vm.prank(creator);
        token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
    }

    /// @dev The product's own example: 20% of the dividends slice in one asset, 80% in another.
    function _nativeAndDaiToken() internal returns (LivoTaxableTokenUniV4 token) {
        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = DAI;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 2_000;
        weights[1] = 8_000;

        address addr = _createMultiAssetToken(assets, weights);
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return LivoTaxableTokenUniV4(payable(addr));
    }

    ///////////////////////// several payout assets /////////////////////////

    /// @dev The creation path stores the whole set, and the warm count is what the transfer hook reads.
    function test_multiAsset_creationStoresTheWholeSet() public {
        LivoTaxableTokenUniV4 token = _nativeAndDaiToken();

        assertEq(token.dividendAssetCount(), 2, "two payout assets");
        assertTrue(token.hasDividends(), "and the warm flag is on");
        (,,,,, address first,,,,) = token.dividendAssets(0);
        (,,,,, address second,,,,) = token.dividendAssets(1);
        assertEq(first, address(0), "asset 0 is native");
        assertEq(second, DAI, "asset 1 is DAI");
        assertEq(token.dividendWeightsBps(0), 2_000, "20% to the native leg");
        assertEq(token.dividendWeightsBps(1), 8_000, "80% to the DAI leg");
    }

    /// @dev Graduation activates EVERY asset at once, so no leg silently misses the seconds between
    ///      going live and its own first distribution.
    function test_multiAsset_graduationActivatesEveryAsset() public {
        LivoTaxableTokenUniV4 token = _nativeAndDaiToken();

        (, uint40 finish0,,,,,,,,) = token.dividendAssets(0);
        (, uint40 finish1,,,,,,,,) = token.dividendAssets(1);
        assertGt(finish0, 0, "asset 0 is live");
        assertEq(finish1, finish0, "and asset 1 went live in the same instant");
    }

    /// @dev End to end, through the real earnings split: one accrual, two buffers, two conversions, two
    ///      payouts, one holder.
    function test_multiAsset_earningsReachHoldersInBothAssets() public {
        LivoTaxableTokenUniV4 token = _nativeAndDaiToken();
        _accrue(token, 1 ether);

        (,,,,,,,, uint88 buffer0,) = token.dividendAssets(0);
        (,,,,,,,, uint88 buffer1,) = token.dividendAssets(1);
        assertEq(uint256(buffer0) * 4, uint256(buffer1), "the 20/80 split reached the buffers");

        token.processDividends(0, 0, _noHolders());
        token.processDividends(1, 0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 ethBefore = buyer.balance;
        vm.prank(buyer);
        token.claimDividends();

        assertGt(buyer.balance, ethBefore, "the holder was paid in native");
        assertGt(IERC20(DAI).balanceOf(buyer), 0, "and in DAI");
    }

    /// @dev The undelivered pot of EVERY asset has to stay out of every sweep path. `_reservedNative`
    ///      loops the set for exactly this reason: a buffer it forgot would be recycled through the
    ///      earnings split on every permissionless `sweepStrayEth`, handing holders' money to the
    ///      creator's fee receivers.
    function test_multiAsset_sweepStrayEthCannotReachAnyAssetBuffer() public {
        LivoTaxableTokenUniV4 token = _nativeAndDaiToken();
        _accrue(token, 1 ether);

        (,,,,,,,, uint88 buffer0,) = token.dividendAssets(0);
        (,,,,,,,, uint88 buffer1,) = token.dividendAssets(1);
        uint256 balanceBefore = address(token).balance;

        token.sweepStrayEth();

        assertEq(address(token).balance, balanceBefore, "nothing was stray, so nothing moved");
        (,,,,,,,, uint88 after0,) = token.dividendAssets(0);
        (,,,,,,,, uint88 after1,) = token.dividendAssets(1);
        assertEq(after0, buffer0, "asset 0's buffer is intact");
        assertEq(after1, buffer1, "asset 1's buffer is intact");
    }

    /// @dev `rescueTokens` subtracts `committedDividends`, which answers per asset. A pot bought for one
    ///      leg must be unreachable even though the token also pays in another.
    function test_multiAsset_rescueTokensCannotTakeAPayoutPot() public {
        LivoTaxableTokenUniV4 token = _nativeAndDaiToken();
        _accrue(token, 1 ether);
        token.processDividends(1, 0, _noHolders());

        uint256 pot = IERC20(DAI).balanceOf(address(token));
        assertGt(pot, 0, "precondition: a DAI pot exists");
        assertEq(token.committedDividends(DAI), pot, "and all of it is owed to holders");

        vm.prank(creator);
        token.rescueTokens(DAI);

        assertEq(IERC20(DAI).balanceOf(address(token)), pot, "the pot is untouched");
        assertEq(IERC20(DAI).balanceOf(creator), 0, "and the owner got nothing");
    }

    ///////////////////////// the keeper gate /////////////////////////

    /// @dev THE reason the gate exists. `processDividends` takes its slippage floor from the caller, so
    ///      a permissionless caller could manipulate the payout pool, call in with a zero floor and
    ///      unwind, atomically and risk-free. The cost of that round trip does not grow with how far the
    ///      price is pushed, so no cap or depth threshold bounds the fraction it takes — only this does.
    function test_processDividends_refusesANonKeeper() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();

        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, new address[](0));
    }

    /// @dev And an appointed keeper goes through, which is what makes the gate a gate rather than a wall.
    function test_processDividends_allowsAnAppointedKeeper() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        address keeper = makeAddr("appointedKeeper");
        vm.prank(admin);
        keepersRegistry.setKeeper(keeper, true);

        vm.prank(keeper);
        token.processDividends(0, new address[](0));

        assertGt(divRate(address(token), 0), 0, "the appointed keeper funded the stream");
    }

    /// @dev Revocation is immediate: a rotated-out key stops working in the next transaction.
    function test_processDividends_refusesARevokedKeeper() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        address keeper = makeAddr("rotatedKeeper");
        vm.startPrank(admin);
        keepersRegistry.setKeeper(keeper, true);
        keepersRegistry.setKeeper(keeper, false);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        token.processDividends(0, new address[](0));
    }

    /// @dev THE ESCAPE HATCH. A keeper set that goes away for good must not strand holders' money in the
    ///      buffer forever, so once the token is stale anyone may fund it. A buffer someone can convert
    ///      badly beats a buffer nobody can convert at all.
    function test_processDividends_goesPermissionlessOnceStale() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();

        skip(token.STALE_DIVIDEND_WINDOW() + 1);
        assertTrue(token.dividendsStale(0), "precondition: the token is stale");

        vm.prank(makeAddr("randomCaller"));
        token.processDividends(0, new address[](0));

        assertGt(divRate(address(token), 0), 0, "a stale token can be funded by anyone");
    }

    /// @dev The gate never stands between a holder and their own money. `claimDividends()` is open to
    ///      everyone, which is what makes keeper-gating the FUNDING leg acceptable at all.
    function test_claimDividends_staysOpenToNonKeepers() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, new address[](0));
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 owed = token.previewDividend(buyer);
        assertGt(owed, 0, "precondition: the holder has accrued");
        uint256 balanceBefore = buyer.balance;

        vm.prank(buyer);
        token.claimDividends();

        assertEq(buyer.balance - balanceBefore, owed, "a non-keeper holder was paid in full");
    }

    ///////////////////////// configuration /////////////////////////

    function test_dividendConfig_storedAtCreation() public {
        LivoTaxableTokenUniV4 token = LivoTaxableTokenUniV4(payable(_createDividendToken(5_000, address(0))));

        assertEq(token.dividendsBps(), 5_000, "dividendsBps stored");
        assertTrue(token.hasDividends(), "warm-slot gate flipped on");
        assertEq(token.dividendToken(), address(0), "paid in native");
        assertEq(token.dividendPeriodFinish(), 0, "the accumulator is dormant before graduation");
    }

    /// @dev The self-token sentinel exists because a creator cannot name an address that does not exist
    ///      yet; it must resolve to the token itself at initialization.
    function test_selfTokenSentinel_resolvesToTheToken() public {
        LivoTaxableTokenUniV4 token = LivoTaxableTokenUniV4(payable(_createDividendToken(5_000, token_SELF())));
        assertEq(token.dividendToken(), address(token), "sentinel resolved");
    }

    /// @dev An asset with no Uniswap V2 pair at all is refused at creation. A clone cannot be patched,
    ///      so the buffer would accrue forever behind it.
    function test_thirdAssetWithNoPairRejected() public {
        vm.expectRevert(abi.encodeWithSelector(LivoDividendSwapRegistry.RouteRejected.selector, SwapRejection.NoPair));
        _createDividendToken(5_000, makeAddr("xStock"));
    }

    /// @dev An asset the registry has blacklisted since is refused the same way. This is the ONE admin
    ///      veto in the path — and it applies to tokens that already exist, not just new ones.
    function test_blacklistedThirdAssetRejected() public {
        // Read the constant BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        vm.prank(admin);
        dividendSwapRegistry.setBlacklisted(DAI, true);

        vm.expectRevert(
            abi.encodeWithSelector(LivoDividendSwapRegistry.RouteRejected.selector, SwapRejection.Blacklisted)
        );
        _createDividendToken(5_000, DAI);
    }

    ///////////////////////// activation and funding /////////////////////////

    /// @dev The accumulator starts in `markGraduated()`, so a holder is earning from the moment the
    ///      token is live — not from whenever the first earnings happen to arrive.
    /// @dev The graduator still holds the WHOLE supply at that instant and moves it into the pool later
    ///      in the same transaction. Under the old round machinery that would have poisoned an opening
    ///      denominator; here there is none to poison, because no stream is running yet and eligible
    ///      supply is read live on every advance.
    function test_dividendsActivateAtGraduation() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        assertGt(token.dividendPeriodFinish(), 0, "activated by graduation itself");
        assertEq(divRate(address(token), 0), 0, "but nothing is streaming yet");
        assertEq(token.previewDividend(buyer), 0, "so nobody has accrued anything");
    }

    function test_accrual_bufferedAsNative() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        assertEq(token.pendingNative(), 0.5 ether, "half of the earnings buffered for holders");
    }

    function test_processDividends_revertsBelowThreshold() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        _accrue(token, 0.01 ether); // 0.005 ETH to dividends, well under the 0.1 ETH threshold
        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processDividends(0, _noHolders());
    }

    /// @dev Staleness is the only escape from the threshold, and V4 needs it: LP fees keep arriving
    ///      while the pool is live, so "the earnings source is finished" is never true here. Without it
    ///      a dead V4 token strands everything under `DIVIDEND_THRESHOLD` (0.1 ETH on mainnet), owed to
    ///      holders and unreachable by them.
    function test_staleTokenPaysItsSubThresholdResidual() public {
        LivoTaxableTokenUniV4 token = _graduatedDividendToken();
        _accrue(token, 0.01 ether); // 0.005 ETH to dividends, well under the threshold
        uint256 residual = token.pendingNative();
        assertGt(residual, 0, "a residual is buffered");

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        token.processDividends(0, _noHolders());

        // Nothing happens to the token for a month — no trades, no distributions.
        skip(token.STALE_DIVIDEND_WINDOW() + 1);
        token.processDividends(0, _noHolders());
        assertEq(token.dividendsOwed(), residual, "the stranded residual finally funded a stream");

        skip(token.DIVIDEND_DRIP_DURATION());
        uint256 before = buyer.balance;
        token.processDividends(0, _batch(buyer));
        assertApproxEqAbs(buyer.balance - before, residual, residual / 1000, "and reached the holder");
    }

    /// @dev A distribution landing while the previous one is still dripping must never revert. It folds
    ///      the undelivered remainder in and re-spreads the sum over a fresh window: the slope changes,
    ///      nothing is deferred, and no phase has to be waited out.
    function test_fundingMidStreamJustChangesTheSlope() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());
        uint256 firstRate = divRate(address(token), 0);

        skip(token.DIVIDEND_DRIP_DURATION() / 2);
        vm.roll(block.number + 1); // the funding leg is once per block
        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders()); // no revert, no wait

        assertEq(
            token.dividendPeriodFinish(),
            block.timestamp + token.DIVIDEND_DRIP_DURATION(),
            "a full fresh window from now"
        );
        assertApproxEqRel(divRate(address(token), 0), firstRate * 3 / 2, 1e14, "slope is (remainder + new) / duration");
        assertEq(token.dividendsOwed(), 1 ether, "and both distributions are owed in full");
    }

    ///////////////////////// the drip, and what it makes worthless /////////////////////////

    /// @dev THE property the design exists for: a balance that exists for zero seconds integrates to
    ///      zero. `holder2` receives half the float and gives it straight back in the same block, with a
    ///      distribution funded in between — and is owed nothing.
    function test_aZeroDurationBalanceEarnsNothing() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));
        uint256 half = erc.balanceOf(buyer) / 2;

        skip(token.DIVIDEND_DRIP_DURATION()); // real time on the clock before the attack

        vm.prank(buyer);
        erc.transfer(holder2, half); // "borrow"
        token.processDividends(0, _noHolders()); // fund, in the same block
        token.processDividends(0, _batch(holder2)); // and try to take it
        vm.prank(holder2);
        erc.transfer(buyer, half); // repay

        assertEq(holder2.balance, 0, "a zero-duration holder is paid nothing");
        assertEq(token.previewDividend(holder2), 0, "and is owed nothing");
    }

    /// @dev Accrual is `balance x time`. Two holders splitting the float evenly for the second half of a
    ///      stream split that half evenly, and the one who held through the first half keeps all of it.
    function test_accrualIsProportionalToBalanceAndTime() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));
        token.processDividends(0, _noHolders());
        uint256 pot = token.dividendsOwed();

        skip(token.DIVIDEND_DRIP_DURATION() / 2);
        // Read the balance BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        uint256 half = erc.balanceOf(buyer) / 2;
        vm.prank(buyer);
        erc.transfer(holder2, half);
        skip(token.DIVIDEND_DRIP_DURATION() / 2);

        assertApproxEqRel(token.previewDividend(holder2), pot / 4, 1e14, "half of the second half");
        assertApproxEqRel(token.previewDividend(buyer), pot * 3 / 4, 1e14, "the rest");
    }

    ///////////////////////// payout /////////////////////////

    function test_singleHolder_receivesTheWholeStream() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());
        assertApproxEqAbs(token.dividendsOwed(), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "the stream is funded");
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 balanceBefore = buyer.balance;
        token.processDividends(0, _batch(buyer));

        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "sole holder takes the whole stream"
        );
        assertLt(token.dividendsOwed(), GRADUATOR_DUST_TOLERANCE, "nothing meaningful left owed");
    }

    /// @dev A keeper's list is untrusted input: the same address twice must pay once, because the amount
    ///      is read from the holder's own accrual and zeroed on the first hit.
    function test_payingTwiceIsANoOp() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());

        address[] memory holders = new address[](2);
        holders[0] = buyer;
        holders[1] = buyer; // a duplicate in the keeper's list

        uint256 balanceBefore = buyer.balance;
        token.processDividends(0, holders);
        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "the duplicate pays nothing"
        );

        uint256 afterFirstBatch = buyer.balance;
        token.processDividends(0, holders);
        assertEq(buyer.balance, afterFirstBatch, "a second batch pays nothing either");
    }

    /// @dev A push-only call must not revert because the buffer happens to be short. This is what makes
    ///      `processDividends(0, holders)` usable as a plain `claimFor` on whatever cadence a keeper
    ///      likes, against whatever holder threshold it likes.
    function test_aPushOnlyCallWorksWithNothingToFund() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 before = buyer.balance;
        token.processDividends(0, _batch(buyer)); // buffer is empty: must still pay
        assertGt(buyer.balance, before, "the payout went out with nothing to fund");
    }

    /// @dev A holder the keeper never includes loses nothing at all: their accrual keeps compounding
    ///      across distributions until somebody pays them or they claim.
    function test_anOmittedHolderKeepsAccruing() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));
        // Read the balance BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        uint256 half = erc.balanceOf(buyer) / 2;
        vm.prank(buyer);
        erc.transfer(holder2, half);

        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());
        vm.roll(block.number + 1); // the funding leg is once per block
        token.processDividends(0, _batch(buyer)); // holder2 omitted

        _accrue(token, 1 ether);
        vm.roll(block.number + 1);
        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());
        vm.roll(block.number + 1);

        assertApproxEqRel(token.previewDividend(holder2), 0.5 ether, 1e14, "two streams' worth, still owed");
        token.processDividends(0, _batch(holder2));
        assertApproxEqRel(holder2.balance, 0.5 ether, 1e14, "and paid in full whenever the keeper gets to it");
    }

    function test_claimDividends_isABackstopForAMissedHolder() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());

        uint256 balanceBefore = buyer.balance;
        vm.prank(buyer);
        token.claimDividends();
        assertApproxEqAbs(
            buyer.balance - balanceBefore, 0.5 ether, GRADUATOR_DUST_TOLERANCE, "self-serve claim pays the same amount"
        );

        uint256 afterFirstClaim = buyer.balance;
        vm.prank(buyer);
        token.claimDividends();
        assertEq(buyer.balance, afterFirstClaim, "and only once");
    }

    ///////////////////////// committed funds (§2.9) /////////////////////////

    /// @dev `sweepStrayEth` is permissionless and repeatable. Reading the raw balance there would let
    ///      anyone recycle the dividend money through the split, handing the fund slice to the creator
    ///      on every call.
    function test_sweepStrayEth_cannotTouchTheDividendBuffer() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        uint256 buffered = token.pendingNative();

        token.sweepStrayEth();
        assertEq(token.pendingNative(), buffered, "buffer untouched by the sweep");

        // Stray ETH on top IS sweepable, and only that.
        vm.deal(address(token), address(token).balance + 0.3 ether);
        token.sweepStrayEth();
        assertEq(token.pendingNative(), buffered + 0.15 ether, "only the stray ETH was re-split");
    }

    function test_undeliveredDividendsSurviveASweep() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        token.processDividends(0, _noHolders());

        token.sweepStrayEth();
        assertApproxEqAbs(
            token.dividendsOwed(), 0.5 ether, GRADUATOR_DUST_TOLERANCE, "undelivered dividends are not stray ETH"
        );
        assertGe(address(token).balance, 0.5 ether, "and are still backed by a real balance");
    }

    ///////////////////////// the exclusion set /////////////////////////

    /// @dev The excluded set is written out TWICE in `LivoTaxableToken` — once as a predicate
    ///      (`_dividendExcluded`) and once as an arithmetic subtraction (`_dividendEligibleSupply`) — and
    ///      the two must name the same addresses. If they drift, the accumulator's denominator counts a
    ///      balance that can never be paid, and every stream under-distributes by that much, forever.
    /// @dev Asserted from outside via the only two things the pair is observable through: a zero
    ///      `previewDividend` per excluded address (the predicate), and the size of a real holder's
    ///      share of a fully-dripped stream (the subtraction).
    function test_theTwoExclusionListsAgree() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));

        address[4] memory excluded = [address(token), token.pair(), address(token.launchpad()), address(0xdEaD)];

        uint256 eligible = erc.totalSupply();
        for (uint256 i; i < excluded.length; ++i) {
            eligible -= erc.balanceOf(excluded[i]);
        }

        token.processDividends(0, _noHolders());
        uint256 pot = token.dividendsOwed();
        skip(token.DIVIDEND_DRIP_DURATION());

        for (uint256 i; i < excluded.length; ++i) {
            assertEq(token.previewDividend(excluded[i]), 0, "an excluded address must accrue nothing");
        }
        assertApproxEqRel(
            token.previewDividend(buyer),
            pot * erc.balanceOf(buyer) / eligible,
            1e14,
            "the denominator is exactly supply minus the balances of the SAME four addresses"
        );
    }

    /// @dev The graduator is deliberately NOT excluded — by the time any stream runs, graduation is over
    ///      and it holds only dust, whose accrual rounds to zero. Pinning that here so the decision (and
    ///      the per-transfer SLOAD it avoids) is not quietly reversed: given a real balance it earns like
    ///      any other address.
    function test_graduatorIsAnOrdinaryAddress_notExcluded() public {
        LivoTaxableTokenUniV4 token = _liveDividendToken();
        IERC20 erc = IERC20(address(token));
        address graduator = token.graduator();

        assertLt(erc.balanceOf(graduator), GRADUATOR_DUST_TOLERANCE, "what it holds is dust, which is why that is safe");

        // Read the balance BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        uint256 half = erc.balanceOf(buyer) / 2;
        vm.prank(buyer);
        erc.transfer(graduator, half);

        token.processDividends(0, _noHolders());
        skip(token.DIVIDEND_DRIP_DURATION());
        assertGt(token.previewDividend(graduator), 0, "with a real balance it accrues like any holder");
    }

    ///////////////////////// the self-token leg /////////////////////////

    /// @dev A graduated token paying its holders in ITSELF. On V4 this is the only leg that runs a swap:
    ///      earnings arrive as ETH and `_acquireDividendAsset` buys the token back on its own pool,
    ///      reusing the primitive `processBurn` uses.
    function _graduatedSelfTokenDividendToken() internal returns (LivoTaxableTokenUniV4 token) {
        address addr = _createDividendToken(5_000, token_SELF());
        testToken = addr;
        _launchpadBuy(addr, 2 ether);
        _graduateToken();
        return LivoTaxableTokenUniV4(payable(addr));
    }

    /// @dev The whole V4 self-token path end to end: accrue ETH, buy the token back on its own pool
    ///      when the stream is funded, and pay holders in tokens. Nothing else exercises
    ///      `_acquireDividendAsset`'s V4 override, so without this the leg is configurable but never
    ///      executed.
    function test_selfTokenLeg_boughtBackOnFundingAndPaidInTokens() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);
        assertEq(token.pendingNative(), 0.5 ether, "the self-token leg buffers as ETH on V4");

        uint256 holderBefore = IERC20(address(token)).balanceOf(buyer);
        token.processDividends(0, _noHolders());

        uint256 pot = token.dividendsOwed();
        assertGt(pot, 0, "ETH was converted into the token itself");
        assertEq(token.dividendToken(), address(token), "the stream is denominated in the token");
        // A self-token leg swaps, so one call converts at most `MAX_DIVIDEND_PER_CONVERSION`. What is
        // left is the uncapped remainder plus the buy-back's own tax, which loops back in as fresh
        // earnings.
        assertApproxEqAbs(
            token.pendingNative(),
            0.5 ether - token.MAX_DIVIDEND_PER_CONVERSION(),
            0.01 ether,
            "the conversion took the cap, the remainder stayed buffered"
        );

        skip(token.DIVIDEND_DRIP_DURATION());
        address[] memory holders = new address[](1);
        holders[0] = buyer;
        token.processDividends(0, holders);

        assertGt(IERC20(address(token)).balanceOf(buyer), holderBefore, "the holder was paid in tokens");
        assertApproxEqAbs(
            IERC20(address(token)).balanceOf(buyer) - holderBefore,
            pot,
            GRADUATOR_DUST_TOLERANCE,
            "paid the whole stream"
        );
    }

    /// @dev The buy-back is an ordinary pool swap, so `LivoSwapHook` emits a `LivoSwapBuy` crediting
    ///      `tx.origin` — the keeper. `DividendBuyBackInitiated` must land BEFORE it so an indexer can
    ///      classify that buy as protocol-internal as it arrives, rather than as a trade by the keeper.
    function test_selfTokenBuyBack_isFlaggedBeforeTheSwap() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);

        vm.recordLogs();
        token.processDividends(0, _noHolders());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 marker = keccak256("DividendBuyBackInitiated(uint256)");
        bytes32 swapBuy = keccak256("LivoSwapBuy(address,address,uint256,uint256,uint256)");
        uint256 markerAt = type(uint256).max;
        uint256 swapAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == marker && markerAt == type(uint256).max) markerAt = i;
            if (logs[i].topics[0] == swapBuy && swapAt == type(uint256).max) swapAt = i;
        }

        assertLt(markerAt, type(uint256).max, "the precursor marker was emitted");
        assertLt(swapAt, type(uint256).max, "the hook's buy event was emitted");
        assertLt(markerAt, swapAt, "the marker must precede the swap it flags");
    }

    /// @dev Native the router sweeps back on a partial fill must stay on the DIVIDEND ledger. The base
    ///      debits `pendingNative` by the full amount it offered, so without the credit-back the unspent
    ///      remainder becomes stray and `sweepStrayEth` re-splits holders' money into the burn, liquidity
    ///      and fund buckets. Measured against stray native rather than the raw balance because a
    ///      buy-back is a swap: the hook's `accrueFees` can land native here mid-call.
    function test_selfTokenBuyBack_unspentEthStaysEarmarked() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);

        uint256 pending = token.pendingNative();
        assertGt(pending, 0, "the self-token leg buffered ETH");
        uint256 cap = token.MAX_DIVIDEND_PER_CONVERSION();
        uint256 spend = pending < cap ? pending : cap;

        // The stub delivers a fixed amount of the token, so it needs a balance at the router's address.
        address router = token.UNIV4_UNIVERSAL_ROUTER();
        deal(address(token), router, 1e18);
        vm.etch(router, type(PartialFillRouterStub).runtimeCode);

        token.processDividends(0, _noHolders());

        assertEq(token.pendingNative(), pending - spend / 2, "only the half the pool took left the buffer");
    }

    /// @dev Undelivered self-token dividends are the token's OWN balance, shared with the tax pool. They
    ///      must be invisible to the swap-back accounting, or holders' money would be re-processed as tax.
    function test_selfTokenDividends_areNotSweepableAsStray() public {
        LivoTaxableTokenUniV4 token = _graduatedSelfTokenDividendToken();
        _accrue(token, 1 ether);
        token.processDividends(0, _noHolders());

        uint256 pot = token.dividendsOwed();
        assertEq(token.committedDividends(address(token)), pot, "the balance is reported as committed");

        // A rescue must not be able to reach it either: it is holders' money, not a stuck balance.
        vm.prank(creator);
        vm.expectRevert(LivoTaxableToken.CannotRescueSelfToken.selector);
        token.rescueTokens(address(token));
    }

    /// @dev Helper: the "pay me in the token itself" sentinel.
    function token_SELF() internal pure returns (address) {
        return address(type(uint160).max);
    }
}
