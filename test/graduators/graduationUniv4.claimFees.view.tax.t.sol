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
            factoryTax.createToken(
                name, symbol, creator, metadata, 0, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION)
            );
    }

    /// @notice Verify that sell tax math is correct: tax/gross == taxBps
    function test_sellTax_amountIsCorrect() public createAndGraduateToken {
        uint256 claimableBefore = _creatorClaimable();
        uint256 ethBefore = buyer.balance;
        uint256 treasuryBefore = treasury.balance;

        uint256 sellAmount = 100_000_000e18;
        _swapSell(buyer, sellAmount, 0.1 ether, true);

        uint256 Y = buyer.balance - ethBefore; // ETH received by seller
        uint256 creatorDelta = _creatorClaimable() - claimableBefore; // LP creator share + sell tax
        uint256 treasuryDelta = treasury.balance - treasuryBefore; // LP treasury share
        uint256 gross = Y + creatorDelta + treasuryDelta; // total ETH from pool

        // creatorDelta = lpCreatorShare + taxAmount; treasuryDelta = lpTreasuryShare ≈ lpCreatorShare
        // so taxOnly ≈ creatorDelta - treasuryDelta
        uint256 taxOnly = creatorDelta - treasuryDelta;

        // taxOnly / gross == 5%
        assertApproxEqRel(taxOnly * 10_000, gross * DEFAULT_SELL_TAX_BPS, 0.0000001e18, "tax/gross should be ~5%");
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
