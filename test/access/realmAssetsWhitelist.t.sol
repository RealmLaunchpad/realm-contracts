// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";

/// @notice Unit tests for the assets whitelist: the owner appoints approvers and nothing else, approvers
///         list assets and nothing else.
contract RealmAssetsWhitelistTest is Test {
    RealmAssetsWhitelist internal whitelist;

    address internal owner = makeAddr("owner");
    address internal approver = makeAddr("approver");
    address internal stranger = makeAddr("stranger");
    address internal asset = makeAddr("asset");

    function setUp() public {
        whitelist = new RealmAssetsWhitelist(owner);
    }

    function test_startsEmpty() public view {
        assertEq(whitelist.unitsPerNativeX18(asset), 0, "nothing is whitelisted by default");
        assertFalse(whitelist.isApprover(approver), "nobody is an approver by default");
        assertEq(whitelist.owner(), owner, "owner set in the constructor");
    }

    function test_theOwnerAppointsApprovers() public {
        vm.expectEmit(address(whitelist));
        emit RealmAssetsWhitelist.ApproverSet(approver, true);
        vm.prank(owner);
        whitelist.setApprover(approver, true);
        assertTrue(whitelist.isApprover(approver));
    }

    function test_anApproverCannotAppointApprovers() public {
        vm.prank(owner);
        whitelist.setApprover(approver, true);

        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, approver));
        whitelist.setApprover(stranger, true);
    }

    /// @dev Unlike the keepers registry, the owner is NOT an approver implicitly.
    function test_theOwnerCannotWhitelist() public {
        vm.prank(owner);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(asset, 1e18);
    }

    function test_aStrangerCannotWhitelist() public {
        vm.prank(stranger);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(asset, 1e18);
    }

    function test_anApproverWhitelistsUpdatesAndDelists() public {
        vm.prank(owner);
        whitelist.setApprover(approver, true);

        vm.startPrank(approver);
        vm.expectEmit(address(whitelist));
        emit RealmAssetsWhitelist.WhitelistUpdated(asset, 3_500e18);
        whitelist.setWhitelisted(asset, 3_500e18);
        assertEq(whitelist.unitsPerNativeX18(asset), 3_500e18, "listed");

        whitelist.setWhitelisted(asset, 4_000e18);
        assertEq(whitelist.unitsPerNativeX18(asset), 4_000e18, "rate updated");

        whitelist.setWhitelisted(asset, 0);
        assertEq(whitelist.unitsPerNativeX18(asset), 0, "delisted");
        vm.stopPrank();
    }

    function test_aRevokedApproverCannotWhitelist() public {
        vm.startPrank(owner);
        whitelist.setApprover(approver, true);
        whitelist.setApprover(approver, false);
        vm.stopPrank();

        vm.prank(approver);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(asset, 1e18);
    }
}
