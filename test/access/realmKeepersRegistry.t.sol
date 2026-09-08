// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";

/// @notice Unit tests for the keeper allowlist: who may change it, and what the two tiers mean.
/// @dev The tiers are the whole point. The owner is a cold multisig that appoints admins; admins rotate
///      hot keeper keys without touching it. A test that let either tier do the other's job would erase
///      the reason the contract has two.
contract RealmKeepersRegistryTest is Test {
    RealmKeepersRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        registry = new RealmKeepersRegistry(owner);
    }

    function test_startsEmpty() public view {
        assertFalse(registry.isKeeper(keeper), "nobody is a keeper by default");
        assertFalse(registry.isAdmin(admin), "nobody is an admin by default");
        assertEq(registry.owner(), owner, "owner set in the constructor");
    }

    function test_theOwnerAppointsAdmins() public {
        vm.prank(owner);
        registry.setAdmin(admin, true);
        assertTrue(registry.isAdmin(admin));
    }

    function test_anAdminCannotAppointAdmins() public {
        vm.prank(owner);
        registry.setAdmin(admin, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        registry.setAdmin(stranger, true);
    }

    function test_anAdminAppointsKeepers() public {
        vm.prank(owner);
        registry.setAdmin(admin, true);

        vm.prank(admin);
        registry.setKeeper(keeper, true);
        assertTrue(registry.isKeeper(keeper));
    }

    /// @dev The owner is an admin implicitly, so a chain with no admins appointed yet is still operable.
    function test_theOwnerCanAppointKeepersDirectly() public {
        vm.prank(owner);
        registry.setKeeper(keeper, true);
        assertTrue(registry.isKeeper(keeper));
    }

    function test_aStrangerCannotAppointKeepers() public {
        vm.prank(stranger);
        vm.expectRevert(RealmKeepersRegistry.NotAdmin.selector);
        registry.setKeeper(stranger, true);
    }

    /// @dev A keeper holds no funds and has nothing to unwind, so revocation is a single write with no
    ///      grace period — which is what makes a compromised hot key a contained incident.
    function test_revocationIsImmediate() public {
        vm.startPrank(owner);
        registry.setKeeper(keeper, true);
        registry.setKeeper(keeper, false);
        vm.stopPrank();

        assertFalse(registry.isKeeper(keeper));
    }

    /// @dev A keeper is not an admin: appointing one must not hand out the power to appoint more.
    function test_aKeeperCannotAppointKeepers() public {
        vm.prank(owner);
        registry.setKeeper(keeper, true);

        vm.prank(keeper);
        vm.expectRevert(RealmKeepersRegistry.NotAdmin.selector);
        registry.setKeeper(stranger, true);
    }
}
