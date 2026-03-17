// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice PoC tests for hook-based LP fees (1% charged by LivoSwapHook, split 50/50 creator/treasury)
contract LivoSwapHookLpFeesTests is TaxTokenUniV4BaseTests {
    function setUp() public override {
        super.setUp();
    }

    function _pendingCreatorFees(address token) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return ILivoFeeHandler(ILivoToken(token).feeHandler()).getClaimable(tokens, creator)[0];
    }

    /// @notice Buy charges 1% LP fee: 0.5% to creator (via fee handler), 0.5% to treasury (direct)
    function test_buyChargesLpFee_splitCreatorTreasury() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesAfter = _pendingCreatorFees(testToken);
        uint256 treasuryAfter = treasury.balance;

        uint256 creatorLpFee = creatorFeesAfter - creatorFeesBefore;
        uint256 treasuryLpFee = treasuryAfter - treasuryBefore;

        // Each should be ~0.5% of buy amount
        assertApproxEqAbs(creatorLpFee, buyAmount / 200, 1, "Creator should receive ~0.5% LP fee on buy");
        assertApproxEqAbs(treasuryLpFee, buyAmount / 200, 1, "Treasury should receive ~0.5% LP fee on buy");
        assertApproxEqAbs(creatorLpFee + treasuryLpFee, buyAmount / 100, 1, "Total LP fee should be ~1%");
    }

    /// @notice Sell charges 1% LP fee (split 50/50)
    function test_sellChargesLpFee() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // Warp past tax period so only LP fee applies
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;

        // LP fee is 1% of gross ETH output; gross = ethReceived + totalLpFee
        uint256 grossEth = ethReceived + totalLpFee;
        uint256 expectedLpFee = grossEth / 100;

        assertApproxEqAbs(totalLpFee, expectedLpFee, 2, "Total LP fee should be ~1% of gross ETH");
        assertApproxEqAbs(creatorLpFee, treasuryLpFee, 1, "Creator and treasury shares should be ~equal");
    }

    /// @notice Sell stacks LP fee + sell tax during active tax period
    function test_sellStacksLpFeeAndSellTax() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorFeesAccrued = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        // Creator fees = LP fee share (0.5%) + sell tax (5%), all deposited via accrueFees
        // Treasury gets only LP fee share (0.5%)
        // Gross ETH = ethReceived + creatorFeesAccrued + treasuryLpFee
        uint256 grossEth = ethReceived + creatorFeesAccrued + treasuryLpFee;

        uint256 expectedTreasuryLpFee = grossEth / 200; // 0.5%
        uint256 expectedCreatorLpFee = grossEth / 200; // 0.5%
        uint256 expectedSellTax = (grossEth * DEFAULT_SELL_TAX_BPS) / 10000; // 5%

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 2, "Treasury should get ~0.5% LP fee");
        assertApproxEqAbs(
            creatorFeesAccrued,
            expectedCreatorLpFee + expectedSellTax,
            2,
            "Creator should get ~0.5% LP fee + ~5% sell tax"
        );
    }

    /// @notice After tax period expires, only LP fee remains (no sell tax)
    function test_onlyLpFeeAfterTaxExpires() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // Warp past tax period
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;
        uint256 grossEth = ethReceived + totalLpFee;

        // No sell tax, only LP fee
        assertApproxEqAbs(totalLpFee, grossEth / 100, 2, "Only LP fee (~1%) should be charged after tax expires");
        assertApproxEqAbs(creatorLpFee, treasuryLpFee, 1, "LP fee split should be ~50/50");
    }

    /// @notice Swaps revert before graduation
    function test_noFeesBeforeGraduation() public createDefaultTaxToken {
        deal(buyer, 1 ether);
        // Swap should revert because token hasn't graduated
        _swapBuy(buyer, 1 ether, 0, false);
    }

    /// @notice Buy charges LP fee (50/50 split) + buy tax (100% creator) during active tax period
    function test_buyChargesBuyTaxAndLpFee() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesAccrued = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        // LP fee = 1% of buyAmount, split 50/50
        // Buy tax = 3% of buyAmount, 100% to creator
        uint256 expectedTreasuryLpFee = buyAmount / 200; // 0.5%
        uint256 expectedCreatorLpFee = buyAmount / 200; // 0.5%
        uint256 expectedBuyTax = (buyAmount * buyTax) / 10000; // 3%

        assertApproxEqAbs(treasuryLpFee, expectedTreasuryLpFee, 1, "Treasury should get ~0.5% LP fee");
        assertApproxEqAbs(
            creatorFeesAccrued,
            expectedCreatorLpFee + expectedBuyTax,
            1,
            "Creator should get ~0.5% LP fee + ~3% buy tax"
        );
    }

    /// @notice After tax period expires, buy only charges LP fee (no buy tax)
    function test_buyOnlyLpFeeAfterTaxExpires() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        // Warp past tax period
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;
        uint256 totalLpFee = creatorLpFee + treasuryLpFee;

        // Only LP fee, no buy tax
        assertApproxEqAbs(totalLpFee, buyAmount / 100, 1, "Only LP fee (~1%) should be charged after tax expires");
        assertApproxEqAbs(creatorLpFee, treasuryLpFee, 1, "LP fee split should be ~50/50");
    }

    /// @notice Both buy and sell are taxed during active tax period
    function test_buyAndSellBothTaxed() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);

        // Buy on bonding curve first so buyer has tokens
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // --- Buy ---
        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 0.5 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorFeesFromBuy = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryFromBuy = treasury.balance - treasuryBefore;

        // Buy should have LP fee + buy tax
        uint256 expectedBuyTax = (buyAmount * buyTax) / 10000;
        assertGt(creatorFeesFromBuy, treasuryFromBuy, "Creator should get more than treasury on taxed buy");
        assertApproxEqAbs(creatorFeesFromBuy - treasuryFromBuy, expectedBuyTax, 1, "Difference should be ~buy tax");

        // --- Sell ---
        creatorFeesBefore = _pendingCreatorFees(testToken);
        treasuryBefore = treasury.balance;
        uint256 buyerEthBefore = buyer.balance;

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 4;
        _swapSell(buyer, sellAmount, 0, true);

        uint256 ethReceived = buyer.balance - buyerEthBefore;
        uint256 creatorFeesFromSell = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryFromSell = treasury.balance - treasuryBefore;

        // Sell should have LP fee + sell tax
        uint256 grossEth = ethReceived + creatorFeesFromSell + treasuryFromSell;
        uint256 expectedSellTax = (grossEth * DEFAULT_SELL_TAX_BPS) / 10000;
        assertApproxEqAbs(
            creatorFeesFromSell - treasuryFromSell, expectedSellTax, 2, "Sell creator excess should be ~sell tax"
        );
    }

    // ─── LivoSwapBuy / LivoSwapSell event tests ────────────────────────

    bytes32 constant LIVO_SWAP_BUY_SIG = keccak256("LivoSwapBuy(address,address,uint256,uint256,uint256)");
    bytes32 constant LIVO_SWAP_SELL_SIG = keccak256("LivoSwapSell(address,address,uint256,uint256,uint256)");

    function _findLog(Vm.Log[] memory logs, bytes32 sig) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                return logs[i];
            }
        }
        revert("event not found");
    }

    /// @notice Buy emits LivoSwapBuy with correct fields
    function test_buyEmitsLivoSwapBuy() public createDefaultTaxToken {
        _graduateToken();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);

        vm.recordLogs();
        _swapBuy(buyer, buyAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), LIVO_SWAP_BUY_SIG);

        // Indexed: token
        assertEq(address(uint160(uint256(log.topics[1]))), testToken, "token mismatch");

        // Data: (ethIn, tokensOut, ethFees)
        (uint256 ethIn, uint256 tokensOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(ethIn, buyAmount, "ethIn should be buy amount");
        assertGt(tokensOut, 0, "tokensOut should be > 0");
        // No buy tax on default token, only 1% LP fee
        assertEq(ethFees, buyAmount / 100, "ethFees should be 1% LP fee");
    }

    /// @notice Sell emits LivoSwapSell with correct fields
    function test_sellEmitsLivoSwapSell() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        // Warp past tax period so only LP fee applies
        vm.warp(block.timestamp + DEFAULT_TAX_DURATION + 1);

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;

        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), LIVO_SWAP_SELL_SIG);

        // Indexed: token
        assertEq(address(uint160(uint256(log.topics[1]))), testToken, "token mismatch");

        // Data: (tokensIn, ethOut, ethFees)
        (uint256 tokensIn, uint256 ethOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        assertEq(tokensIn, sellAmount, "tokensIn should be sell amount");
        assertGt(ethOut, 0, "ethOut should be > 0");
        // LP fee = 1% of ethOut
        assertApproxEqAbs(ethFees, ethOut / 100, 1, "ethFees should be ~1% LP fee");
    }

    /// @notice Buy with tax emits correct fee amount
    function test_buyWithTaxEmitsCorrectFees() public {
        uint16 buyTax = 300; // 3%
        testToken = _createTaxToken(buyTax, DEFAULT_SELL_TAX_BPS, DEFAULT_TAX_DURATION);
        _graduateToken();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);

        vm.recordLogs();
        _swapBuy(buyer, buyAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), LIVO_SWAP_BUY_SIG);

        (,, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        // LP fee 1% + buy tax 3% = 4%
        uint256 expectedFees = (buyAmount * (100 + buyTax)) / 10000;
        assertEq(ethFees, expectedFees, "ethFees should be LP fee + buy tax");
    }

    /// @notice Sell with tax emits correct fee amount
    function test_sellWithTaxEmitsCorrectFees() public createDefaultTaxToken {
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, DEADLINE);
        _graduateToken();

        uint256 sellAmount = IERC20(testToken).balanceOf(buyer) / 2;

        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0, true);
        Vm.Log memory log = _findLog(vm.getRecordedLogs(), LIVO_SWAP_SELL_SIG);

        (, uint256 ethOut, uint256 ethFees) = abi.decode(log.data, (uint256, uint256, uint256));

        // LP fee 1% + sell tax 5% = 6% of gross ETH
        uint256 expectedFees = (ethOut * (100 + DEFAULT_SELL_TAX_BPS)) / 10000;
        assertApproxEqAbs(ethFees, expectedFees, 2, "ethFees should be LP fee + sell tax");
    }

    /// @notice Accurate fee amounts: buy 10 ETH, verify exactly 0.05 ETH to each of creator and treasury
    function test_accurateFeeAmounts() public createDefaultTaxToken {
        _graduateToken();

        uint256 creatorFeesBefore = _pendingCreatorFees(testToken);
        uint256 treasuryBefore = treasury.balance;

        uint256 buyAmount = 10 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 creatorLpFee = _pendingCreatorFees(testToken) - creatorFeesBefore;
        uint256 treasuryLpFee = treasury.balance - treasuryBefore;

        // 1% of 10 ETH = 0.1 ETH total, split 50/50 = 0.05 ETH each
        assertEq(creatorLpFee, 0.05 ether, "Creator should receive exactly 0.05 ETH");
        assertEq(treasuryLpFee, 0.05 ether, "Treasury should receive exactly 0.05 ETH");
    }
}
