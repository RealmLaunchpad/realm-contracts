// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {DummyConstantPriceCurve} from "src/bondingCurves/DummyConstantPriceCurve.sol";
import {LivoGraduatorUniV2} from "src/graduators/LivoGraduatorUniV2.sol";
import {LivoToken} from "src/LivoToken.sol";

contract LivoLaunchpadTest is Test {
    LivoLaunchpad public launchpad;
    DummyConstantPriceCurve public bondingCurve;
    LivoGraduatorUniV2 public graduator;
    LivoToken public tokenImplementation;
    address public treasury;
    address public creator;
    address public buyer;

    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");

        // Deploy token implementation
        tokenImplementation = new LivoToken();

        // Deploy launchpad with treasury and token implementation
        launchpad = new LivoLaunchpad(treasury, tokenImplementation);

        // Deploy bonding curve and graduator
        bondingCurve = new DummyConstantPriceCurve();
        graduator = new LivoGraduatorUniV2(address(0), address(launchpad)); // Using address(0) for router as it's not used in tests

        // Whitelist bonding curve and graduator
        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        launchpad.whitelistGraduator(address(graduator), true);

        // Give ETH to test accounts
        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function testCreateToken() public {
        vm.prank(creator);
        address token =
            launchpad.createToken("TestToken", "TEST", "ipfs://metadata", address(bondingCurve), address(graduator));
        assertTrue(token != address(0));
        LivoToken livoToken = LivoToken(token);
        assertEq(livoToken.name(), "TestToken");
        assertEq(livoToken.symbol(), "TEST");
        assertEq(livoToken.creator(), creator);
        assertEq(livoToken.launchpad(), address(launchpad));
    }

    function testBuyToken() public {
        // Create token
        vm.prank(creator);
        address token =
            launchpad.createToken("TestToken", "TEST", "ipfs://metadata", address(bondingCurve), address(graduator));
        // Buy tokens
        uint256 ethAmount = 1 ether;
        (,, uint256 expectedTokens) = launchpad.quoteBuy(token, ethAmount);
        uint256 balanceBefore = LivoToken(token).balanceOf(buyer);
        vm.prank(buyer);
        launchpad.buyToken{value: ethAmount}(token, expectedTokens, block.timestamp + 1 hours);
        uint256 balanceAfter = LivoToken(token).balanceOf(buyer);
        assertEq(balanceAfter - balanceBefore, expectedTokens);
    }

    function testSellToken() public {
        // Create token and buy some first
        vm.prank(creator);
        address token =
            launchpad.createToken("TestToken", "TEST", "ipfs://metadata", address(bondingCurve), address(graduator));
        // Buy tokens
        uint256 ethAmount = 1 ether;
        vm.prank(buyer);
        launchpad.buyToken{value: ethAmount}(token, 0, block.timestamp + 1 hours);
        uint256 tokenBalance = LivoToken(token).balanceOf(buyer);
        uint256 sellAmount = tokenBalance / 2;
        // Approve launchpad to spend tokens
        vm.prank(buyer);
        LivoToken(token).approve(address(launchpad), sellAmount);
        (,, uint256 expectedEth) = launchpad.quoteSell(token, sellAmount);
        uint256 ethBefore = buyer.balance;
        vm.prank(buyer);
        launchpad.sellToken(token, sellAmount, expectedEth, block.timestamp + 1 hours);
        uint256 ethAfter = buyer.balance;
        assertApproxEqRel(ethAfter - ethBefore, expectedEth, 0.01e18); // 1% tolerance
    }

    function test_RevertWhen_CreateTokenWithInvalidBondingCurve() public {
        address invalidCurve = makeAddr("invalidCurve");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidBondingCurve.selector));
        launchpad.createToken("TestToken", "TEST", "ipfs://metadata", invalidCurve, address(graduator));
    }

    function testCreateTokenWithDuplicateSymbols() public {
        // Create first token with symbol "TEST"
        vm.prank(creator);
        address token1 =
            launchpad.createToken("FirstToken", "TEST", "ipfs://metadata1", address(bondingCurve), address(graduator));

        // Create second token with same symbol "TEST" - should succeed
        vm.prank(creator);
        address token2 =
            launchpad.createToken("SecondToken", "TEST", "ipfs://metadata2", address(bondingCurve), address(graduator));

        // Verify both tokens exist and have the same symbol but different addresses
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);
        assertEq(LivoToken(token1).symbol(), "TEST");
        assertEq(LivoToken(token2).symbol(), "TEST");
        assertEq(LivoToken(token1).name(), "FirstToken");
        assertEq(LivoToken(token2).name(), "SecondToken");
    }
}
