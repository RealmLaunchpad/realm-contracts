// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {E2EHappyPath} from "test/e2e/suites/E2EHappyPath.t.sol";
import {E2EGraduationFlows} from "test/e2e/suites/E2EGraduationFlows.t.sol";
import {E2ESniperWindow} from "test/e2e/suites/E2ESniperWindow.t.sol";

contract E2E_FactorySniperProtected is
    E2EHappyPath,
    E2EGraduationFlows,
    E2ESniperWindow,
    LaunchpadBaseTestsWithUniv4Graduator
{
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }

    function _factory() internal view override returns (address) {
        return address(factorySniper);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(realmTokenSniper);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        vm.prank(creator);
        token = factorySniper.createToken(
            "E2E", "E2E", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _defaultE2EAntiSniperCfg()
        );
    }

    function _createTestTokenWithSplit(bytes32 salt, IRealmFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token)
    {
        vm.prank(creator);
        token = factorySniper.createToken(
            "E2E", "E2E", salt, feeReceivers, _noSs(), false, _emptyTaxCfg(), _defaultE2EAntiSniperCfg()
        );
    }

    function _createTokenWithDeployerBuy(
        bytes32 salt,
        uint256 ethValue,
        IRealmFactory.SupplyShare[] memory supplyShares
    ) internal override returns (address token) {
        vm.deal(creator, ethValue);
        vm.prank(creator);
        token = factorySniper.createToken{value: ethValue}(
            "E2E", "E2E", salt, _fs(creator), supplyShares, false, _emptyTaxCfg(), _defaultE2EAntiSniperCfg()
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return true;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return true;
    }

    function _hasTax() internal pure override returns (bool) {
        return false;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return true;
    }
}
