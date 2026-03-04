// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv4GraduatorTaxableToken} from "test/launchpad/base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {FactoryWhitelisting} from "src/FactoryWhitelisting.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";

contract LivoFactoryTaxTokenDeploymentTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    address public deployedToken;

    // ============ Modifiers ============

    modifier withTaxTokenCreated(uint16 sellTaxBps, uint32 taxDuration) {
        vm.prank(creator);
        deployedToken = factoryTax.createToken("TestToken", "TEST", creator, "0x12", sellTaxBps, taxDuration);
        _;
    }

    // ============ Tax Validation ============

    /// @dev when sellTaxBps exceeds MAX_SELL_TAX_BPS, then createToken reverts with InvalidSellTaxBps
    function test_createToken_revertsOnSellTaxAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidSellTaxBps.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 501, uint32(14 days));
    }

    /// @dev when taxDurationSeconds exceeds MAX_SELL_TAX_DURATION_SECONDS, then createToken reverts with InvalidTaxDuration
    function test_createToken_revertsOnTaxDurationAboveMax() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(LivoFactoryTaxToken.InvalidTaxDuration.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days + 1));
    }

    /// @dev when sellTaxBps equals MAX_SELL_TAX_BPS, then createToken succeeds
    function test_createToken_assertMaxSellTaxAccepted()
        public
        withTaxTokenCreated(500, uint32(14 days))
    {
        assertTrue(deployedToken != address(0));
    }

    /// @dev when taxDurationSeconds equals MAX_SELL_TAX_DURATION_SECONDS, then createToken succeeds
    function test_createToken_assertMaxTaxDurationAccepted()
        public
        withTaxTokenCreated(100, uint32(14 days))
    {
        assertTrue(deployedToken != address(0));
    }

    /// @dev when sellTaxBps and taxDuration are zero, then createToken succeeds with no tax
    function test_createToken_assertZeroTaxAccepted()
        public
        withTaxTokenCreated(0, 0)
    {
        assertTrue(deployedToken != address(0));
    }

    // ============ Input Validation ============

    /// @dev when name is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptyName() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryTax.createToken("", "TEST", creator, "0x12", 500, uint32(14 days));
    }

    /// @dev when symbol is empty, then createToken reverts with InvalidNameOrSymbol
    function test_createToken_revertsOnEmptySymbol() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidNameOrSymbol.selector));
        factoryTax.createToken("TestToken", "", creator, "0x0", 500, uint32(14 days));
    }

    /// @dev when tokenOwner is zero address, then createToken reverts with InvalidTokenOwner
    function test_createToken_revertsOnZeroOwner() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ILivoFactory.InvalidTokenOwner.selector));
        factoryTax.createToken("TestToken", "TEST", address(0), "0x12", 500, uint32(14 days));
    }

    // ============ Events ============

    /// @dev when tax token is created, then LivoTaxableTokenInitialized event is emitted with correct params
    function test_createToken_emitsLivoTaxableTokenInitialized() public {
        vm.expectEmit(true, true, true, true);
        emit LivoTaxableTokenUniV4.LivoTaxableTokenInitialized(0, 500, 14 days);

        vm.prank(creator);
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));
    }

    /// @dev when tax token is created, then launchpad does not emit the old TokenCreated event
    function test_createToken_launchpadDoesNotEmitTokenCreated() public {
        vm.recordLogs();

        vm.prank(creator);
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0);

        bytes32 tokenCreatedSig = keccak256("TokenCreated(address,address,string,string,address,address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != tokenCreatedSig, "TokenCreated should not be emitted by launchpad");
        }
    }
}

contract LivoFactoryTaxTokenWhitelistTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    // ============ Modifiers ============

    modifier withBlacklistedFactory() {
        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryTax));
        _;
    }

    // ============ Whitelist / Blacklist Integration ============

    /// @dev when factory is whitelisted, then createToken succeeds
    function test_whitelistedFactory_canCreateToken() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(creator);
        address token = factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));
        assertTrue(token != address(0));
    }

    /// @dev when factory is blacklisted, then createToken reverts with UnauthorizedFactory
    function test_blacklistedFactory_cannotCreateToken() public withBlacklistedFactory {
        assertFalse(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FactoryWhitelisting.UnauthorizedFactory.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));
    }

    /// @dev when factory is whitelisted then blacklisted, then createToken reverts with UnauthorizedFactory
    function test_whitelistThenBlacklist_cannotCreateToken() public {
        assertTrue(launchpad.whitelistedFactories(address(factoryTax)));

        vm.prank(admin);
        launchpad.blacklistFactory(address(factoryTax));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FactoryWhitelisting.UnauthorizedFactory.selector));
        factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));
    }

    /// @dev when factory is blacklisted then re-whitelisted, then createToken succeeds again
    function test_blacklistThenRewhitelist_canCreateToken() public withBlacklistedFactory {
        vm.prank(admin);
        launchpad.whitelistFactory(address(factoryTax));

        vm.prank(creator);
        address token = factoryTax.createToken("TestToken", "TEST", creator, "0x12", 500, uint32(14 days));
        assertTrue(token != address(0));
    }

    /// @dev when non-owner calls whitelistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotWhitelistFactory() public {
        address newFactory = makeAddr("newFactory");

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.whitelistFactory(newFactory);
    }

    /// @dev when non-owner calls blacklistFactory, then it reverts with OwnableUnauthorizedAccount
    function test_nonOwner_cannotBlacklistFactory() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        launchpad.blacklistFactory(address(factoryTax));
    }
}
