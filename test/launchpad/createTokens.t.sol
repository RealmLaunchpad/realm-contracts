// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "./base.t.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

contract RealmTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployRealmToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = factoryV2.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        assertTrue(deployedToken != address(0));

        RealmToken token = RealmToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV2));

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertEq(token.owner(), address(0));
        assertApproxEqRel(config.bondingCurve.getGraduationConfig().ethGraduationThreshold, GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);

        assertEq(token.balanceOf(address(launchpad)), token.totalSupply());
    }

    function test_cannotInitializeImplementation() public {
        RealmToken imp = new RealmToken();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        imp.initialize(
            IRealmToken.InitializeParams({
                name: "ImplToken",
                symbol: "IMPL",
                tokenOwner: msg.sender,
                graduator: address(graduatorV2),
                launchpad: address(this),
                feeHandler: address(feeHandler),
                vaultAllocation: 0,
                lpFeeBps: 100,
                treasuryShareBps: 10_000,
                swapLpFeeBps: 0
            }),
            _emptyAntiSniperCfg()
        );
    }

    function testTokenCreatedHasDifferentAddressThanImplementation() public {
        vm.prank(creator);
        address deployedToken = factoryV2.createToken(
            "Sanitator",
            "SANIT",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(realmToken));
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("", "TEST", "0x12", _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken("TestToken", "", "0x0", _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function testCannotCreateTokenWithWrongEnding() public {
        bytes32 correctSalt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTokenAddress.selector));
        factoryV2.createToken(
            "TestToken1",
            "TEST",
            bytes32(uint256(correctSalt) + 1),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        // with correct salt it should succeed
        factoryV2.createToken(
            "TestToken1", "TEST", correctSalt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
        vm.stopPrank();
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        vm.prank(creator);
        address token1 = factoryV2.createToken(
            "TestToken1",
            "TEST",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        vm.prank(creator);
        address token2 = factoryV2.createToken(
            "TestToken2",
            "TEST",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(RealmToken(token1).symbol(), "TEST");
        assertEq(RealmToken(token2).symbol(), "TEST");
        assertEq(RealmToken(token1).name(), "TestToken1");
        assertEq(RealmToken(token2).name(), "TestToken2");
    }

    function testCanCreateTokensWithDifferentSymbols() public {
        vm.prank(creator);
        address token1 = factoryV2.createToken(
            "TestToken1",
            "TEST1",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        vm.prank(creator);
        address token2 = factoryV2.createToken(
            "TestToken2",
            "TEST2",
            _nextValidSalt(address(factoryV2), address(realmToken)),
            _fs(creator),
            _noSs(),
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        assertTrue(token1 != address(0));
        assertTrue(token2 != address(0));
        assertTrue(token1 != token2);

        assertEq(RealmToken(token1).symbol(), "TEST1");
        assertEq(RealmToken(token2).symbol(), "TEST2");
    }

    function test_cantCreateTokenWithTooLongSymbol() public {
        string memory longSymbol =
            "TESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTX";
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken(
            "TestToken", longSymbol, "0x12", _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }
}

contract RealmTokenV4DeploymentTest is LaunchpadBaseTestsWithUniv4Graduator {
    /// @dev when feeReceiver is zero address, then createToken reverts with InvalidFeeReceiver
    function test_createToken_v4_revertsOnZeroFeeReceiver() public {
        IRealmFactory.FeeShare[] memory zeroFs = new IRealmFactory.FeeShare[](1);
        zeroFs[0] = IRealmFactory.FeeShare({account: address(0), shares: 10_000, directFeesEnabled: false});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidFeeReceiver.selector));
        factoryV4.createToken(
            "TestToken", "TEST", "0x12", zeroFs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_v4_happyPath() public {
        vm.prank(creator);
        address deployedToken = factoryV4.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV4), address(realmToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );

        assertTrue(deployedToken != address(0));

        RealmToken token = RealmToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(address(launchpad)), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(graduatorV4));
        assertEq(token.owner(), creator);

        TokenConfig memory config = launchpad.getTokenConfig(deployedToken);
        assertEq(address(config.bondingCurve), address(bondingCurve));
        assertApproxEqRel(config.bondingCurve.getGraduationConfig().ethGraduationThreshold, GRADUATION_THRESHOLD, 1e10);

        TokenState memory state = launchpad.getTokenState(deployedToken);
        assertEq(state.ethCollected, 0);
        assertEq(state.graduated, false);
    }

    /// @dev when renounceOwnership=true, then tokenOwner is set to address(0)
    function test_createToken_v4_renounceOwnership_setsOwnerToZero() public {
        vm.prank(creator);
        address deployedToken = factoryV4.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV4), address(realmToken)),
            _fs(creator),
            _noSs(),
            true,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        assertEq(RealmToken(deployedToken).owner(), address(0));
    }

    /// @dev when renounceOwnership=false, then tokenOwner is msg.sender
    function test_createToken_v4_keepOwnership_setsOwnerToCaller() public {
        vm.prank(creator);
        address deployedToken = factoryV4.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryV4), address(realmToken)),
            _fs(creator),
            _noSs(),
            false,
            _emptyTaxCfg(),
            _emptyAntiSniperCfg()
        );
        assertEq(RealmToken(deployedToken).owner(), creator);
    }
}

contract RealmTaxableTokenValidationTests is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function test_cannotCreateToken_sellTaxAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxBps.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            "0x12",
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 401, uint32(14 days)),
            _emptyAntiSniperCfg()
        );
    }

    function test_cannotCreateToken_taxDurationAboveMax() public {
        // Duration above the 120-year overflow-prevention cap — must revert with InvalidTaxDuration.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxDuration.selector));
        factoryTax.createToken(
            "TestToken",
            "TEST",
            "0x12",
            _fs(alice),
            _noSs(),
            true,
            _taxCfg(0, 400, uint32(120 * 365 days + 1)),
            _emptyAntiSniperCfg()
        );
    }
}

contract RealmTaxableTokenEventTests is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    function test_RealmTaxableTokenInitialized_emittedOnCreation() public {
        vm.expectEmit(true, true, true, true);
        emit RealmTaxableToken.RealmTaxableTokenInitialized(0, 400, 14 days, true, 0, 0, 0);

        vm.prank(creator);
        address deployedToken = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        assertTrue(deployedToken != address(0));
    }

    function test_LaunchpadDoesNotEmitTokenCreated_eventRemoved() public {
        vm.recordLogs();

        vm.prank(creator);
        address deployedToken = factoryTax.createToken(
            "TestToken",
            "TEST",
            _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(logs.length > 0);

        bytes32 tokenCreatedSig = keccak256("TokenCreated(address,address,string,string,address,address,address)");
        bytes32 taxInitSig = keccak256("RealmTaxableTokenInitialized(uint16,uint16,uint40,bool,uint16,uint16,uint40)");

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
        assertTrue(taxInitIndex != type(uint256).max, "RealmTaxableTokenInitialized event not found");

        assertTrue(deployedToken != address(0));
    }
}
