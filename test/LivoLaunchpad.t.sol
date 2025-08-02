// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/LivoLaunchpad.sol";
import "../src/LinearBondingCurve.sol";
import "../src/LivoToken.sol";

contract LivoLaunchpadTest is Test {
    LivoLaunchpad public launchpad;
    LinearBondingCurve public bondingCurve;
    address public treasury;
    address public creator;
    address public buyer;
    
    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        buyer = makeAddr("buyer");
        
        launchpad = new LivoLaunchpad(treasury);
        bondingCurve = new LinearBondingCurve();
        
        // Whitelist bonding curve
        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        
        // Give ETH to test accounts
        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
    }
    
    function testCreateToken() public {
        vm.prank(creator);
        address token = launchpad.createToken(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            address(bondingCurve)
        );
        
        assertTrue(token != address(0));
        
        LivoToken livoToken = LivoToken(token);
        assertEq(livoToken.name(), "TestToken");
        assertEq(livoToken.symbol(), "TEST");
        assertEq(livoToken.creator(), creator);
        assertEq(livoToken.factory(), address(launchpad));
    }
    
    function testBuyToken() public {
        // Create token
        vm.prank(creator);
        address token = launchpad.createToken(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            address(bondingCurve)
        );
        
        // Buy tokens
        uint256 ethAmount = 1 ether;
        uint256 expectedTokens = launchpad.getBuyPrice(token, ethAmount);
        
        uint256 balanceBefore = LivoToken(token).balanceOf(buyer);
        
        vm.prank(buyer);
        launchpad.buyToken{value: ethAmount}(token);
        
        uint256 balanceAfter = LivoToken(token).balanceOf(buyer);
        assertEq(balanceAfter - balanceBefore, expectedTokens);
    }
    
    function testSellToken() public {
        // Create token and buy some first
        vm.prank(creator);
        address token = launchpad.createToken(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            address(bondingCurve)
        );
        
        // Buy tokens
        uint256 ethAmount = 1 ether;
        vm.prank(buyer);
        launchpad.buyToken{value: ethAmount}(token);
        
        uint256 tokenBalance = LivoToken(token).balanceOf(buyer);
        uint256 sellAmount = tokenBalance / 2;
        
        // Approve launchpad to spend tokens
        vm.prank(buyer);
        LivoToken(token).approve(address(launchpad), sellAmount);
        
        uint256 expectedEth = launchpad.getSellPrice(token, sellAmount);
        uint256 ethBefore = buyer.balance;
        
        vm.prank(buyer);
        launchpad.sellToken(token, sellAmount);
        
        uint256 ethAfter = buyer.balance;
        assertApproxEqRel(ethAfter - ethBefore, expectedEth, 0.01e18); // 1% tolerance
    }
    
    function test_RevertWhen_CreateTokenWithInvalidBondingCurve() public {
        address invalidCurve = makeAddr("invalidCurve");
        
        vm.prank(creator);
        vm.expectRevert("LivoLaunchpad: Invalid bonding curve");
        launchpad.createToken(
            "TestToken",
            "TEST",
            "ipfs://metadata",
            invalidCurve
        );
    }
}