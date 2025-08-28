// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {DummyLinearBondingCurve} from "src/bondingCurves/DummyLinearBondingCurve.sol";
import {LivoGraduatorUniV2} from "src/graduators/LivoGraduatorUniV2.sol";
import {LivoToken} from "src/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

contract LivoTokenDeploymentTest is Test {
    LivoLaunchpad public launchpad;
    DummyLinearBondingCurve public bondingCurve;
    LivoGraduatorUniV2 public graduator;
    LivoToken public tokenImplementation;

    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");

    // review question are these mainnet addresses?

    address public constant uniswapRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); // Uniswap V2 Router
    address public constant uniswapFactory = address(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f); // Uniswap V2 Factory

    function setUp() public {
        // Deploy token implementation
        tokenImplementation = new LivoToken();

        // Deploy launchpad
        launchpad = new LivoLaunchpad(treasury, tokenImplementation);

        // Deploy bonding curve and graduator
        bondingCurve = new DummyLinearBondingCurve();
        graduator = new LivoGraduatorUniV2(uniswapRouter, address(launchpad));

        // Whitelist bonding curve and graduator
        launchpad.whitelistBondingCurve(address(bondingCurve), true);
        launchpad.whitelistGraduator(address(graduator), true);

        // Give ETH to creator
        vm.deal(creator, 100 ether);
    }

    function testDeployLivoToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = launchpad.createToken(
            "TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );

        // Verify token was deployed
        assertTrue(deployedToken != address(0));

        // Verify token properties
        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.creator(), creator);
        assertEq(token.launchpad(), address(launchpad));
        assertEq(token.totalSupply(), 1_000_000_000e18);

        // Verify token config was stored correctly
        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(address(config.graduator), address(graduator));
        assertEq(config.creator, creator);
        assertEq(config.graduationEthFee, 0.5 ether);
        assertEq(config.ethForGraduationLiquidity, 7.5 ether);

        // Verify token state was initialized correctly
        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        // Verify all tokens are held by launchpad initially
        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

    function testCannotCreateTokenWithInvalidBondingCurve() public {
        address invalidCurve = makeAddr("invalidCurve");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidBondingCurve.selector));
        launchpad.createToken("TestToken", "TEST", "ipfs://test-metadata", invalidCurve, address(graduator));
    }

    function testCannotCreateTokenWithInvalidGraduator() public {
        address invalidGraduator = makeAddr("invalidGraduator");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidGraduator.selector));
        launchpad.createToken("TestToken", "TEST", "ipfs://test-metadata", address(bondingCurve), invalidGraduator);
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken("", "TEST", "ipfs://test-metadata", address(bondingCurve), address(graduator));
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken("TestToken", "", "ipfs://test-metadata", address(bondingCurve), address(graduator));
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        // Create first token with symbol "TEST"
        vm.prank(creator);
        address token1 = launchpad.createToken(
            "TestToken1", "TEST", "ipfs://test-metadata1", address(bondingCurve), address(graduator)
        );

        // Create second token with same symbol - should succeed now
        vm.prank(creator);
        address token2 = launchpad.createToken(
            "TestToken2", "TEST", "ipfs://test-metadata2", address(bondingCurve), address(graduator)
        );

        // Both should be deployed successfully
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        // Verify both have the same symbol but different names
        assertEq(LivoToken(token1).symbol(), "TEST");
        assertEq(LivoToken(token2).symbol(), "TEST");
        assertEq(LivoToken(token1).name(), "TestToken1");
        assertEq(LivoToken(token2).name(), "TestToken2");
    }

    function testCanCreateTokensWithDifferentSymbols() public {
        // Create first token
        vm.prank(creator);
        address token1 = launchpad.createToken(
            "TestToken1", "TEST1", "ipfs://test-metadata1", address(bondingCurve), address(graduator)
        );

        // Create second token with different symbol
        vm.prank(creator);
        address token2 = launchpad.createToken(
            "TestToken2", "TEST2", "ipfs://test-metadata2", address(bondingCurve), address(graduator)
        );

        // Both should be deployed successfully
        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        // Verify symbols are different
        assertEq(LivoToken(token1).symbol(), "TEST1");
        assertEq(LivoToken(token2).symbol(), "TEST2");
    }
}
