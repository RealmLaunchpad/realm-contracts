// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator, LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "./base.t.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {Vm} from "forge-std/Vm.sol";
import {LivoFactoryBase} from "src/tokenFactories/LivoFactoryBase.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";

contract LivoTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployLivoToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = factoryV2.createToken("TestToken", "TEST", creator, "0x12");

        assertTrue(deployedToken != address(0));

        LivoToken token = LivoToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV2));

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(token.owner(), creator);
        assertApproxEqRel(config.bondingCurve.ethGraduationThreshold(), GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

    function test_cannotInitializeImplementation() public {
        LivoToken imp = new LivoToken();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        imp.initialize(
            ILivoToken.InitializeParams({
                name: "ImplToken",
                symbol: "IMPL",
                tokenOwner: msg.sender,
                graduator: address(graduatorV2),
                pair: address(0),
                launchpad: address(this),
                feeHandler: address(feeHandler),
                feeReceiver: msg.sender
            })
        );
    }

    function testTokenCreatedHasDifferentAddressThanImplementation() public {
        vm.prank(creator);
        address deployedToken = factoryV2.createToken("Sanitator", "SANIT", creator, "0x12");

        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(livoToken));
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryBase.InvalidNameOrSymbol.selector));
        factoryV2.createToken("", "TEST", creator, "0x12");
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryBase.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", "", creator, "0x0");
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        vm.prank(creator);
        address token1 = factoryV2.createToken("TestToken1", "TEST", creator, "0x12");

        vm.prank(creator);
        address token2 = factoryV2.createToken("TestToken2", "TEST", creator, "0x12342");

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(LivoToken(token1).symbol(), "TEST");
        assertEq(LivoToken(token2).symbol(), "TEST");
        assertEq(LivoToken(token1).name(), "TestToken1");
        assertEq(LivoToken(token2).name(), "TestToken2");
    }

    function testCanCreateTokensWithDifferentSymbols() public {
        vm.prank(creator);
        address token1 = factoryV2.createToken("TestToken1", "TEST1", creator, "0x0");

        vm.prank(creator);
        address token2 = factoryV2.createToken("TestToken2", "TEST2", creator, "0x12");

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(LivoToken(token1).symbol(), "TEST1");
        assertEq(LivoToken(token2).symbol(), "TEST2");
    }

    function test_cantCreateTokenWithTooLongSymbol() public {
        string memory longSymbol = "TESTTESTTESTTESTTESTTESTTESTESESD";
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryBase.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", longSymbol, creator, "0x12");
    }

    function test_cannotCreateTokenWithZeroOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryBase.InvalidTokenOwner.selector));
        factoryV2.createToken("TestToken", "TEST", address(0), "0x12");
    }
}

contract LivoTaxableTokenEventTests is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function test_LivoTaxableTokenInitialized_emittedOnCreation() public {
        vm.expectEmit(true, true, true, true);
        emit LivoTaxableTokenUniV4.LivoTaxableTokenInitialized(0, 500, 14 days);

        vm.prank(creator);
        address deployedToken = factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));

        assertTrue(deployedToken != address(0));
    }

    function test_LaunchpadDoesNotEmitTokenCreated_eventRemoved() public {
        vm.recordLogs();

        vm.prank(creator);
        address deployedToken = factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(logs.length > 0);

        bytes32 tokenCreatedSig = keccak256("TokenCreated(address,address,string,string,address,address,address)");
        bytes32 taxInitSig = keccak256("LivoTaxableTokenInitialized(uint16,uint16,uint40)");

        uint256 tokenCreatedIndex = type(uint256).max;
        uint256 taxInitIndex = type(uint256).max;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == tokenCreatedSig) {
                tokenCreatedIndex = i;
            } else if (logs[i].topics[0] == taxInitSig) {
                taxInitIndex = i;
            }
        }

        assertTrue(tokenCreatedIndex == type(uint256).max, "TokenCreated should not be emitted by launchpad");
        assertTrue(taxInitIndex != type(uint256).max, "LivoTaxableTokenInitialized event not found");

        assertTrue(deployedToken != address(0));
    }
}
