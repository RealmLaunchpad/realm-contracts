// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {E2EHappyPath} from "test/e2e/suites/E2EHappyPath.t.sol";
import {E2EGraduationFlows} from "test/e2e/suites/E2EGraduationFlows.t.sol";

/// @notice E2E variant for the V2 tax token. Mirrors `E2E_FactoryTaxToken` (V4 tax) but uses the
///         V2 graduator + V2 tax token implementation. The tax-window suite is V4-hook-specific
///         (asserts hook-emitted `CreatorTaxesAccrued`), so it is not mixed in here — the V2
///         intrinsic-taxation flow is covered by `RealmTaxableTokenUniV2.t.sol`.
contract E2E_FactoryTaxTokenUniV2 is E2EHappyPath, E2EGraduationFlows, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
        implementation = realmTaxTokenV2;
    }

    function _factory() internal view override returns (address) {
        return address(factoryV2);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(realmTaxTokenV2);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        vm.prank(creator);
        token = factoryV2.createToken(
            "E2E", "E2E", salt, _fs(creator), _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );
    }

    function _createTestTokenWithSplit(bytes32 salt, IRealmFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token)
    {
        vm.prank(creator);
        token = factoryV2.createToken(
            "E2E", "E2E", salt, feeReceivers, _noSs(), _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );
    }

    function _createTokenWithDeployerBuy(
        bytes32 salt,
        uint256 ethValue,
        IRealmFactory.SupplyShare[] memory supplyShares
    ) internal override returns (address token) {
        vm.deal(creator, ethValue);
        vm.prank(creator);
        token = factoryV2.createToken{value: ethValue}(
            "E2E", "E2E", salt, _fs(creator), supplyShares, _taxCfg(0, 400, uint32(7 days)), _emptyAntiSniperCfg()
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return false;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return false;
    }

    function _hasTax() internal pure override returns (bool) {
        return true;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return false;
    }
}
