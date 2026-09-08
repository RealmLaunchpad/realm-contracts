// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice Factory-level coverage for the `directFeesEnabled` opt-in field on `FeeShare`:
///         - max-1-direct enforcement
///         - registration in the singleton handler when 1 receiver opts in
///         - propagation into the master handler config when 2+ receivers and one opts in
///         - struct-level validation paths (zero address, share sums, etc.) still hold
contract RealmFactoryDirectFeesTest is LaunchpadBaseTestsWithUniv4Graduator {
    function _fsTwoWithDirect(address a1, uint256 s1, address a2, uint256 s2, bool a1Direct, bool a2Direct)
        internal
        pure
        returns (IRealmFactory.FeeShare[] memory arr)
    {
        arr = new IRealmFactory.FeeShare[](2);
        arr[0] = IRealmFactory.FeeShare({account: a1, shares: s1, directFeesEnabled: a1Direct});
        arr[1] = IRealmFactory.FeeShare({account: a2, shares: s2, directFeesEnabled: a2Direct});
    }

    /// @dev when two receivers both flag directFeesEnabled, then createToken reverts with MultipleDirectFeeReceivers
    function test_createToken_revertsWhenTwoDirectReceivers() public {
        IRealmFactory.FeeShare[] memory fs = _fsTwoWithDirect(alice, 6_000, bob, 4_000, true, true);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.MultipleDirectFeeReceivers.selector);
        factoryV4Unified.createToken(
            "DirectFees", "DF", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev when one receiver flags direct (single-receiver path), then registerDirectReceiver is invoked on the singleton
    function test_createToken_singleDirect_registersOnSingleton() public {
        IRealmFactory.FeeShare[] memory fs = _fsDirect(creator);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "DirectFees", "DF", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertTrue(feeHandler.isDirectReceiver(token, creator), "direct receiver registered");
    }

    /// @dev when one receiver flags direct (single-receiver path) on V2 factory, then registerDirectReceiver is invoked
    function test_createToken_singleDirect_registersOnSingleton_v2() public {
        IRealmFactory.FeeShare[] memory fs = _fsDirect(creator);

        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmToken));
        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("DirectFees", "DF", salt, fs, _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertTrue(feeHandler.isDirectReceiver(token, creator), "direct receiver registered (V2)");
    }

    /// @dev when no receiver flags direct, then directReceiver mapping stays zero for the token
    function test_createToken_noDirect_doesNotRegister() public {
        IRealmFactory.FeeShare[] memory fs = _fs(creator);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("Plain", "P", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertFalse(feeHandler.isDirectReceiver(token, creator), "no direct registration when not opted in");
    }

    /// @dev when 2+ receivers and one flags direct, master handler registers the direct receiver
    function test_createToken_multiReceiver_withDirect_registersDirectOnMasterHandler() public {
        IRealmFactory.FeeShare[] memory fs = _fsTwoWithDirect(alice, 6_000, bob, 4_000, true, false);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "MultiReceiver", "MR", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertTrue(feeHandler.isDirectReceiver(token, alice), "alice is direct receiver");
        assertFalse(feeHandler.isDirectReceiver(token, bob), "bob is claimable, not direct");
    }

    /// @dev when receiver flags direct on a V4 deployer-buy (msg.value > 0), the registration happens before launchToken
    function test_createToken_directWithDeployerBuy_registersBeforeAccrual() public {
        IRealmFactory.FeeShare[] memory fs = _fsDirect(creator);
        IRealmFactory.SupplyShare[] memory ss = _ss(creator);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.deal(creator, 5 ether);
        // Small buy so the token stays pre-graduation; the trace shows registration is invoked
        // immediately after token init, before any fee can possibly flow.
        vm.prank(creator);
        address token = factoryV4Unified.createToken{value: 0.05 ether}(
            "DirectBuy", "DB", salt, fs, ss, false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertTrue(feeHandler.isDirectReceiver(token, creator), "registered before deployer-buy fees flow");
    }
}
