// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract GraduatorAdminFunctionsTest is LaunchpadBaseTests {
    address public nonOwner = makeAddr("nonOwner");

    function setUp() public override {
        super.setUp();
        vm.deal(nonOwner, INITIAL_ETH_BALANCE);
    }

    function test_graduatorV2_whitelistFactory_FailsForNonOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        graduatorV2.whitelistFactory(newFactory);
    }

    function test_graduatorV2_blacklistFactory_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        graduatorV2.blacklistFactory(address(factoryV2));
    }

    function test_graduatorV2_whitelistFactory_SucceedsForOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        graduatorV2.whitelistFactory(newFactory);

        assertTrue(graduatorV2.whitelistedFactories(newFactory));
    }

    function test_graduatorV2_blacklistFactory_SucceedsForOwner() public {
        assertTrue(graduatorV2.whitelistedFactories(address(factoryV2)));

        vm.prank(admin);
        graduatorV2.blacklistFactory(address(factoryV2));

        assertFalse(graduatorV2.whitelistedFactories(address(factoryV2)));
    }

    function test_graduatorV4_whitelistFactory_FailsForNonOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        graduatorV4.whitelistFactory(newFactory);
    }

    function test_graduatorV4_blacklistFactory_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        graduatorV4.blacklistFactory(address(factoryV4));
    }

    function test_graduatorV4_whitelistFactory_SucceedsForOwner() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(admin);
        graduatorV4.whitelistFactory(newFactory);

        assertTrue(graduatorV4.whitelistedFactories(newFactory));
    }

    function test_graduatorV4_blacklistFactory_SucceedsForOwner() public {
        assertTrue(graduatorV4.whitelistedFactories(address(factoryV4)));

        vm.prank(admin);
        graduatorV4.blacklistFactory(address(factoryV4));

        assertFalse(graduatorV4.whitelistedFactories(address(factoryV4)));
    }
}
