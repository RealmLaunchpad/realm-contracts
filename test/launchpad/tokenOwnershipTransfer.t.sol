// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";

contract TokenOwnershipTransferTests is LaunchpadBaseTestsWithUniv4Graduator {
    modifier proposedOwner(address currentOwner, address nextOwner) {
        vm.prank(currentOwner);
        IRealmToken(testToken).proposeNewOwner(nextOwner);
        _;
    }

    /// @dev when creator proposes alice and alice accepts, then `owner()` returns alice
    function test_proposeAccept_assertGetTokenOwnerMatchesProposed()
        public
        createTestToken
        proposedOwner(creator, alice)
    {
        vm.prank(alice);
        IRealmToken(testToken).acceptTokenOwnership();

        assertEq(IRealmToken(testToken).owner(), alice);
    }

    /// @dev when creator proposes alice then reproposes bob, then alice cannot accept and bob can become owner
    function test_reproposeFromAliceToBob_assertOnlyBobCanAccept() public createTestToken {
        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(bob);

        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(testToken).acceptTokenOwnership();

        vm.prank(bob);
        IRealmToken(testToken).acceptTokenOwnership();

        assertEq(IRealmToken(testToken).owner(), bob);
    }

    /// @dev when creator proposes alice then cancels with `address(0)`, then alice cannot accept ownership
    function test_proposeThenCancel_assertAliceCannotAccept() public createTestToken {
        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(address(0));

        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(testToken).acceptTokenOwnership();

        assertEq(IRealmToken(testToken).owner(), creator);
    }

    /// @dev when creator transfers to alice and alice later transfers to bob, then final `owner()` returns bob
    function test_transferToAliceThenBob_assertGetTokenOwnerMatchesFinalAcceptedOwner() public createTestToken {
        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(alice);

        vm.prank(alice);
        IRealmToken(testToken).acceptTokenOwnership();
        assertEq(IRealmToken(testToken).owner(), alice);

        vm.prank(alice);
        IRealmToken(testToken).proposeNewOwner(bob);

        vm.prank(bob);
        IRealmToken(testToken).acceptTokenOwnership();

        assertEq(IRealmToken(testToken).owner(), bob);
    }

    /// @dev test only the current tokenOwner can propose a new wner
    function test_onlyCurrentOwnerCanPropose() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(alice);
    }

    /// @dev owner renounces, owner becomes address(0), proposedOwner cleared, event emitted
    function test_renounceOwnership_happyPath() public createTestToken {
        vm.expectEmit(address(testToken));
        emit IRealmToken.OwnershipTransferred(address(0));

        vm.prank(creator);
        IRealmToken(testToken).renounceOwnership();

        assertEq(IRealmToken(testToken).owner(), address(0));
        assertEq(IRealmToken(testToken).proposedOwner(), address(0));
    }

    /// @dev non-owner cannot renounce
    function test_renounceOwnership_revertsIfNotOwner() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(testToken).renounceOwnership();
    }

    /// @dev if a proposedOwner was set, it gets cleared on renounce
    function test_renounceOwnership_clearsPendingProposal() public createTestToken proposedOwner(creator, alice) {
        assertEq(IRealmToken(testToken).proposedOwner(), alice);

        vm.prank(creator);
        IRealmToken(testToken).renounceOwnership();

        assertEq(IRealmToken(testToken).owner(), address(0));
        assertEq(IRealmToken(testToken).proposedOwner(), address(0));
    }

    /// @dev proposeNewOwner reverts after ownership is renounced
    function test_renounceOwnership_cannotProposeAfterRenounce() public createTestToken {
        vm.prank(creator);
        IRealmToken(testToken).renounceOwnership();

        vm.prank(creator);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(testToken).proposeNewOwner(alice);
    }
}
