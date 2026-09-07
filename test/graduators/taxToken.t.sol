// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {IRealmTaxableToken} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {LivoSwapHook} from "src/hooks/LivoSwapHook.sol";
import {IRealmGraduator} from "src/interfaces/IRealmGraduator.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice Comprehensive tests for RealmTaxableTokenUniV4 and LivoTaxSwapHook functionality
contract TaxTokenUniV4Tests is TaxTokenUniV4BaseTests {
    function test_deployTaxTokenWithTooHighSellTaxes() public {
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxBps.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            "0x12",
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 401, uint32(4 days)),
            _emptyAntiSniperCfg()
        );
    }

    function test_deployTaxTokenWithTooLongTaxPeriod() public {
        // Duration above the 120-year overflow-prevention cap — must revert with InvalidTaxDuration.
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxDuration.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            "0x12",
            _fs(alice),
            _noSs(),
            true,
            _taxCfg(0, 400, uint32(120 * 365 days + 1)),
            _emptyAntiSniperCfg()
        );
    }

    function test_markGraduateOnlyGraduatorAllowed() public createDefaultTaxToken {
        vm.expectRevert(RealmToken.OnlyGraduatorAllowed.selector);
        vm.prank(buyer);
        IRealmToken(testToken).markGraduated();

        vm.prank(address(graduator));
        IRealmToken(testToken).markGraduated();
    }
}
