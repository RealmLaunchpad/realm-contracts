// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BaseUniswapV4FeesTests,
    UniswapV4ClaimFeesViewFunctionsBase
} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

contract UniswapV4ClaimFeesViewFunctions_TaxToken is TaxTokenUniV4BaseTests, UniswapV4ClaimFeesViewFunctionsBase {
    function setUp() public override(TaxTokenUniV4BaseTests, BaseUniswapV4FeesTests) {
        super.setUp();
        implementation = IRealmToken(address(taxTokenImpl));
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

    function _createTokenForCreator(string memory name, string memory symbol, bytes32)
        internal
        override
        returns (address)
    {
        vm.prank(creator);
        address token = factoryTax.createToken(
            name,
            symbol,
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION)),
            _emptyAntiSniperCfg()
        );
        return token;
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

        // creatorDelta = lpCreatorShare + taxAmount, so isolating the tax means subtracting the
        // creator's tier-0 LP share of the gross (the creator and treasury LP shares are no longer
        // equal, so `creatorDelta - treasuryDelta` would leave the 20 bps tier-0 gap in `taxOnly`).
        uint256 taxOnly = creatorDelta - _lpCreatorShareTier0(gross);

        // taxOnly / gross == DEFAULT_SELL_TAX_BPS
        assertApproxEqRel(
            taxOnly * 10_000, gross * DEFAULT_SELL_TAX_BPS, 0.0000001e18, "tax/gross should be ~DEFAULT_SELL_TAX_BPS"
        );
    }

    /// @notice Verify that buys have no sell tax, only 1% LP fees
    function test_buyTax_noSellTaxOnlyLpFees() public createAndGraduateToken {
        uint256 claimableBefore = _creatorClaimable();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 claimableDelta = _creatorClaimable() - claimableBefore;

        // Creator gets the tier-0 share (60%) of the 1% total LP fee on buys
        assertApproxEqAbs(claimableDelta, _lpCreatorShareTier0(buyAmount), 1, "buy claimable should be tier-0 LP share");
    }
}
