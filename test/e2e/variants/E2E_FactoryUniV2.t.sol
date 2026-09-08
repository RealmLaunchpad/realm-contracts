// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {E2EHappyPath} from "test/e2e/suites/E2EHappyPath.t.sol";
import {E2EGraduationFlows} from "test/e2e/suites/E2EGraduationFlows.t.sol";

contract E2E_FactoryUniV2 is E2EHappyPath, E2EGraduationFlows, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    function _factory() internal view override returns (address) {
        return address(factoryV2);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(realmToken);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        vm.prank(creator);
        token = factoryV2.createToken("E2E", "E2E", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function _createTestTokenWithSplit(bytes32 salt, IRealmFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token)
    {
        vm.prank(creator);
        token = factoryV2.createToken("E2E", "E2E", salt, feeReceivers, _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function _createTokenWithDeployerBuy(
        bytes32 salt,
        uint256 ethValue,
        IRealmFactory.SupplyShare[] memory supplyShares
    ) internal override returns (address token) {
        vm.deal(creator, ethValue);
        vm.prank(creator);
        token = factoryV2.createToken{value: ethValue}(
            "E2E", "E2E", salt, _fs(creator), supplyShares, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return false;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return false;
    }

    function _hasTax() internal pure override returns (bool) {
        return false;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return false;
    }
}
