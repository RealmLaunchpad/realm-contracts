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
        return factoryTax.createToken(name, symbol, creator, metadata, DEFAULT_SELL_TAX_BPS, uint32(DEFAULT_TAX_DURATION));
    }
}
