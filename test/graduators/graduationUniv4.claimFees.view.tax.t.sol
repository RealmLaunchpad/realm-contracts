// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BaseUniswapV4FeesTests,
    UniswapV4ClaimFeesViewFunctionsBase
} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

contract UniswapV4ClaimFeesViewFunctions_TaxToken is TaxTokenUniV4BaseTests, UniswapV4ClaimFeesViewFunctionsBase {
    function setUp() public override(TaxTokenUniV4BaseTests, BaseUniswapV4FeesTests) {
        super.setUp();
        implementation = ILivoToken(address(taxTokenImpl));
    }

    function _expectsSellTaxes() internal pure override returns (bool) {
        return true;
    }

    function _swap(
        address caller,
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBuy,
        bool expectSuccess
    ) internal override(BaseUniswapV4GraduationTests, TaxTokenUniV4BaseTests) {
        TaxTokenUniV4BaseTests._swap(caller, token, amountIn, minAmountOut, isBuy, expectSuccess);
    }

    function _createTokenForCreator(string memory name, string memory symbol, bytes32 metadata)
        internal
        override
        returns (address)
    {
        vm.prank(creator);
        return
            factoryTax.createToken(name, symbol, creator, metadata, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION));
    }

    /// @notice Verify that sell tax math is correct: tax/T == taxBps and claimable == tax
    function test_sellTax_amountIsCorrect() public createAndGraduateToken {
        uint256 claimableBefore = _creatorClaimable();
        uint256 ethBefore = buyer.balance;

        uint256 sellAmount = 100_000_000e18;
        _swapSell(buyer, sellAmount, 0.1 ether, true);

        uint256 Y = buyer.balance - ethBefore; // ETH received by seller
        uint256 tax = _creatorClaimable() - claimableBefore; // tax accrued as claimable
        uint256 T = Y + tax; // total ETH that left the pool

        // tax / T == 5%
        assertApproxEqRel(tax * 10_000 / T, DEFAULT_SELL_TAX_BPS, 0.000001e18, "tax/T should be ~5%");
        // Y / T == 95%
        assertApproxEqRel(Y * 10_000 / T, 10_000 - DEFAULT_SELL_TAX_BPS, 0.000001e18, "Y/T should be ~95%");
    }

    /// @notice Verify that buys have no sell tax, only 1% LP fees
    function test_buyTax_noSellTaxOnlyLpFees() public createAndGraduateToken {
        uint256 claimableBefore = _creatorClaimable();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 claimableDelta = _creatorClaimable() - claimableBefore;

        // Creator gets 0.5% LP fees on buys (half of 1% total LP fee)
        assertApproxEqAbs(claimableDelta, buyAmount / 200, 1, "buy claimable should be ~0.5% LP fee share");
    }
}
