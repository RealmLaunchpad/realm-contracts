// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

/// @notice UUPS upgrade-safety tests for the unified factories. Locks in:
///         (1) ownership and immutable-readback semantics across an upgrade,
///         (2) upgrade auth (only owner),
///         (3) initializer is one-shot on the proxy and disabled on the implementation,
///         (4) `createToken` still works after the implementation is swapped out.
contract FactoryUpgradeTests is LaunchpadBaseTestsWithUniv4Graduator {
    function _deployV4ImplWithGraduator(address newGraduator) internal returns (address) {
        return address(
            new RealmFactoryUniV4Unified(
                address(launchpad),
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxToken)}),
                address(bondingCurve),
                newGraduator,
                address(feeHandler),
                address(creatorVaultFactory),
                vaultCurves,
                _v4TierConfig()
            )
        );
    }

    function _deployV4ImplSameArgs() internal returns (address) {
        return _deployV4ImplWithGraduator(address(graduatorV4));
    }

    // ───────────── Owner / state preservation ─────────────

    function test_upgrade_preservesOwner() public {
        address before = factoryV4Unified.owner();
        assertEq(before, admin);

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(factoryV4Unified.owner(), before);
    }

    function test_upgrade_preservesImmutables_whenSameArgs() public {
        address launchpadBefore = address(factoryV4Unified.LAUNCHPAD());
        address graduatorBefore = address(factoryV4Unified.GRADUATOR());
        address feeHandlerBefore = address(factoryV4Unified.MASTER_FEE_HANDLER());
        address tokenImplBefore = factoryV4Unified.TOKEN_IMPL_BASE();

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(address(factoryV4Unified.LAUNCHPAD()), launchpadBefore);
        assertEq(address(factoryV4Unified.GRADUATOR()), graduatorBefore);
        assertEq(address(factoryV4Unified.MASTER_FEE_HANDLER()), feeHandlerBefore);
        assertEq(factoryV4Unified.TOKEN_IMPL_BASE(), tokenImplBefore);
    }

    /// @dev Proves the upgrade mechanism actually reroutes reads to the new implementation: a new
    ///      impl deployed with a different `graduator` argument shows up as the new value through
    ///      the proxy.
    function test_upgrade_swapsImmutables_whenDifferentArgs() public {
        address newGraduator = makeAddr("newGraduator");
        address newImpl = _deployV4ImplWithGraduator(newGraduator);

        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        assertEq(address(factoryV4Unified.GRADUATOR()), newGraduator);
    }

    // ───────────── Upgrade authorization ─────────────

    function test_upgrade_revertsForNonOwner() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        factoryV4Unified.upgradeToAndCall(newImpl, "");
    }

    // ───────────── Initializer safety ─────────────

    function test_initialize_revertsOnSecondCall() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factoryV4Unified.initialize();
    }

    /// @dev `_disableInitializers()` runs in the implementation's constructor, so calling
    ///      `initialize()` directly on the implementation must revert. Otherwise an attacker
    ///      could claim ownership of the implementation contract and (with `selfdestruct` /
    ///      `delegatecall` shenanigans) cause mischief.
    function test_implementationInitializeReverts() public {
        address impl = _deployV4ImplSameArgs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RealmFactoryUniV4Unified(impl).initialize();
    }

    // ───────────── End-to-end after upgrade ─────────────

    function test_createToken_worksAfterUpgrade() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        factoryV4Unified.upgradeToAndCall(newImpl, "");

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "Upgraded", "UPG", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
        assertTrue(token != address(0));
    }
}
