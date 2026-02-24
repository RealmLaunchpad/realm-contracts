// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";

contract TokenOwnershipTransferTests is LaunchpadBaseTestsWithUniv2Graduator {
    modifier proposedOwner(address currentOwner, address nextOwner) {
        vm.prank(currentOwner);
        launchpad.proposeTokenOwner(testToken, nextOwner);
        _;
    }

    /// @dev when creator proposes alice and alice accepts, then `getTokenOwner()` returns alice
    function test_proposeAccept_assertGetTokenOwnerMatchesProposed() public createTestToken proposedOwner(creator, alice) {
        vm.prank(alice);
        launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), alice);
    }

    /// @dev when creator proposes alice then reproposes bob, then alice cannot accept and bob can become owner
    function test_reproposeFromAliceToBob_assertOnlyBobCanAccept() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, bob);

        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.acceptTokenOwnership(testToken);

        vm.prank(bob);
        launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), bob);
    }

    /// @dev when creator proposes alice then cancels with `address(0)`, then alice cannot accept ownership
    function test_proposeThenCancel_assertAliceCannotAccept() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, address(0));

        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), creator);
    }

    /// @dev when creator transfers to alice and alice later transfers to bob, then final `getTokenOwner()` returns bob
    function test_transferToAliceThenBob_assertGetTokenOwnerMatchesFinalAcceptedOwner() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(alice);
        launchpad.acceptTokenOwnership(testToken);
        assertEq(launchpad.getTokenOwner(testToken), alice);

        vm.prank(alice);
        launchpad.proposeTokenOwner(testToken, bob);

        vm.prank(bob);
            launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), bob);
    }

    /// @dev test only the current tokenOwner can propose a new wner
    function test_onlyCurrentOwnerCanPropose() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);
    }
}
