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
        launchpad.setLivoTokenImplementation(newImplementation);
    }

    function test_setLivoTokenImplementation_SucceedsForOwner() public {
        IERC20 newImplementation = new LivoToken();

        vm.expectEmit(true, true, true, true);
        emit TokenImplementationUpdated(newImplementation);

        launchpad.setLivoTokenImplementation(newImplementation);

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

        launchpad.setTradingFees(newBuyFee, newSellFee);

        assertEq(launchpad.baseBuyFeeBps(), newBuyFee);
        assertEq(launchpad.baseSellFeeBps(), newSellFee);
    }

    function test_setTradingFees_FailsForInvalidBuyFee() public {
        uint16 invalidBuyFee = 10001; // > 100%
        uint16 validSellFee = 250;

        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidBuyFee));
        launchpad.setTradingFees(invalidBuyFee, validSellFee);
    }

    function test_setTradingFees_FailsForInvalidSellFee() public {
        uint16 validBuyFee = 200;
        uint16 invalidSellFee = 10001; // > 100%

        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidSellFee));
        launchpad.setTradingFees(validBuyFee, invalidSellFee);
    }

    // whitelistBondingCurve Tests
    function test_whitelistBondingCurve_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.whitelistBondingCurve(newBondingCurve, true);
    }

    function test_whitelistBondingCurve_SucceedsForOwner() public {
        vm.expectEmit(true, true, true, true);
        emit BondingCurveWhitelisted(newBondingCurve, true);

        launchpad.whitelistBondingCurve(newBondingCurve, true);

        assertTrue(launchpad.whitelistedBondingCurves(newBondingCurve));

        // Test blacklisting
        vm.expectEmit(true, true, true, true);
        emit BondingCurveWhitelisted(newBondingCurve, false);

        launchpad.whitelistBondingCurve(newBondingCurve, false);

        assertFalse(launchpad.whitelistedBondingCurves(newBondingCurve));
    }

    // whitelistGraduator Tests
    function test_whitelistGraduator_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.whitelistGraduator(newGraduator, true);
    }

    function test_whitelistGraduator_SucceedsForOwner() public {
        vm.expectEmit(true, true, true, true);
        emit GraduatorWhitelisted(newGraduator, true);

        launchpad.whitelistGraduator(newGraduator, true);

        assertTrue(launchpad.whitelistedGraduators(newGraduator));

        // Test blacklisting
        vm.expectEmit(true, true, true, true);
        emit GraduatorWhitelisted(newGraduator, false);

        launchpad.whitelistGraduator(newGraduator, false);

        assertFalse(launchpad.whitelistedGraduators(newGraduator));
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

        launchpad.setTreasuryAddress(newTreasury);

        assertEq(launchpad.treasury(), newTreasury);
    }

    // collectTreasuryFees Tests
    function test_collectTreasuryFees_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
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

            launchpad.collectTreasuryFees();

            assertEq(launchpad.treasuryEthFeesCollected(), 0);
            assertEq(treasury.balance, initialTreasuryBalance + feesCollected);
        }
    }

    function test_collectTreasuryFees_NoFeesToCollect() public {
        // When there are no fees, function should succeed but do nothing
        uint256 initialTreasuryBalance = treasury.balance;

        launchpad.collectTreasuryFees();

        assertEq(launchpad.treasuryEthFeesCollected(), 0);
        assertEq(treasury.balance, initialTreasuryBalance);
    }

    // Events from the contract - needed for expectEmit
    event TokenImplementationUpdated(IERC20 newImplementation);
    event EthGraduationThresholdUpdated(uint256 newThreshold);
    event GraduationFeeUpdated(uint256 newGraduationFee);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event BondingCurveWhitelisted(address indexed bondingCurve, bool whitelisted);
    event GraduatorWhitelisted(address indexed graduator, bool whitelisted);
    event TreasuryAddressUpdated(address newTreasury);
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);
}
