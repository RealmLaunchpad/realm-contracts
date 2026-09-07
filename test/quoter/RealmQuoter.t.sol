// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {RealmQuoter} from "src/RealmQuoter.sol";
import {IRealmQuoter2} from "src/interfaces/IRealmQuoter2.sol";
import {LimitReason} from "src/interfaces/IRealmQuoter.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {SniperProtection, AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Quoter test suite. Every consistency test follows the same shape:
///         1) ask the quoter for a quote,
///         2) broadcast the corresponding launchpad call using the quote's outputs (with the
///            quote's expected output as `minTokens`/`minEth` so any under-quote auto-reverts),
///         3) assert the actual on-chain balance changes match the quote field-by-field.
///         If a quote is wrong (or trips a cap), one of those assertions / the launchpad's
///         slippage check fails — guaranteeing the quoter's outputs are *executable* and
///         *accurate*, not merely non-reverting.
contract RealmQuoterTest is LaunchpadBaseTestsWithUniv4Graduator {
    RealmQuoter internal quoter;

    address internal sniperToken;
    address internal baseToken;

    function _sniperCfg() internal pure returns (AntiSniperConfigs memory) {
        return AntiSniperConfigs({
            maxBuyPerTxBps: 300, maxWalletBps: 300, protectionWindowSeconds: 3 hours, whitelist: new address[](0)
        });
    }

    function _sniperCfgWithWhitelist(address w) internal pure returns (AntiSniperConfigs memory cfg) {
        address[] memory wl = new address[](1);
        wl[0] = w;
        cfg = AntiSniperConfigs({
            maxBuyPerTxBps: 300, maxWalletBps: 300, protectionWindowSeconds: 3 hours, whitelist: wl
        });
    }

    function setUp() public override {
        super.setUp();
        quoter = new RealmQuoter(address(launchpad));

        vm.prank(creator);
        sniperToken = factorySniper.createToken(
            "SNIPER",
            "SNIPER",
            _nextValidSalt(address(factorySniper), address(realmTokenSniper)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _sniperCfg()
        );

        vm.prank(creator);
        baseToken = factoryV4.createToken(
            "BASE",
            "BASE",
            _nextValidSalt(address(factoryV4), address(realmToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
    }

    /////////////////////////////// REASON-CODE TESTS (no execution) ///////////////////////////////

    function test_reason_INVALID_TOKEN() public {
        address fake = makeAddr("fake");
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(fake, buyer, 1 ether);
        assertEq(uint256(q.reason), uint256(LimitReason.INVALID_TOKEN));
        assertEq(q.ethSpent, 0);

        (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(fake, buyer);
        assertEq(maxEth, 0);
        assertEq(uint256(reason), uint256(LimitReason.INVALID_TOKEN));
    }

    function test_reason_GRADUATED() public {
        _graduateBaseToken();
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(baseToken, buyer, 1 ether);
        assertEq(uint256(q.reason), uint256(LimitReason.GRADUATED));
        assertEq(q.ethSpent, 0);

        (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(baseToken, buyer);
        assertEq(maxEth, 0);
        assertEq(uint256(reason), uint256(LimitReason.GRADUATED));
    }

    function test_reason_SNIPER_CAP_oversizedBuy_reasonOnly() public view {
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(sniperToken, buyer, 0.2 ether);
        assertEq(uint256(q.reason), uint256(LimitReason.SNIPER_CAP));
        assertLt(q.ethSpent, 0.2 ether);
    }

    function test_reason_GRADUATION_EXCESS_baseToken_reasonOnly() public {
        _launchpadBuy(baseToken, _increaseWithFees(GRADUATION_THRESHOLD - 0.01 ether));
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(baseToken, buyer, 0.5 ether);
        assertEq(uint256(q.reason), uint256(LimitReason.GRADUATION_EXCESS));
        assertEq(q.ethSpent, launchpad.getMaxEthToSpend(baseToken));
    }

    /////////////////////////////// CONSISTENCY: quoteBuyTokensWithExactEth → buy ///////////////////////////////

    function test_consistency_buyExactEth_NONE_baseToken() public {
        _quoteAndBuyExactEth(baseToken, buyer, 0.05 ether, LimitReason.NONE);
    }

    function test_consistency_buyExactEth_NONE_sniperSmall() public {
        _quoteAndBuyExactEth(sniperToken, buyer, 0.01 ether, LimitReason.NONE);
    }

    function test_consistency_buyExactEth_NONE_windowExpired() public {
        SniperProtection sp = SniperProtection(sniperToken);
        vm.warp(uint256(RealmToken(address(sp)).launchTimestamp()) + uint256(sp.protectionWindowSeconds()) + 1);
        _quoteAndBuyExactEth(sniperToken, buyer, 0.5 ether, LimitReason.NONE);
    }

    function test_consistency_buyExactEth_NONE_whitelistedBuyer() public {
        vm.prank(creator);
        address wlToken = factorySniper.createToken(
            "WL",
            "WL",
            _nextValidSalt(address(factorySniper), address(realmTokenSniper)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _sniperCfgWithWhitelist(buyer)
        );
        _quoteAndBuyExactEth(wlToken, buyer, 0.5 ether, LimitReason.NONE);
    }

    function test_consistency_buyExactEth_GRADUATION_EXCESS() public {
        _launchpadBuy(baseToken, _increaseWithFees(GRADUATION_THRESHOLD - 0.005 ether));
        _quoteAndBuyExactEth(baseToken, buyer, 0.5 ether, LimitReason.GRADUATION_EXCESS);
    }

    function test_consistency_buyExactEth_SNIPER_CAP_perTxBinding() public {
        _quoteAndBuyExactEth(sniperToken, buyer, 0.2 ether, LimitReason.SNIPER_CAP);
    }

    function test_consistency_buyExactEth_SNIPER_CAP_walletBinding() public {
        // First buy fills the buyer's wallet to nearly the cap.
        _quoteAndBuyExactEth(sniperToken, buyer, 0.06 ether, LimitReason.NONE);
        // Second buy is clamped by the *wallet* portion of the sniper cap.
        _quoteAndBuyExactEth(sniperToken, buyer, 0.06 ether, LimitReason.SNIPER_CAP);
    }

    /////////////////////////////// CONSISTENCY: quoteBuyExactTokens → buy ///////////////////////////////

    function test_consistency_buyExactTokens_NONE_baseToken() public {
        _quoteAndBuyExactTokens(baseToken, buyer, 5_000_000e18, LimitReason.NONE);
    }

    function test_consistency_buyExactTokens_NONE_sniperSmall() public {
        _quoteAndBuyExactTokens(sniperToken, buyer, 1_000_000e18, LimitReason.NONE);
    }

    function test_consistency_buyExactTokens_SNIPER_CAP() public {
        // 50M tokens > 3% sniper cap (30M) → clamps to sniper cap.
        _quoteAndBuyExactTokens(sniperToken, buyer, 50_000_000e18, LimitReason.SNIPER_CAP);
    }

    function test_consistency_buyExactTokens_GRADUATION_EXCESS() public {
        _launchpadBuy(baseToken, _increaseWithFees(GRADUATION_THRESHOLD - 0.005 ether));
        // Asking for more tokens than fit before graduation.
        _quoteAndBuyExactTokens(baseToken, buyer, 100_000_000e18, LimitReason.GRADUATION_EXCESS);
    }

    /////////////////////////////// CONSISTENCY: quoteSellExactTokens → sell ///////////////////////////////

    function test_consistency_sellExactTokens_NONE_partial() public {
        _launchpadBuy(baseToken, 1 ether);
        uint256 toSell = IERC20(baseToken).balanceOf(buyer) / 3;
        _quoteAndSellExactTokens(baseToken, buyer, toSell, LimitReason.NONE);
    }

    function test_consistency_sellExactTokens_NONE_full() public {
        _launchpadBuy(baseToken, 0.5 ether);
        uint256 toSell = IERC20(baseToken).balanceOf(buyer);
        _quoteAndSellExactTokens(baseToken, buyer, toSell, LimitReason.NONE);
    }

    /////////////////////////////// CONSISTENCY: quoteSellTokensForExactEth → sell ///////////////////////////////

    function test_consistency_sellForExactEth_NONE() public {
        _launchpadBuy(baseToken, 1 ether);
        // Target half the post-fee ETH the seller could redeem.
        uint256 ethTarget = (launchpad.getTokenState(baseToken).ethCollected) / 4;
        _quoteAndSellForExactEth(baseToken, buyer, ethTarget, LimitReason.NONE);
    }

    /////////////////////////////// CONSISTENCY: getMaxEthToSpend → buy ///////////////////////////////

    function test_consistency_getMaxEthToSpend_freshBaseToken() public {
        (uint256 maxEth,) = quoter.getMaxEthToSpend(baseToken, buyer);
        _quoteAndBuyExactEth(baseToken, buyer, maxEth, LimitReason.NONE);
    }

    function test_consistency_getMaxEthToSpend_freshSniperToken() public {
        (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(sniperToken, buyer);
        assertEq(uint256(reason), uint256(LimitReason.SNIPER_CAP));
        // Spending exactly maxEth on the sniper token is within the cap → quoter returns NONE.
        _quoteAndBuyExactEth(sniperToken, buyer, maxEth, LimitReason.NONE);
    }

    function test_consistency_getMaxEthToSpend_nearGraduation() public {
        _launchpadBuy(baseToken, _increaseWithFees(GRADUATION_THRESHOLD - 0.005 ether));
        (uint256 maxEth,) = quoter.getMaxEthToSpend(baseToken, buyer);
        if (maxEth > 0) _quoteAndBuyExactEth(baseToken, buyer, maxEth, LimitReason.NONE);
    }

    function test_consistency_getMaxEthToSpend_walletPartiallyFilled() public {
        _launchpadBuy(sniperToken, 0.04 ether);
        (uint256 maxEth,) = quoter.getMaxEthToSpend(sniperToken, buyer);
        _quoteAndBuyExactEth(sniperToken, buyer, maxEth, LimitReason.NONE);
    }

    function test_consistency_getMaxEthToSpend_windowExpired() public {
        SniperProtection sp = SniperProtection(sniperToken);
        vm.warp(uint256(RealmToken(address(sp)).launchTimestamp()) + uint256(sp.protectionWindowSeconds()) + 1);
        (uint256 maxEth, LimitReason reason) = quoter.getMaxEthToSpend(sniperToken, buyer);
        assertEq(uint256(reason), uint256(LimitReason.GRADUATION_EXCESS));
        _quoteAndBuyExactEth(sniperToken, buyer, maxEth, LimitReason.NONE);
    }

    /////////////////////////////// CONSISTENCY: fuzz ///////////////////////////////

    /// @notice Fuzz: any ETH input → quoter buy → matches actual on-chain trade exactly.
    function testFuzz_consistency_buyExactEth_sniper(uint96 ethInput) public {
        ethInput = uint96(bound(uint256(ethInput), 1, 5 ether));
        _quoteAndBuyExactEth_skipReason(sniperToken, buyer, ethInput);
    }

    /// @notice Fuzz: any token input → quoter buy → matches actual on-chain trade exactly.
    function testFuzz_consistency_buyExactTokens_sniper(uint96 tokenInput) public {
        uint256 amount = bound(uint256(tokenInput), 1e15, 100_000_000e18);
        _quoteAndBuyExactTokens_skipReason(sniperToken, buyer, amount);
    }

    /// @notice Fuzz: any token input on a base token → consistency holds for graduation excess too.
    function testFuzz_consistency_buyExactEth_baseNearGraduation(uint96 ethInput) public {
        // Top up so the curve is in its last 0.05 ETH of room.
        _launchpadBuy(baseToken, _increaseWithFees(GRADUATION_THRESHOLD - 0.02 ether));
        ethInput = uint96(bound(uint256(ethInput), 1, 1 ether));
        _quoteAndBuyExactEth_skipReason(baseToken, buyer, ethInput);
    }

    /// @notice Fuzz: any token input → quoter sell → matches actual on-chain trade exactly.
    function testFuzz_consistency_sellExactTokens(uint96 sellInput) public {
        _launchpadBuy(baseToken, 1.5 ether);
        uint256 held = IERC20(baseToken).balanceOf(buyer);
        uint256 toSell = bound(uint256(sellInput), 1e12, held);
        _quoteAndSellExactTokens_skipReason(baseToken, buyer, toSell);
    }

    /////////////////////////////// HELPERS ///////////////////////////////

    /// @dev Quote a buy-exact-eth, broadcast it, and assert every quote field matches reality.
    function _quoteAndBuyExactEth(address token, address buyer_, uint256 ethInput, LimitReason expectedReason)
        internal
    {
        _quoteAndBuyExactEth_inner(token, buyer_, ethInput, expectedReason, true);
    }

    /// @dev Same as `_quoteAndBuyExactEth` but skips the reason assertion (for fuzz tests where
    ///      the reason depends on the random input).
    function _quoteAndBuyExactEth_skipReason(address token, address buyer_, uint256 ethInput) internal {
        _quoteAndBuyExactEth_inner(token, buyer_, ethInput, LimitReason.NONE, false);
    }

    function _quoteAndBuyExactEth_inner(
        address token,
        address buyer_,
        uint256 ethInput,
        LimitReason expectedReason,
        bool checkReason
    ) internal {
        IRealmQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(token, buyer_, ethInput);

        if (checkReason) assertEq(uint256(q.reason), uint256(expectedReason), "wrong reason");
        if (q.reason == LimitReason.INVALID_TOKEN || q.reason == LimitReason.GRADUATED || q.ethSpent == 0) return;

        // Snapshot the sniper cap *before* the buy. After the buy the buyer's balance changes and
        // the cap can shrink to zero (when the wallet cap was binding), making a post-buy read
        // useless for this assertion.
        uint256 sniperCapBefore = RealmToken(token).maxTokenPurchase(buyer_);

        uint256 buyerEthBefore = buyer_.balance;
        uint256 buyerTokensBefore = IERC20(token).balanceOf(buyer_);
        uint256 treasuryEthBefore = treasury.balance;

        vm.deal(buyer_, buyerEthBefore + q.ethSpent);
        vm.prank(buyer_);
        // `minTokens = q.tokensToReceive` is the strongest slippage check: if the actual trade
        // yields fewer than quoted, the launchpad reverts with `SlippageExceeded`. The equality
        // assertion below catches over-quoting.
        uint256 actualTokens = launchpad.buyTokensWithExactEth{value: q.ethSpent}(token, q.tokensToReceive, DEADLINE);

        assertEq(actualTokens, q.tokensToReceive, "actual tokens != quoted");
        assertEq(IERC20(token).balanceOf(buyer_) - buyerTokensBefore, q.tokensToReceive, "token balance delta");
        assertEq(buyerEthBefore + q.ethSpent - buyer_.balance, q.ethSpent, "buyer ETH delta");
        _assertTreasuryFeeDelta(token, treasuryEthBefore, q.ethFee);

        // The quote's graduation flag must match what actually happened on-chain.
        assertEq(launchpad.getTokenState(token).graduated, q.canGraduate, "canGraduate mismatch (exact-eth)");

        if (q.reason == LimitReason.SNIPER_CAP) assertLe(actualTokens, sniperCapBefore, "sniper cap exceeded");
    }

    /// @dev Quote a buy-exact-tokens, broadcast it, and assert quote fields match reality.
    function _quoteAndBuyExactTokens(address token, address buyer_, uint256 tokenInput, LimitReason expectedReason)
        internal
    {
        _quoteAndBuyExactTokens_inner(token, buyer_, tokenInput, expectedReason, true);
    }

    function _quoteAndBuyExactTokens_skipReason(address token, address buyer_, uint256 tokenInput) internal {
        _quoteAndBuyExactTokens_inner(token, buyer_, tokenInput, LimitReason.NONE, false);
    }

    function _quoteAndBuyExactTokens_inner(
        address token,
        address buyer_,
        uint256 tokenInput,
        LimitReason expectedReason,
        bool checkReason
    ) internal {
        IRealmQuoter2.BuyExactTokensQuote memory q = quoter.quoteBuyExactTokens(token, buyer_, tokenInput);

        if (checkReason) assertEq(uint256(q.reason), uint256(expectedReason), "wrong reason");
        if (q.reason == LimitReason.INVALID_TOKEN || q.reason == LimitReason.GRADUATED || q.totalEthNeeded == 0) {
            return;
        }

        uint256 sniperCapBefore = RealmToken(token).maxTokenPurchase(buyer_);

        uint256 buyerEthBefore = buyer_.balance;
        uint256 buyerTokensBefore = IERC20(token).balanceOf(buyer_);
        uint256 treasuryEthBefore = treasury.balance;

        vm.deal(buyer_, buyerEthBefore + q.totalEthNeeded);
        vm.prank(buyer_);
        uint256 actualTokens =
            launchpad.buyTokensWithExactEth{value: q.totalEthNeeded}(token, q.tokensReceived, DEADLINE);

        assertEq(actualTokens, q.tokensReceived, "actual tokens != quoted (exact-tokens)");
        assertEq(
            IERC20(token).balanceOf(buyer_) - buyerTokensBefore, q.tokensReceived, "token balance delta (exact-tokens)"
        );
        assertEq(buyerEthBefore + q.totalEthNeeded - buyer_.balance, q.totalEthNeeded, "buyer ETH delta");
        _assertTreasuryFeeDelta(token, treasuryEthBefore, q.ethFee);

        // The quote's graduation flag must match what actually happened on-chain.
        assertEq(launchpad.getTokenState(token).graduated, q.canGraduate, "canGraduate mismatch (exact-tokens)");

        if (q.reason == LimitReason.SNIPER_CAP) assertLe(actualTokens, sniperCapBefore, "sniper cap exceeded");
    }

    /// @dev Quote a sell-exact-tokens, broadcast it, and assert quote fields match reality.
    function _quoteAndSellExactTokens(address token, address buyer_, uint256 tokenAmount, LimitReason expectedReason)
        internal
    {
        _quoteAndSellExactTokens_inner(token, buyer_, tokenAmount, expectedReason, true);
    }

    function _quoteAndSellExactTokens_skipReason(address token, address buyer_, uint256 tokenAmount) internal {
        _quoteAndSellExactTokens_inner(token, buyer_, tokenAmount, LimitReason.NONE, false);
    }

    function _quoteAndSellExactTokens_inner(
        address token,
        address buyer_,
        uint256 tokenAmount,
        LimitReason expectedReason,
        bool checkReason
    ) internal {
        IRealmQuoter2.SellExactTokensQuote memory q = quoter.quoteSellExactTokens(token, tokenAmount);

        if (checkReason) assertEq(uint256(q.reason), uint256(expectedReason), "wrong reason");
        if (q.reason == LimitReason.INVALID_TOKEN || q.reason == LimitReason.GRADUATED || q.tokensSold == 0) return;

        uint256 buyerEthBefore = buyer_.balance;
        uint256 buyerTokensBefore = IERC20(token).balanceOf(buyer_);
        uint256 treasuryEthBefore = treasury.balance;

        vm.prank(buyer_);
        uint256 actualEth = launchpad.sellExactTokens(token, q.tokensSold, q.ethForSeller, DEADLINE);

        assertEq(actualEth, q.ethForSeller, "actual ETH != quoted (sell-exact-tokens)");
        assertEq(buyer_.balance - buyerEthBefore, q.ethForSeller, "seller ETH delta");
        assertEq(buyerTokensBefore - IERC20(token).balanceOf(buyer_), q.tokensSold, "token balance delta");
        _assertTreasuryFeeDelta(token, treasuryEthBefore, q.ethFee);
    }

    /// @dev Quote a sell-for-exact-eth, broadcast `sellExactTokens` with `q.tokensRequired`, and
    ///      assert quote fields match reality.
    function _quoteAndSellForExactEth(address token, address buyer_, uint256 ethTarget, LimitReason expectedReason)
        internal
    {
        IRealmQuoter2.SellForExactEthQuote memory q = quoter.quoteSellTokensForExactEth(token, ethTarget);

        assertEq(uint256(q.reason), uint256(expectedReason), "wrong reason");
        if (q.reason == LimitReason.INVALID_TOKEN || q.reason == LimitReason.GRADUATED || q.tokensRequired == 0) {
            return;
        }

        uint256 buyerEthBefore = buyer_.balance;
        uint256 buyerTokensBefore = IERC20(token).balanceOf(buyer_);
        uint256 treasuryEthBefore = treasury.balance;

        vm.prank(buyer_);
        uint256 actualEth = launchpad.sellExactTokens(token, q.tokensRequired, q.ethReceived, DEADLINE);

        assertEq(actualEth, q.ethReceived, "actual ETH != quoted (sell-for-exact-eth)");
        assertEq(buyer_.balance - buyerEthBefore, q.ethReceived, "seller ETH delta");
        assertEq(buyerTokensBefore - IERC20(token).balanceOf(buyer_), q.tokensRequired, "token balance delta");
        _assertTreasuryFeeDelta(token, treasuryEthBefore, q.ethFee);
    }

    /// @dev Treasury fee assertion that tolerates graduation triggering. The launchpad now splits the
    ///      LP fee between treasury and creator, so the treasury only receives `treasuryShareBps` of
    ///      the quoted fee (these tokens are non-tax, so `q.ethFee` is entirely LP fee). When a buy
    ///      crosses the graduation threshold, the launchpad also pays the graduator's treasury fee
    ///      (~0.20 ETH for V4), so we accept any delta ≥ the treasury's trading-fee share post-graduation.
    function _assertTreasuryFeeDelta(address token, uint256 treasuryBefore, uint256 quotedFee) internal view {
        uint256 delta = treasury.balance - treasuryBefore;
        uint256 expectedTreasuryShare = quotedFee * RealmToken(token).treasuryShareBps() / 10_000;
        if (launchpad.getTokenState(token).graduated) {
            assertGe(delta, expectedTreasuryShare, "treasury fee delta below quoted (graduated)");
        } else {
            assertEq(delta, expectedTreasuryShare, "treasury fee delta");
        }
    }

    function _graduateBaseToken() internal {
        uint256 ethReserves = launchpad.getTokenState(baseToken).ethCollected;
        uint256 missingEth = GRADUATION_THRESHOLD - ethReserves;
        _launchpadBuy(baseToken, _increaseWithFees(missingEth));
    }
}
