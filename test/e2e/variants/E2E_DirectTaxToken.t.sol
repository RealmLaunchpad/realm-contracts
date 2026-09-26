// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {E2ETaxWindow} from "test/e2e/suites/E2ETaxWindow.t.sol";

/// @notice The V4 tax window end to end, on a direct-launched taxable token (4% sell for 7 days). The
///         curve-flow suites (`E2EHappyPath`, `E2EGraduationFlows`) run on the V2 variants only: a
///         direct token has no pre-graduation phase.
contract E2E_DirectTaxToken is E2ETaxWindow, LaunchpadBaseTestsWithDirectV4 {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {
        super.setUp();
    }

    function _createTestToken() internal override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {
        LaunchpadBaseTestsWithDirectV4._createTestToken();
    }

    function _graduateToken() internal override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {}

    function _factory() internal view override returns (address) {
        return address(directFactory);
    }

    function _tokenImpl() internal view override returns (address) {
        return address(realmTaxToken);
    }

    function _createTestToken(bytes32 salt) internal override returns (address token) {
        return _createDirect(salt, _fs(creator), 0, _noDevBuy());
    }

    function _createTestTokenWithSplit(bytes32 salt, IRealmFactory.FeeShare[] memory feeReceivers)
        internal
        override
        returns (address token)
    {
        return _createDirect(salt, feeReceivers, 0, _noDevBuy());
    }

    function _createTokenWithDeployerBuy(
        bytes32 salt,
        uint256 ethValue,
        IRealmFactory.SupplyShare[] memory supplyShares
    ) internal override returns (address token) {
        RealmFactoryUniV4Direct.DevBuy memory devBuy = _noDevBuy();
        devBuy.recipients = supplyShares;
        return _createDirect(salt, _fs(creator), ethValue, devBuy);
    }

    function _createDirect(
        bytes32 salt,
        IRealmFactory.FeeShare[] memory feeShares,
        uint256 ethValue,
        RealmFactoryUniV4Direct.DevBuy memory devBuy
    ) internal returns (address token) {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: "E2E", symbol: "E2E", salt: salt, feeShares: feeShares, renounceOwnership: false, lpFeeBps: 100
        });
        vm.deal(creator, ethValue);
        vm.prank(creator);
        token = directFactory.createToken{value: ethValue}(
            setup,
            _nativePair(),
            _noDirectAlloc(_taxCfg(0, 400, uint32(7 days))),
            _emptyAntiSniperCfg(),
            _noVaults(),
            devBuy,
            address(0)
        );
    }

    function _isV4Graduator() internal pure override returns (bool) {
        return true;
    }

    function _hasSniperProtection() internal pure override returns (bool) {
        return false;
    }

    function _hasTax() internal pure override returns (bool) {
        return true;
    }

    function _supportsRenounceOwnership() internal pure override returns (bool) {
        return true;
    }
}
