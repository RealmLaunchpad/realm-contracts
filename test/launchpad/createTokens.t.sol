// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";

contract LivoTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployLivoToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );

        // Verify token was deployed
        assertTrue(deployedToken != address(0));

        // Verify token properties
        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduator));

        // Verify token config was stored correctly
        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(address(config.graduator), address(graduator));
        assertEq(config.tokenOwner, creator);
        assertEq(config.graduationEthFee, GRADUATION_FEE);
        assertApproxEqRel(config.ethGraduationThreshold, GRADUATION_THRESHOLD, 1e10);

        // Verify token state was initialized correctly
        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        // Verify all tokens are held by launchpad initially
        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

    function test_cannotInitializeImplementation() public {
        LivoToken imp = new LivoToken();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        imp.initialize("ImplToken", "IMPL", address(graduator), address(0), address(this), 1234);
    }

    function testTokenCreatedHasDifferentAddressThanImplementation() public {
        vm.prank(creator);
        address deployedToken = launchpad.createToken(
            "Sanitator", "SANIT", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );

        // Verify token was deployed
        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(implementation));
    }

    function testCannotCreateTokenWith_InvalidCrurve_ValidGraduator() public {
        address invalidCurve = makeAddr("invalidCurve");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.NotWhitelistedComponents.selector));
        launchpad.createToken("TestToken", "TEST", address(implementation), invalidCurve, address(graduator), creator, "0x12");
    }

    function testCannotCreateTokenWith_InvalidGraduator_ValidCurve() public {
        address invalidCurve = makeAddr("invalidCurve");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.NotWhitelistedComponents.selector));
        launchpad.createToken("TestToken", "TEST", address(implementation), invalidCurve, address(graduator), creator, "0x12");
    }

    function testCannotCreateTokenWith_blaklistedComponents() public {
        // this should succeed
        vm.prank(creator);
        launchpad.createToken(
            "Sanitator", "SANIT", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );

        vm.prank(admin);
        launchpad.blacklistComponents(address(implementation), address(bondingCurve), address(graduator));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.NotWhitelistedComponents.selector));
        launchpad.createToken(
            "TestToken", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken("", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12");
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoLaunchpad.InvalidNameOrSymbol.selector));
        launchpad.createToken(
            "TestToken", "", address(implementation), address(bondingCurve), address(graduator), creator, "0x0"
        );
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        // Create first token with symbol "TEST"
        vm.prank(creator);
        address token1 = launchpad.createToken(
            "TestToken1", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );

        // Create second token with same symbol - should succeed now
        vm.prank(creator);
        address token2 = launchpad.createToken(
            "TestToken2", "TEST", address(implementation), address(bondingCurve), address(graduator), creator, "0x12342"
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
            "TestToken1", "TEST1", address(implementation), address(bondingCurve), address(graduator), creator, "0x0"
        );

        // Create second token with different symbol
        vm.prank(creator);
        address token2 = launchpad.createToken(
            "TestToken2", "TEST2", address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
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
            "TestToken", longSymbol, address(implementation), address(bondingCurve), address(graduator), creator, "0x12"
        );
    }
}
