// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithDirectV4} from "test/launchpad/base.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract TokenOwnershipTransferTests is LaunchpadBaseTestsWithDirectV4 {
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

    //////////////////////// protocol admin (fee handler owner) on renounced direct tokens ////////////////////////

    /// @dev A direct-venue token (no launchpad) deployed with `renounceOwnership = true`.
    function _renouncedDirect(bool taxable) internal returns (address token) {
        token = _createDirectTokenAs(
            creator,
            "Renounced",
            "RNC",
            _fs(creator),
            true,
            taxable ? _taxCfg(400, 400, uint32(4 days)) : _emptyTaxCfg()
        );
        assertEq(IRealmToken(token).owner(), address(0));
        assertEq(address(RealmToken(token).launchpad()), address(0));
        assertEq(feeHandler.owner(), admin);
    }

    /// @dev when a direct token renounced ownership, then the fee handler owner can still hand it to a new owner
    function test_adminTakeover_renouncedDirectToken_proposeAndAccept() public {
        address token = _renouncedDirect(false);

        vm.expectEmit(token);
        emit IRealmToken.NewOwnerProposed(address(0), alice, admin);
        vm.prank(admin);
        IRealmToken(token).proposeNewOwner(alice);

        vm.prank(alice);
        IRealmToken(token).acceptTokenOwnership();
        assertEq(IRealmToken(token).owner(), alice);
    }

    /// @dev when a direct token renounced ownership, then nobody but the admin can propose
    function test_adminTakeover_renouncedDirectToken_nonAdminReverts() public {
        address token = _renouncedDirect(false);

        vm.prank(creator);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        IRealmToken(token).proposeNewOwner(alice);
    }

    /// @dev when the token has an owner, then the admin can still override it with a takeover proposal
    function test_adminTakeover_ownedDirectToken_adminCanPropose() public {
        address token = _createDirectToken(_emptyTaxCfg());
        assertEq(IRealmToken(token).owner(), creator);

        vm.prank(admin);
        IRealmToken(token).proposeNewOwner(alice);
        assertEq(IRealmToken(token).proposedOwner(), alice);
    }

    /// @dev when a taxable direct token renounced ownership, then the admin can still lower its tax
    function test_adminSetTaxBps_renouncedDirectToken() public {
        address token = _renouncedDirect(true);

        vm.prank(admin);
        RealmTaxableToken(payable(token)).setTaxBps(100, 200);
        assertEq(RealmTaxableToken(payable(token)).buyTaxBps(), 100);
        assertEq(RealmTaxableToken(payable(token)).sellTaxBps(), 200);
    }

    /// @dev when a taxable direct token renounced ownership, then the admin can rescue stray ERC20s to itself
    function test_adminRescueTokens_renouncedDirectToken_paysAdmin() public {
        address token = _renouncedDirect(true);
        ERC20Mock stray = new ERC20Mock();
        stray.mint(token, 1e18);

        vm.prank(admin);
        RealmTaxableToken(payable(token)).rescueTokens(address(stray));
        assertEq(IERC20(address(stray)).balanceOf(admin), 1e18);
        assertEq(IERC20(address(stray)).balanceOf(token), 0);
    }
}
