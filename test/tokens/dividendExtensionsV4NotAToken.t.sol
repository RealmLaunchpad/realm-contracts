// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {RealmV4ExtensionBase} from "src/tokens/RealmV4ExtensionBase.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice The two Uniswap-V4 extensions, `RealmDividendLogicUniV4` and `RealmEarningsLogicUniV4`, are
///         execution bodies a token `delegatecall`s into, not tokens. The V4 counterpart of
///         `DividendsTaxTokenV2Tests.test_extension_disownsTheTokenEntryPoints`, over the whole stub set
///         `RealmV4ExtensionBase` gives both.
contract DividendExtensionsV4NotATokenTests is LaunchpadBaseTests {
    /// @dev Every token entry point the extension inherits reverts `NotAToken` when reached directly.
    function _assertDisownsTheTokenEntryPoints(address extension) internal {
        RealmV4ExtensionBase ext = RealmV4ExtensionBase(payable(extension));
        IRealmToken.InitializeParams memory params;
        TaxConfigs memory taxCfg;
        AntiSniperConfigs memory antiSniperCfg;
        IRealmToken.LaunchpadTrade memory trade;

        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.initialize(params, taxCfg, antiSniperCfg);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.initialize(params, antiSniperCfg);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.transfer(alice, 1);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.transferFrom(alice, bob, 1);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.burn(1);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.burnFrom(alice, 1);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.markGraduated();
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.rescueTokens(address(WETH));
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.setTaxBps(0, 0);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.accrueFees{value: 0}();
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.sweepStrayEth();
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.getLaunchpadFees(trade);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.getTaxConfig();
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.getSwapFees(true);
        vm.expectRevert(RealmTaxableToken.NotAToken.selector);
        ext.initializeEarningsAllocation(0, 0, 0);
    }

    function test_dividendExtension_disownsTheTokenEntryPoints() public {
        _assertDisownsTheTokenEntryPoints(realmTaxToken.DIVIDEND_LOGIC());
    }

    function test_earningsExtension_disownsTheTokenEntryPoints() public {
        _assertDisownsTheTokenEntryPoints(realmTaxToken.EARNINGS_LOGIC());
    }
}
