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

/// @notice Comprehensive tests for LivoTaxableTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    function test_deployLivoToken_withEncodedCalldataFromWrongImplementation() public {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(550, 4 days);

        vm.expectRevert("Token calldata must be empty");
        launchpad.createToken(
            "TestToken",
            "TEST",
            address(implementation),
            address(bondingCurve),
            address(graduator),
            "0x12",
            tokenCalldata
        );
    }

    function test_deployTaxTokenWithTooHighSellTaxes() public {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(550, 4 days);

        vm.expectRevert(abi.encodeWithSelector(LivoTaxableTokenUniV4.InvalidTaxRate.selector, uint16(550)));
        launchpad.createToken(
            "TestToken", "TEST", address(taxTokenImpl), address(bondingCurve), address(graduator), "0x12", tokenCalldata
        );
    }

    // This test is removed because buy taxes no longer exist in the implementation

    function test_deployTaxTokenWithTooLongTaxPeriod() public {
        bytes memory tokenCalldata = taxTokenImpl.encodeTokenCalldata(500, 15 days);

        vm.expectRevert(abi.encodeWithSelector(LivoTaxableTokenUniV4.InvalidTaxDuration.selector, 15 days));
        launchpad.createToken(
            "TestToken", "TEST", address(taxTokenImpl), address(bondingCurve), address(graduator), "0x12", tokenCalldata
        );
    }

    function test_markGraduateOnlyGraduatorAllowed() public createDefaultTaxToken {
        vm.expectRevert(LivoToken.OnlyGraduatorAllowed.selector);
        vm.prank(buyer);
        ILivoToken(testToken).markGraduated();

        vm.prank(address(graduator));
        ILivoToken(testToken).markGraduated();
    }
}
