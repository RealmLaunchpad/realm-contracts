// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {LivoToken} from "src/LivoToken.sol";

contract AdminFunctionsTest is LaunchpadBaseTestsWithUniv2Graduator {
    address public nonOwner = makeAddr("nonOwner");
    address public newTreasury = makeAddr("newTreasury");
    address public newBondingCurve = makeAddr("newBondingCurve");
    address public newGraduator = makeAddr("newGraduator");

    function setUp() public override {
        super.setUp();
        vm.deal(nonOwner, INITIAL_ETH_BALANCE);
    }

    // setLivoTokenImplementation Tests
    function test_setLivoTokenImplementation_FailsForNonOwner() public {
        IERC20 newImplementation = new LivoToken();

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setLivoTokenImplementation(address(newImplementation));
    }

    function test_setLivoTokenImplementation_SucceedsForOwner() public {
        IERC20 newImplementation = new LivoToken();

        vm.expectEmit(true, true, true, true);
        emit TokenImplementationUpdated(address(newImplementation));

        vm.prank(admin);
        launchpad.setLivoTokenImplementation(address(newImplementation));

        assertEq(address(launchpad.tokenImplementation()), address(newImplementation));
    }

    // setEthGraduationThreshold Tests
    function test_setEthGraduationThreshold_FailsForNonOwner() public {
        uint256 newThreshold = 10 ether;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setEthGraduationThreshold(newThreshold);
    }

    function test_setEthGraduationThreshold_SucceedsForOwner() public {
        uint256 newThreshold = 10 ether;

        vm.expectEmit(true, true, true, true);
        emit EthGraduationThresholdUpdated(newThreshold);

        vm.prank(admin);
        launchpad.setEthGraduationThreshold(newThreshold);

        assertEq(launchpad.baseEthGraduationThreshold(), newThreshold);
    }

    // setGraduationFee Tests
    function test_setGraduationFee_FailsForNonOwner() public {
        uint256 newFee = 1 ether;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setGraduationFee(newFee);
    }

    function test_setGraduationFee_SucceedsForOwner() public {
        uint256 newFee = 1 ether;

        vm.expectEmit(true, true, true, true);
        emit GraduationFeeUpdated(newFee);

        vm.prank(admin);
        launchpad.setGraduationFee(newFee);

        assertEq(launchpad.baseGraduationFee(), newFee);
    }

    // setTradingFees Tests
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
        uint16 invalidBuyFee = 10001; // > 100%
        uint16 validSellFee = 250;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidBuyFee));
        launchpad.setTradingFees(invalidBuyFee, validSellFee);
    }

    function test_setTradingFees_FailsForInvalidSellFee() public {
        uint16 validBuyFee = 200;
        uint16 invalidSellFee = 10001; // > 100%

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidSellFee));
        launchpad.setTradingFees(validBuyFee, invalidSellFee);
    }

    // whitelistBondingCurve Tests
    function test_whitelisting_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.whitelistCurveAndGraduator(address(bondingCurve), address(graduator), true);
    }

    function test_whitelisting_SucceedsForOwner() public {
        vm.expectEmit(false, false, false, true);
        emit CurveAndGraduatorWhitelistedSet(newBondingCurve, newGraduator, true);
        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(newBondingCurve, newGraduator, true);

        assertTrue(launchpad.whitelistedComponents(newBondingCurve, newGraduator));

        // Test blacklisting
        vm.expectEmit(false, false, false, true);
        emit CurveAndGraduatorWhitelistedSet(newBondingCurve, newGraduator, false);

        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(newBondingCurve, newGraduator, false);

        assertFalse(launchpad.whitelistedComponents(newBondingCurve, newGraduator));
    }

    function test_whitelistCurveAndGraduator_GivesFalseFor_wCurve_notGraduator() public {
        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(newBondingCurve, newGraduator, true);

        assertFalse(launchpad.whitelistedComponents(address(bondingCurve), newGraduator));
    }

    function test_whitelistCurveAndGraduator_GivesFalseFor_notCurve_wGraduator() public {
        vm.prank(admin);
        launchpad.whitelistCurveAndGraduator(newBondingCurve, newGraduator, true);

        assertFalse(launchpad.whitelistedComponents(newBondingCurve, address(graduator)));
    }

    // setTreasuryAddress Tests
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

    // collectTreasuryFees Tests
    function test_collectTreasuryFees_nonOwnerCanClaim() public {
        vm.prank(nonOwner);
        launchpad.collectTreasuryFees();
    }

    function test_collectTreasuryFees_SucceedsForOwner() public createTestToken {
        // First, generate some fees by doing a buy transaction
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, block.timestamp + 1);

        uint256 initialTreasuryBalance = treasury.balance;
        uint256 feesCollected = launchpad.treasuryEthFeesCollected();

        // Only proceed if there are fees to collect
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
        // Start ownership transfer
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        // Accept ownership from new owner
        vm.prank(nonOwner);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), nonOwner);
        assertEq(launchpad.pendingOwner(), address(0));
    }

    function test_transferOwnership_cancelled() public {
        // Start ownership transfer
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        // original owner can still do owner functions
        vm.prank(admin);
        launchpad.setEthGraduationThreshold(9 ether);

        // Cancel ownership transfer by setting pending owner to zero address
        vm.prank(admin);
        launchpad.transferOwnership(address(0));
        assertEq(launchpad.pendingOwner(), address(0));
        assertEq(launchpad.owner(), admin);

        // original owner can still do owner functions
        vm.prank(admin);
        launchpad.setEthGraduationThreshold(10 ether);
    }

    function test_collectTreasuryFees_NoFeesToCollect() public {
        // When there are no fees, function should succeed but do nothing
        uint256 initialTreasuryBalance = treasury.balance;

        vm.prank(admin);
        launchpad.collectTreasuryFees();

        assertEq(launchpad.treasuryEthFeesCollected(), 0);
        assertEq(treasury.balance, initialTreasuryBalance);
    }

    // Events from the contract - needed for expectEmit
    event TokenImplementationUpdated(address newImplementation);
    event EthGraduationThresholdUpdated(uint256 newThreshold);
    event GraduationFeeUpdated(uint256 newGraduationFee);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event CurveAndGraduatorWhitelistedSet(address bondingCurve, address graduator, bool whitelisted);
    event TreasuryAddressUpdated(address newTreasury);
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);
}
