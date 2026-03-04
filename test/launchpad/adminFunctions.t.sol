// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";

contract AdminFunctionsTest is LaunchpadBaseTestsWithUniv2Graduator {
    address public nonOwner = makeAddr("nonOwner");
    address public newTreasury = makeAddr("newTreasury");

    function setUp() public override {
        super.setUp();
        vm.deal(nonOwner, INITIAL_ETH_BALANCE);
    }

    function test_setTradingFees_FailsForNonOwner() public {
        uint16 newBuyFee = 200;
        uint16 newSellFee = 250;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setTradingFees(newBuyFee, newSellFee);
    }

    function test_setTradingFees_SucceedsForOwner() public {
        uint16 newBuyFee = 200;
        uint16 newSellFee = 250;

        vm.expectEmit(true, true, true, true);
        emit TradingFeesUpdated(newBuyFee, newSellFee);

        vm.prank(admin);
        launchpad.setTradingFees(newBuyFee, newSellFee);

        assertEq(launchpad.baseBuyFeeBps(), newBuyFee);
        assertEq(launchpad.baseSellFeeBps(), newSellFee);
    }

    function test_setTradingFees_FailsForInvalidBuyFee() public {
        uint16 invalidBuyFee = 10001;
        uint16 validSellFee = 250;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidBuyFee));
        launchpad.setTradingFees(invalidBuyFee, validSellFee);
    }

    function test_setTradingFees_FailsForInvalidSellFee() public {
        uint16 validBuyFee = 200;
        uint16 invalidSellFee = 10001;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidSellFee));
        launchpad.setTradingFees(validBuyFee, invalidSellFee);
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

    function test_collectTreasuryFees_nonOwnerCanClaim() public {
        vm.prank(nonOwner);
        launchpad.collectTreasuryFees();
    }

    function test_collectTreasuryFees_SucceedsForOwner() public createTestToken {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, block.timestamp + 1);

        uint256 initialTreasuryBalance = treasury.balance;
        uint256 feesCollected = launchpad.treasuryEthFeesCollected();

        if (feesCollected > 0) {
            vm.expectEmit(true, true, true, true);
            emit TreasuryFeesCollected(treasury, feesCollected);

            vm.prank(admin);
            launchpad.collectTreasuryFees();

            assertEq(launchpad.treasuryEthFeesCollected(), 0);
            assertEq(treasury.balance, initialTreasuryBalance + feesCollected);
        }
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

    function test_collectTreasuryFees_NoFeesToCollect() public {
        uint256 initialTreasuryBalance = treasury.balance;

        vm.prank(admin);
        launchpad.collectTreasuryFees();

        assertEq(launchpad.treasuryEthFeesCollected(), 0);
        assertEq(treasury.balance, initialTreasuryBalance);
    }

    function test_communityTakeOver_revertsForNonOwner() public createTestToken {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.communityTakeOver(testToken, alice);

        assertEq(ILivoToken(testToken).proposedOwner(), address(0));
    }

    function test_communityTakeOver_routesToTokenProposeNewOwner() public createTestToken {
        vm.prank(creator);
        ILivoToken(testToken).proposeNewOwner(alice);
        assertEq(ILivoToken(testToken).proposedOwner(), alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, bob);

        assertEq(ILivoToken(testToken).proposedOwner(), bob);

        vm.prank(bob);
        ILivoToken(testToken).acceptTokenOwnership();
        assertEq(ILivoToken(testToken).owner(), bob);
    }

    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event FactoryWhitelisted(address indexed factory);
    event FactoryBlacklisted(address indexed factory);
    event TreasuryAddressUpdated(address newTreasury);
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);

    error OwnableUnauthorizedAccount(address caller);

    event NewOwnerProposed(address owner, address proposedOwner);
    event OwnershipTransferred(address newOwner);

    function test_tokenOwnershipTransfer_happyPath_reflectedInLaunchpad() public createTestToken {
        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);

        vm.prank(alice);
        LivoToken(testToken).acceptTokenOwnership();

        assertEq(ILivoToken(testToken).owner(), alice);
    }

    function test_tokenOwnershipTransfer_setsAndClearsProposedOwner() public createTestToken {
        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);
        assertEq(LivoToken(testToken).proposedOwner(), alice);

        vm.prank(alice);
        LivoToken(testToken).acceptTokenOwnership();
        assertEq(LivoToken(testToken).proposedOwner(), address(0));
    }

    function test_tokenOwnershipTransfer_emitsTokenEvents() public createTestToken {
        vm.expectEmit(true, true, true, true);
        emit ILivoToken.NewOwnerProposed(creator, alice, creator);

        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(alice);

        vm.prank(alice);
        LivoToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_revertsIfNotCurrentOwner() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        LivoToken(testToken).proposeNewOwner(alice);
    }

    function test_tokenOwnershipTransfer_revertsIfNotProposedOwner() public createTestToken {
        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);

        vm.prank(nonOwner);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        LivoToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_cancelProposalWithZeroAddress() public createTestToken {
        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(address(0));

        assertEq(LivoToken(testToken).proposedOwner(), address(0));

        vm.prank(alice);
        vm.expectRevert(LivoToken.Unauthorized.selector);
        LivoToken(testToken).acceptTokenOwnership();
    }

    function test_tokenOwnershipTransfer_ownerCanRepropose() public createTestToken {
        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(alice);

        vm.prank(creator);
        LivoToken(testToken).proposeNewOwner(nonOwner);

        assertEq(LivoToken(testToken).proposedOwner(), nonOwner);
    }
}
