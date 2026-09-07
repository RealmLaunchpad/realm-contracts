// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";

contract AdminFunctionsTest is LaunchpadBaseTestsWithUniv4Graduator {
    address public nonOwner = makeAddr("nonOwner");
    address public newTreasury = makeAddr("newTreasury");

    function setUp() public override {
        super.setUp();
        vm.deal(nonOwner, INITIAL_ETH_BALANCE);
    }

    function test_whitelistFactory_FailsForNonOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.whitelistFactory(newFactory);
    }

    function test_whitelistFactory_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        launchpad.whitelistFactory(address(0));
    }

    function test_whitelistFactory_AlreadyWhitelisted() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryV2)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AlreadyConfigured()"));
        launchpad.whitelistFactory(address(factoryV2));
    }

    function test_whitelistFactory_SucceedsForOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.expectEmit(true, true, true, true);
        emit FactoryWhitelisted(newFactory);

        vm.prank(admin);
        launchpad.whitelistFactory(newFactory);

        assertTrue(launchpad.whitelistedFactories(newFactory));
    }

    function test_blacklistFactory_FailsForNonWhitelisted() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedFactory()"));
        launchpad.blacklistFactory(newFactory);
    }

    function test_blacklistFactory_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.blacklistFactory(address(factoryV2));
    }

    function test_blacklistFactory_Succeeds() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryV2)));

        vm.expectEmit(true, true, true, true);
        emit FactoryBlacklisted(address(factoryV2));

        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryV2));

        assertFalse(launchpad.whitelistedFactories(address(factoryV2)));
    }

    function test_setTreasuryAddress_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setTreasuryAddress(newTreasury);
    }

    function test_setTreasuryAddress_SucceedsForOwner() public {
        vm.expectEmit(true, true, true, true);
        emit TreasuryAddressUpdated(newTreasury);

        vm.prank(admin);
        launchpad.setTreasuryAddress(newTreasury);

        assertEq(launchpad.treasury(), newTreasury);
    }

    function test_setTreasuryAddress_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        launchpad.setTreasuryAddress(address(0));
    }

    function test_transferOwnership2step() public {
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        vm.prank(nonOwner);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), nonOwner);
        assertEq(launchpad.pendingOwner(), address(0));
    }

    function test_transferOwnership_cancelled() public {
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        vm.prank(admin);
        launchpad.setTreasuryAddress(address(0x12345));

        vm.prank(admin);
        launchpad.transferOwnership(address(0));
        assertEq(launchpad.pendingOwner(), address(0));
        assertEq(launchpad.owner(), admin);

        vm.prank(admin);
        launchpad.setTreasuryAddress(address(0x1223432345));
    }

    function test_communityTakeOver_revertsForNonOwner() public createTestToken {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.communityTakeOver(testToken, alice);

        assertEq(IRealmToken(testToken).proposedOwner(), address(0));
    }

    function test_communityTakeOver_routesToTokenProposeNewOwner() public createTestToken {
        vm.prank(creator);
        IRealmToken(testToken).proposeNewOwner(alice);
        assertEq(IRealmToken(testToken).proposedOwner(), alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, bob);

        assertEq(IRealmToken(testToken).proposedOwner(), bob);

        vm.prank(bob);
        IRealmToken(testToken).acceptTokenOwnership();
        assertEq(IRealmToken(testToken).owner(), bob);
    }

    event FactoryWhitelisted(address indexed factory);
    event FactoryBlacklisted(address indexed factory);
    event TreasuryAddressUpdated(address newTreasury);

    error OwnableUnauthorizedAccount(address caller);

    event NewOwnerProposed(address owner, address proposedOwner);
    event OwnershipTransferred(address newOwner);

    function test_tokenOwnershipTransfer_happyPath_reflectedInLaunchpad() public createTestToken {
        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);

        vm.prank(alice);
        RealmToken(testToken).acceptTokenOwnership();

        assertEq(IRealmToken(testToken).owner(), alice);
    }

    function test_tokenOwnershipTransfer_setsAndClearsProposedOwner() public createTestToken {
        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);
        assertEq(RealmToken(testToken).proposedOwner(), alice);

        vm.prank(alice);
        RealmToken(testToken).acceptTokenOwnership();
        assertEq(RealmToken(testToken).proposedOwner(), address(0));
    }

    function test_tokenOwnershipTransfer_emitsTokenEvents() public createTestToken {
        vm.expectEmit(true, true, true, true);
        emit IRealmToken.NewOwnerProposed(creator, alice, creator);

        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(alice);

        vm.prank(alice);
        RealmToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_revertsIfNotCurrentOwner() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        RealmToken(testToken).proposeNewOwner(alice);
    }

    function test_tokenOwnershipTransfer_revertsIfNotProposedOwner() public createTestToken {
        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);

        vm.prank(nonOwner);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        RealmToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_cancelProposalWithZeroAddress() public createTestToken {
        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(address(0));

        assertEq(RealmToken(testToken).proposedOwner(), address(0));

        vm.prank(alice);
        vm.expectRevert(RealmToken.Unauthorized.selector);
        RealmToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_ownerCanRepropose() public createTestToken {
        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        RealmToken(testToken).proposeNewOwner(nonOwner);

        assertEq(RealmToken(testToken).proposedOwner(), nonOwner);
    }
}
