// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTest} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

contract LivoTokenDeploymentTest is LaunchpadBaseTest {
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
        assertEq(token.launchpad(), address(launchpad));
        assertEq(token.totalSupply(), TOTAL_SUPPLY);

        // Verify token config was stored correctly
        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(address(config.graduator), address(graduator));
        assertEq(config.creator, creator);
        assertEq(config.graduationEthFee, BASE_GRADUATION_FEE);
        assertApproxEqRel(config.ethGraduationThreshold, BASE_GRADUATION_THRESHOLD, 1e10);

        // Verify token state was initialized correctly
        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        // Verify all tokens are held by launchpad initially
        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

    function testTokenCreatedHasDifferentAddressThanImplementation() public {
        vm.prank(creator);
        address deployedToken = launchpad.createToken(
            "Sanitator", "SANIT", "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );

        // Verify token was deployed
        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(launchpad.tokenImplementation()));
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

    function test_cantCreateTokenWithTooLongSymbol() public {
        string memory longSymbol = "TESTTESTTESTTESTTESTTESTTESTESESD"; // 33 characters
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken(
            "TestToken", longSymbol, "ipfs://test-metadata", address(bondingCurve), address(graduator)
        );
    }
}
