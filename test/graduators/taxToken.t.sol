// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";

/// @notice Comprehensive tests for LivoTaxableTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    function test_deployTaxTokenWithTooHighSellTaxes() public {
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxBps.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 0, 550, uint32(4 days));
    }

    function test_deployTaxTokenWithTooLongTaxPeriod() public {
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxDuration.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 0, 500, uint32(15 days));
    }

    function test_markGraduateOnlyGraduatorAllowed() public createDefaultTaxToken {
        vm.expectRevert(LivoToken.OnlyGraduatorAllowed.selector);
        vm.prank(buyer);
        ILivoToken(testToken).markGraduated();

        vm.prank(address(graduator));
        ILivoToken(testToken).markGraduated();
    }
}
