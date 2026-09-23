// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Vm} from "forge-std/Vm.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

import {LaunchpadBaseTestsWithDirectV4} from "test/launchpad/base.t.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

/// @notice UUPS upgrade-safety tests for the factories (V4 direct as the representative). Locks in:
///         (1) ownership and immutable-readback semantics across an upgrade,
///         (2) upgrade auth (only owner),
///         (3) initializer is one-shot on the proxy and disabled on the implementation,
///         (4) `createToken` still works after the implementation is swapped out.
contract FactoryUpgradeTests is LaunchpadBaseTestsWithDirectV4 {
    function _deployV4ImplWithGraduator(address newGraduator) internal returns (address) {
        return address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: address(realmToken), tax: address(realmTaxToken)}),
                newGraduator,
                address(feeHandler),
                address(creatorVaultFactory),
                address(WETH),
                address(assetsWhitelist)
            )
        );
    }

    function _deployV4ImplSameArgs() internal returns (address) {
        return _deployV4ImplWithGraduator(address(directGraduator));
    }

    // ───────────── Owner / state preservation ─────────────

    function test_upgrade_preservesOwner() public {
        address before = directFactory.owner();
        assertEq(before, admin);

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        directFactory.upgradeToAndCall(newImpl, "");

        assertEq(directFactory.owner(), before);
    }

    function test_upgrade_preservesImmutables_whenSameArgs() public {
        address launchpadBefore = address(directFactory.LAUNCHPAD());
        address graduatorBefore = address(directFactory.GRADUATOR());
        address feeHandlerBefore = address(directFactory.MASTER_FEE_HANDLER());
        address tokenImplBefore = directFactory.TOKEN_IMPL_BASE();

        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        directFactory.upgradeToAndCall(newImpl, "");

        assertEq(address(directFactory.LAUNCHPAD()), launchpadBefore);
        assertEq(address(directFactory.GRADUATOR()), graduatorBefore);
        assertEq(address(directFactory.MASTER_FEE_HANDLER()), feeHandlerBefore);
        assertEq(directFactory.TOKEN_IMPL_BASE(), tokenImplBefore);
    }

    /// @dev Proves the upgrade mechanism actually reroutes reads to the new implementation: a new
    ///      impl deployed with a different `graduator` argument shows up as the new value through
    ///      the proxy.
    function test_upgrade_swapsImmutables_whenDifferentArgs() public {
        address newGraduator = makeAddr("newGraduator");
        address newImpl = _deployV4ImplWithGraduator(newGraduator);

        vm.prank(admin);
        directFactory.upgradeToAndCall(newImpl, "");

        assertEq(address(directFactory.GRADUATOR()), newGraduator);
    }

    // ───────────── Upgrade authorization ─────────────

    function test_upgrade_revertsForNonOwner() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        directFactory.upgradeToAndCall(newImpl, "");
    }

    // ───────────── Initializer safety ─────────────

    function test_initialize_revertsOnSecondCall() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        directFactory.initialize();
    }

    /// @dev `_disableInitializers()` runs in the implementation's constructor, so calling
    ///      `initialize()` directly on the implementation must revert. Otherwise an attacker
    ///      could claim ownership of the implementation contract and (with `selfdestruct` /
    ///      `delegatecall` shenanigans) cause mischief.
    function test_implementationInitializeReverts() public {
        address impl = _deployV4ImplSameArgs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RealmFactoryUniV4Direct(impl).initialize();
    }

    // ───────────── GraduatorSet announcement ─────────────

    function test_initialize_emitsGraduatorSet() public {
        address impl = _deployV4ImplSameArgs();
        vm.expectEmit();
        emit IRealmFactory.GraduatorSet(address(directGraduator));
        new ERC1967Proxy(impl, abi.encodeCall(RealmFactoryAbstract.initialize, ()));
    }

    /// @dev Live proxies predate `_announcedGraduator` (slot 0 is zero): the upgrade announces once,
    ///      a repeat announces nothing, and a graduator swap announces the new one.
    function test_upgrade_announcesGraduatorOnce() public {
        vm.store(address(directFactory), bytes32(0), bytes32(0));
        bytes memory announce = abi.encodeCall(RealmFactoryAbstract.announceGraduator, ());
        address implA = _deployV4ImplSameArgs();
        address implB = _deployV4ImplSameArgs();
        address newGraduator = makeAddr("newGraduator");
        address implC = _deployV4ImplWithGraduator(newGraduator);

        vm.expectEmit(address(directFactory));
        emit IRealmFactory.GraduatorSet(address(directGraduator));
        vm.prank(admin);
        directFactory.upgradeToAndCall(implA, announce);

        vm.recordLogs();
        vm.prank(admin);
        directFactory.upgradeToAndCall(implB, announce);
        directFactory.announceGraduator();
        assertEq(_countGraduatorSet(), 0);

        vm.expectEmit(address(directFactory));
        emit IRealmFactory.GraduatorSet(newGraduator);
        vm.prank(admin);
        directFactory.upgradeToAndCall(implC, announce);
    }

    function _countGraduatorSet() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IRealmFactory.GraduatorSet.selector) n++;
        }
    }

    // ───────────── End-to-end after upgrade ─────────────

    function test_createToken_worksAfterUpgrade() public {
        address newImpl = _deployV4ImplSameArgs();
        vm.prank(admin);
        directFactory.upgradeToAndCall(newImpl, "");

        address token = _createDirectToken(_emptyTaxCfg());
        assertTrue(token != address(0));
    }
}
