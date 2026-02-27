// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";

contract TokenOwnershipTransferTests is LaunchpadBaseTestsWithUniv2Graduator {
    modifier proposedOwner(address currentOwner, address nextOwner) {
        vm.prank(currentOwner);
        ILivoToken(testToken).proposeNewOwner(nextOwner);
        _;
    }

    /// @dev when creator proposes alice and alice accepts, then `owner()` returns alice
    function test_proposeAccept_assertGetTokenOwnerMatchesProposed()
        public
        createTestToken
        proposedOwner(creator, alice)
    {
        vm.prank(alice);
        ILivoToken(testToken).acceptTokenOwnership();

        assertEq(ILivoToken(testToken).owner(), alice);
    }

    /// @dev when creator proposes alice then reproposes bob, then alice cannot accept and bob can become owner
    function test_reproposeFromAliceToBob_assertOnlyBobCanAccept() public createTestToken {
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(bob);

        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        ILivoToken(testToken).acceptTokenOwnership();

        vm.prank(bob);
        ILivoToken(testToken).acceptTokenOwnership();

        assertEq(ILivoToken(testToken).owner(), bob);
    }

    /// @dev when creator proposes alice then cancels with `address(0)`, then alice cannot accept ownership
    function test_proposeThenCancel_assertAliceCannotAccept() public createTestToken {
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(address(0));

        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        ILivoToken(testToken).acceptTokenOwnership();

        assertEq(ILivoToken(testToken).owner(), creator);
    }

    /// @dev when creator transfers to alice and alice later transfers to bob, then final `owner()` returns bob
    function test_transferToAliceThenBob_assertGetTokenOwnerMatchesFinalAcceptedOwner() public createTestToken {
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);

        vm.prank(alice);
        ILivoToken(testToken).acceptTokenOwnership();
        assertEq(ILivoToken(testToken).owner(), alice);

        vm.prank(alice);
        ILivoToken(testToken).proposeNewOwner(bob);

        vm.prank(bob);
        ILivoToken(testToken).acceptTokenOwnership();

        assertEq(ILivoToken(testToken).owner(), bob);
    }

    /// @dev test only the current tokenOwner can propose a new wner
    function test_onlyCurrentOwnerCanPropose() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        ILivoToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);
    }
}
