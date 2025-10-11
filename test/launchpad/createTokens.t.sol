// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

contract LivoTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployLivoToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = launchpad.createToken("TestToken", "TEST", address(bondingCurve), address(graduator));

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
        address deployedToken = launchpad.createToken("Sanitator", "SANIT", address(bondingCurve), address(graduator));

        // Verify token was deployed
        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(launchpad.tokenImplementation()));
    }

    function testCannotCreateTokenWith_InvalidCrurve_ValidGraduator() public {
        address invalidCurve = makeAddr("invalidCurve");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidCurveGraduatorCombination.selector));
        launchpad.createToken("TestToken", "TEST", invalidCurve, address(graduator));
    }

    function testCannotCreateTokenWith_InvalidGraduator_ValidCurve() public {
        address invalidCurve = makeAddr("invalidCurve");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidCurveGraduatorCombination.selector));
        launchpad.createToken("TestToken", "TEST", address(bondingCurve), invalidCurve);
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken("", "TEST", address(bondingCurve), address(graduator));
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken("TestToken", "", address(bondingCurve), address(graduator));
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        // Create first token with symbol "TEST"
        vm.prank(creator);
        address token1 = launchpad.createToken("TestToken1", "TEST", address(bondingCurve), address(graduator));

        // Create second token with same symbol - should succeed now
        vm.prank(creator);
        address token2 = launchpad.createToken("TestToken2", "TEST", address(bondingCurve), address(graduator));

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
        address token1 = launchpad.createToken("TestToken1", "TEST1", address(bondingCurve), address(graduator));

        // Create second token with different symbol
        vm.prank(creator);
        address token2 = launchpad.createToken("TestToken2", "TEST2", address(bondingCurve), address(graduator));

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
        launchpad.createToken("TestToken", longSymbol, address(bondingCurve), address(graduator));
    }
}
