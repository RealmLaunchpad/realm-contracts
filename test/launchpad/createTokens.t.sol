// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator, LaunchpadBaseTestsWithDirectV4} from "./base.t.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {TokenConfig, TokenState} from "src/types/tokenData.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmTaxableToken} from "src/tokens/RealmTaxableToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";

contract RealmTokenDeploymentTest is LaunchpadBaseTestsWithUniv2Graduator {
    function testDeployRealmToken_happyPath() public {
        vm.prank(creator);
        address deployedToken = factoryV2.createToken(
            _setupTiered("TestToken", "TEST", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("Sanitator", "SANIT", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertTrue(deployedToken != address(0));
        assertTrue(deployedToken != address(realmToken));
    }

    function testCannotCreateTokenWithEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken(
            _setupTiered("", "TEST", "0x12", _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function testCannotCreateTokenWithEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidNameOrSymbol.selector));
        factoryV2.createToken(
            _setupTiered("TestToken", "", "0x0", _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function testCannotCreateTokenWithWrongEnding() public {
        bytes32 correctSalt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTokenAddress.selector));
        factoryV2.createToken(
            _setupTiered("TestToken1", "TEST", bytes32(uint256(correctSalt) + 1), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        // with correct salt it should succeed
        factoryV2.createToken(
            _setupTiered("TestToken1", "TEST", correctSalt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        vm.stopPrank();
    }

    function testCanCreateTokenWithDuplicateSymbol() public {
        vm.prank(creator);
        address token1 = factoryV2.createToken(
            _setupTiered("TestToken1", "TEST", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        vm.prank(creator);
        address token2 = factoryV2.createToken(
            _setupTiered("TestToken2", "TEST", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken1", "TEST1", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        vm.prank(creator);
        address token2 = factoryV2.createToken(
            _setupTiered("TestToken2", "TEST2", _nextValidSalt(address(factoryV2), address(realmToken)), _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", longSymbol, "0x12", _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }
}

/// @notice Token creation on the direct V4 venue (the only V4 venue).
contract RealmTokenV4DeploymentTest is LaunchpadBaseTestsWithDirectV4 {
    function _create(RealmFactoryUniV4Direct.DirectTokenSetup memory setup, TaxConfigs memory tax)
        internal
        returns (address)
    {
        vm.prank(creator);
        return directFactory.createToken(
            setup, _nativePair(), _noDirectAlloc(tax), _emptyAntiSniperCfg(), _noVaults(), _noDevBuy(), address(0)
        );
    }

    /// @dev when feeReceiver is zero address, then createToken reverts with InvalidFeeReceiver
    function test_createToken_v4_revertsOnZeroFeeReceiver() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", false);
        setup.feeShares[0].account = address(0);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidFeeReceiver.selector));
        _create(setup, _emptyTaxCfg());
    }

    function test_createToken_v4_happyPath() public {
        address deployedToken = _create(_directSetup("TestToken", "TEST", false), _emptyTaxCfg());

        RealmToken token = RealmToken(deployedToken);
        assertEq(token.name(), "TestToken");
        assertEq(token.symbol(), "TEST");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.graduator(), address(directGraduator));
        assertEq(token.owner(), creator);
        assertEq(address(token.launchpad()), address(0), "direct venue has no launchpad");
        assertTrue(token.graduated(), "graduated in its creation tx");
    }

    /// @dev when renounceOwnership=true, then tokenOwner is set to address(0)
    function test_createToken_v4_renounceOwnership_setsOwnerToZero() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", false);
        setup.renounceOwnership = true;
        assertEq(RealmToken(_create(setup, _emptyTaxCfg())).owner(), address(0));
    }

    /// @dev when renounceOwnership=false, then tokenOwner is msg.sender
    function test_createToken_v4_keepOwnership_setsOwnerToCaller() public {
        assertEq(RealmToken(_create(_directSetup("TestToken", "TEST", false), _emptyTaxCfg())).owner(), creator);
    }

    function test_cannotCreateToken_sellTaxAboveMax() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", true);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxBps.selector));
        _create(setup, _taxCfg(0, 401, uint32(14 days)));
    }

    function test_cannotCreateToken_taxDurationAboveMax() public {
        // Duration above the 120-year overflow-prevention cap — must revert with InvalidTaxDuration.
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", true);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidTaxDuration.selector));
        _create(setup, _taxCfg(0, 400, uint32(120 * 365 days + 1)));
    }

    function test_RealmTaxableTokenInitialized_emittedOnCreation() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("TestToken", "TEST", true);
        vm.expectEmit(true, true, true, true);
        emit RealmTaxableToken.RealmTaxableTokenInitialized(0, 400, 14 days, true, 0, 0, 0);
        _create(setup, _taxCfg(0, 400, uint32(14 days)));
    }
}
