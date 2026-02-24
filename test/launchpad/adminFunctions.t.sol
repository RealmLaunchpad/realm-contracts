// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoToken} from "src/tokens/LivoToken.sol";
import {ConstantProductBondingCurve} from "src/bondingCurves/ConstantProductBondingCurve.sol";
import {LivoGraduatorUniswapV2} from "src/graduators/LivoGraduatorUniswapV2.sol";
import {TokenConfig} from "src/types/tokenData.sol";

contract AdminFunctionsTest is LaunchpadBaseTestsWithUniv2Graduator {
    address public nonOwner = makeAddr("nonOwner");
    address public newTreasury = makeAddr("newTreasury");
    address public newBondingCurve = makeAddr("newBondingCurve");
    address public newGraduator = makeAddr("newGraduator");

    function setUp() public override {
        super.setUp();
        vm.deal(nonOwner, INITIAL_ETH_BALANCE);
    }

    // setTradingFees Tests
    function test_setTradingFees_FailsForNonOwner() public {
        uint16 newBuyFee = 200;
        uint16 newSellFee = 250;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setTradingFees(newBuyFee, newSellFee);
    }

    function test_setTradingFees_SucceedsForOwner() public {
        uint16 newBuyFee = 200;
        uint16 newSellFee = 250;

        vm.expectEmit(true, true, true, true);
        emit TradingFeesUpdated(newBuyFee, newSellFee);

        vm.prank(admin);
        launchpad.setTradingFees(newBuyFee, newSellFee);

        assertEq(launchpad.baseBuyFeeBps(), newBuyFee);
        assertEq(launchpad.baseSellFeeBps(), newSellFee);
    }

    function test_setTradingFees_FailsForInvalidBuyFee() public {
        uint16 invalidBuyFee = 10001; // > 100%
        uint16 validSellFee = 250;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidBuyFee));
        launchpad.setTradingFees(invalidBuyFee, validSellFee);
    }

    function test_setTradingFees_FailsForInvalidSellFee() public {
        uint16 validBuyFee = 200;
        uint16 invalidSellFee = 10001; // > 100%

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", invalidSellFee));
        launchpad.setTradingFees(validBuyFee, invalidSellFee);
    }

    // whitelistBondingCurve Tests
    function test_whitelisting_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.whitelistComponents(
            address(implementation),
            address(bondingCurve),
            address(graduator),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS
        );
    }

    function test_whitelistComponentsZeroEthGraduationThreshold() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(uint256)", 0));
        launchpad.whitelistComponents(
            address(implementation), address(bondingCurve), address(graduator), 0, MAX_THRESHOLD_EXCESS
        );
    }

    function test_whitelistAlreadyWhitelistedCombination() public {
        assertTrue(launchpad.isSetWhitelisted(address(implementation), address(bondingCurve), address(graduator)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AlreadyConfigured()"));
        launchpad.whitelistComponents(
            address(implementation),
            address(bondingCurve),
            address(graduator),
            GRADUATION_THRESHOLD,
            MAX_THRESHOLD_EXCESS
        );
    }

    function test_blacklistNonWhitelistedComponents() public {
        assertTrue(launchpad.isSetWhitelisted(address(implementation), address(bondingCurve), address(graduator)));

        vm.prank(admin);
        launchpad.blacklistComponents(address(implementation), address(bondingCurve), address(graduator));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted()"));
        launchpad.blacklistComponents(address(implementation), address(bondingCurve), address(graduator));

        // also should revert if trying to blacklist something that was never whitelisted
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("AlreadyBlacklisted()"));
        launchpad.blacklistComponents(address(0), address(0), address(0));
    }

    function test_whitelisting_SucceedsForOwner() public {
        vm.expectEmit(false, false, false, true);
        emit ComponentsSetWhitelisted(
            address(implementation), newBondingCurve, newGraduator, GRADUATION_THRESHOLD, MAX_THRESHOLD_EXCESS
        );
        vm.prank(admin);
        launchpad.whitelistComponents(
            address(implementation), newBondingCurve, newGraduator, GRADUATION_THRESHOLD, MAX_THRESHOLD_EXCESS
        );

        assertTrue(launchpad.isSetWhitelisted(address(implementation), newBondingCurve, newGraduator));
    }

    function test_blacklisting_SucceedsForOwner() public {
        vm.prank(admin);
        launchpad.whitelistComponents(
            address(implementation), newBondingCurve, newGraduator, GRADUATION_THRESHOLD, MAX_THRESHOLD_EXCESS
        );

        // Test blacklisting
        vm.expectEmit(false, false, false, true);
        emit ComponentsSetBlacklisted(address(implementation), newBondingCurve, newGraduator);

        vm.prank(admin);
        launchpad.blacklistComponents(address(implementation), newBondingCurve, newGraduator);

        assertFalse(launchpad.isSetWhitelisted(address(implementation), newBondingCurve, newGraduator));
    }

    function test_whitelistCurveAndGraduator_GivesFalseFor_wCurve_notGraduator() public {
        vm.prank(admin);
        launchpad.whitelistComponents(
            address(implementation), newBondingCurve, newGraduator, GRADUATION_THRESHOLD, MAX_THRESHOLD_EXCESS
        );

        assertFalse(launchpad.isSetWhitelisted(address(implementation), address(bondingCurve), newGraduator));
    }

    function test_whitelistCurveAndGraduator_GivesFalseFor_notCurve_wGraduator() public {
        vm.prank(admin);
        launchpad.whitelistComponents(
            address(implementation), newBondingCurve, newGraduator, GRADUATION_THRESHOLD, MAX_THRESHOLD_EXCESS
        );

        assertFalse(launchpad.isSetWhitelisted(address(implementation), newBondingCurve, address(graduator)));
    }

    // setTreasuryAddress Tests
    function test_setTreasuryAddress_FailsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        launchpad.setTreasuryAddress(newTreasury);
    }

    function test_setTreasuryAddress_SucceedsForOwner() public {
        vm.expectEmit(true, true, true, true);
        emit TreasuryAddressUpdated(newTreasury);

        vm.prank(admin);
        launchpad.setTreasuryAddress(newTreasury);

        assertEq(launchpad.treasury(), newTreasury);
    }

    // collectTreasuryFees Tests
    function test_collectTreasuryFees_nonOwnerCanClaim() public {
        vm.prank(nonOwner);
        launchpad.collectTreasuryFees();
    }

    function test_collectTreasuryFees_SucceedsForOwner() public createTestToken {
        // First, generate some fees by doing a buy transaction
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(testToken, 0, block.timestamp + 1);

        uint256 initialTreasuryBalance = treasury.balance;
        uint256 feesCollected = launchpad.treasuryEthFeesCollected();

        // Only proceed if there are fees to collect
        if (feesCollected > 0) {
            vm.expectEmit(true, true, true, true);
            emit TreasuryFeesCollected(treasury, feesCollected);

            vm.prank(admin);
            launchpad.collectTreasuryFees();

            assertEq(launchpad.treasuryEthFeesCollected(), 0);
            assertEq(treasury.balance, initialTreasuryBalance + feesCollected);
        }
    }

    function test_transferOwnership2step() public {
        // Start ownership transfer
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        // Accept ownership from new owner
        vm.prank(nonOwner);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), nonOwner);
        assertEq(launchpad.pendingOwner(), address(0));
    }

    function test_transferOwnership_cancelled() public {
        // Start ownership transfer
        vm.prank(admin);
        launchpad.transferOwnership(nonOwner);
        assertEq(launchpad.pendingOwner(), nonOwner);

        // original owner can still do owner functions
        vm.prank(admin);
        launchpad.setTreasuryAddress(address(0x12345));

        // Cancel ownership transfer by setting pending owner to zero address
        vm.prank(admin);
        launchpad.transferOwnership(address(0));
        assertEq(launchpad.pendingOwner(), address(0));
        assertEq(launchpad.owner(), admin);

        // original owner can still do owner functions
        vm.prank(admin);
        launchpad.setTreasuryAddress(address(0x1223432345));
    }

    function test_collectTreasuryFees_NoFeesToCollect() public {
        // When there are no fees, function should succeed but do nothing
        uint256 initialTreasuryBalance = treasury.balance;

        vm.prank(admin);
        launchpad.collectTreasuryFees();

        assertEq(launchpad.treasuryEthFeesCollected(), 0);
        assertEq(treasury.balance, initialTreasuryBalance);
    }

    // Events from the contract - needed for expectEmit
    event TokenImplementationUpdated(address newImplementation);
    event EthGraduationThresholdUpdated(uint256 newThreshold);
    event GraduationFeeUpdated(uint256 newGraduationFee);
    event TradingFeesUpdated(uint16 buyFeeBps, uint16 sellFeeBps);
    event ComponentsSetWhitelisted(
        address implementation,
        address bondingCurve,
        address graduator,
        uint256 ethGraduationThreshold,
        uint256 maxExcessOverThreshold
    );
    event ComponentsSetBlacklisted(address implementation, address bondingCurve, address graduator);
    event TreasuryAddressUpdated(address newTreasury);
    event TreasuryFeesCollected(address indexed treasury, uint256 amount);

    function test_readTokenOwnerInvalidToken() public {
        vm.expectRevert(LivoLaunchpad.InvalidToken.selector);
        launchpad.getTokenOwner(address(0));
    }

    error OwnableUnauthorizedAccount(address caller);

    function test_communityTakeOver_onlyOwnerAllowed() public createTestToken {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, creator));
        launchpad.communityTakeOver(testToken, alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        // ownership not yet transferred — alice must accept
        assertEq(launchpad.getTokenOwner(testToken), creator);

        vm.prank(alice);
        launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), alice);
    }

    event TokenOwnerProposed(address indexed token, address indexed currentOwner, address indexed proposedOwner);
    event TokenOwnerUpdated(address indexed token, address indexed newOwner);

    // ─── proposeTokenOwner ───────────────────────────────────────────────

    function test_proposeTokenOwner_byCurrentOwner_setsProposedOwner() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, alice);
    }

    function test_proposeTokenOwner_emitsTokenOwnerProposed() public createTestToken {
        vm.expectEmit(true, true, true, true);
        emit TokenOwnerProposed(testToken, creator, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);
    }

    function test_proposeTokenOwner_revertsIfNotCurrentOwner() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.proposeTokenOwner(testToken, alice);
    }

    function test_proposeTokenOwner_revertsIfInvalidToken() public {
        vm.prank(creator);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.proposeTokenOwner(address(0x1234), alice);
    }

    function test_proposeTokenOwner_withZeroAddress_cancelsProposal() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, address(0));

        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, address(0));
    }

    // ─── acceptTokenOwnership ────────────────────────────────────────────

    function test_acceptTokenOwnership_happyPath_setsOwnerAndClearsProposed() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.expectEmit(true, true, true, true);
        emit TokenOwnerUpdated(testToken, alice);

        vm.prank(alice);
        launchpad.acceptTokenOwnership(testToken);

        assertEq(launchpad.getTokenOwner(testToken), alice);
        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, address(0));
    }

    function test_acceptTokenOwnership_revertsIfNotProposedOwner() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(nonOwner);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.acceptTokenOwnership(testToken);
    }

    function test_acceptTokenOwnership_revertsIfNoProposalPending() public createTestToken {
        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.acceptTokenOwnership(testToken);
    }

    function test_acceptTokenOwnership_revertsIfInvalidToken() public {
        vm.prank(alice);
        vm.expectRevert(LivoLaunchpad.InvalidTokenOwner.selector);
        launchpad.acceptTokenOwnership(address(0x1234));
    }

    // ─── communityTakeOver (new two-step behaviour) ───────────────────────

    function test_communityTakeOver_nowProposes_doesNotDirectlyTransfer() public createTestToken {
        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        assertEq(launchpad.getTokenOwner(testToken), creator, "ownership should not change before accept");
    }

    function test_communityTakeOver_overridesPendingOwnerProposal() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, nonOwner);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, alice);

        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, alice, "admin takeover should override pending proposal");
    }

    function test_communityTakeOver_revertsIfInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert(LivoLaunchpad.InvalidToken.selector);
        launchpad.communityTakeOver(address(0x1234), alice);
    }

    // ─── edge cases ───────────────────────────────────────────────────────

    function test_ownerCanRepropose_whenProposalPending() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, nonOwner);

        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, nonOwner, "second proposal should override first");
    }

    function test_adminCanOverrideOwnerProposal() public createTestToken {
        vm.prank(creator);
        launchpad.proposeTokenOwner(testToken, alice);

        vm.prank(admin);
        launchpad.communityTakeOver(testToken, nonOwner);

        TokenConfig memory config = launchpad.getTokenConfig(testToken);
        assertEq(config.proposedOwner, nonOwner, "admin takeover should override owner proposal");
    }

    function test_createCustomToken_onlyOwnerAllowed() public {
        LivoToken otherImplementation = new LivoToken();
        ConstantProductBondingCurve otherBondingCurve = new ConstantProductBondingCurve();
        LivoGraduatorUniswapV2 otherGraduator = new LivoGraduatorUniswapV2(UNISWAP_V2_ROUTER, address(launchpad));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, alice));
        launchpad.createCustomToken(
            "CustomToken",
            "CTK",
            address(otherImplementation),
            address(otherBondingCurve),
            address(otherGraduator),
            alice,
            0,
            "",
            LivoLaunchpad.ThresholdSettings({
                ethGraduationThreshold: GRADUATION_THRESHOLD, maxExcessOverThreshold: MAX_THRESHOLD_EXCESS
            })
        );

        // the owner can create a weird components combination without restrictions
        vm.prank(admin);
        launchpad.createCustomToken(
            "CustomToken",
            "CTK",
            address(otherImplementation),
            address(otherBondingCurve),
            address(otherGraduator),
            alice,
            0,
            "",
            LivoLaunchpad.ThresholdSettings({
                ethGraduationThreshold: GRADUATION_THRESHOLD, maxExcessOverThreshold: MAX_THRESHOLD_EXCESS
            })
        );
    }
}
