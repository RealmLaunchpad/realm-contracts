// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    BaseUniswapV4FeesTests,
    UniswapV4ClaimFeesViewFunctionsBase
} from "test/graduators/graduationUniv4.claimFees.t.sol";
import {BaseUniswapV4GraduationTests} from "test/graduators/graduationUniv4.base.t.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmSwapHook} from "src/hooks/RealmSwapHook.sol";
import {Vm} from "forge-std/Vm.sol";

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
        address token = _createDirectTokenAs(
            creator, name, symbol, _fs(creator), false, _taxCfg(0, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION))
        );
        return token;
    }

    /// @notice Verify that sell tax math is correct: tax/gross == taxBps
    function test_sellTax_amountIsCorrect() public createAndGraduateToken {
        uint256 ethBefore = buyer.balance;

        uint256 sellAmount = 100_000_000e18;
        vm.recordLogs();
        _swapSell(buyer, sellAmount, 0.1 ether, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 Y = buyer.balance - ethBefore; // ETH received by seller
        // The seller's sell is the first tax accrual; the swap helper's LP-fee conversion comes after it.
        uint256 tax = abi.decode(
            _firstLogData(
                logs, address(taxHook), RealmSwapHook.CreatorTaxesAccrued.selector, bytes32(uint256(uint160(testToken)))
            ),
            (uint256)
        );
        // The hook takes nothing but the tax from the pool's output: the LP fee was paid in the token.
        uint256 gross = Y + tax;

        // tax / gross == DEFAULT_SELL_TAX_BPS
        assertApproxEqRel(
            tax * 10_000, gross * DEFAULT_SELL_TAX_BPS, 0.0000001e18, "tax/gross should be ~DEFAULT_SELL_TAX_BPS"
        );
    }

    /// @notice Verify that buys have no sell tax, only 1% LP fees
    function test_buyTax_noSellTaxOnlyLpFees() public createAndGraduateToken {
        uint256 claimableBefore = _creatorClaimable();

        uint256 buyAmount = 1 ether;
        deal(buyer, buyAmount);
        _swapBuy(buyer, buyAmount, 0, true);

        uint256 claimableDelta = _creatorClaimable() - claimableBefore;

        // Creator gets the share (60%) of the 1% total LP fee on buys
        assertApproxEqAbs(claimableDelta, _lpCreatorShare(buyAmount), 1, "buy claimable should be LP share");
    }
}
