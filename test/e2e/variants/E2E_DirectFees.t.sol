// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {V4SwapHelpers} from "test/e2e/base/V4SwapHelpers.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice End-to-end coverage for direct fees: deploy a V4 token with a single direct receiver,
///         graduate, swap, and assert the receiver's wallet balance increased without ever calling
///         `claim()`.
contract E2E_DirectFees is V4SwapHelpers, LaunchpadBaseTestsWithUniv4Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv4Graduator) {
        super.setUp();
    }

    /// @dev Direct receiver auto-receives all creator fees (graduation + post-grad LP fees).
    function test_singleDirect_receiverGetsFeesWithoutClaiming() public {
        // alice is the direct receiver
        IRealmFactory.FeeShare[] memory fs = _fsDirect(alice);

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("DF", "DF", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg());

        // Singleton handler has alice as the direct receiver for this token
        assertTrue(feeHandler.isDirectReceiver(token, alice));

        uint256 aliceBefore = alice.balance;

        // Graduate via bonding curve buys
        testToken = token;
        _graduateToken();

        // Creator graduation compensation (0.125 ETH) plus the creator's share of the LP fee on the
        // graduating buy both forward directly to alice (the sole 100% direct receiver).
        uint256 missingForGraduation = (GRADUATION_THRESHOLD * 10_000) / (10_000 - BASE_BUY_FEE_BPS);
        uint256 tradingFee = (missingForGraduation * BASE_BUY_FEE_BPS) / 10_000;
        uint256 creatorTradingShare = tradingFee - _treasuryShareOf(tradingFee);
        assertEq(
            alice.balance - aliceBefore,
            CREATOR_GRADUATION_COMPENSATION + creatorTradingShare,
            "graduation fee forwarded directly"
        );

        // Post-graduation swap → hook charges 1% LP fee, half goes to creator (alice direct).
        uint256 aliceAfterGrad = alice.balance;
        // _launchpadBuy left buyer at 0 balance via vm.deal — refund for the post-grad swap.
        vm.deal(buyer, 1 ether);
        _swapBuyV4(buyer, token, 1 ether, 0, true);

        // alice should have received MORE eth — half of the 1% LP fee on a 1 ETH buy is 5e15 wei.
        assertGt(alice.balance - aliceAfterGrad, 0, "post-grad LP fee forwarded directly");
        // Sanity: alice never called claim and has no pending balance in the handler.
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        assertEq(feeHandler.getClaimable(tokens, alice)[0], 0, "no pending: all forwarded");
    }

    /// @dev Multi-recipient mode: alice (direct) receives her share immediately, bob (claimable) accrues.
    function test_multiRecipientDirect_aliceImmediateBobClaimable() public {
        // 40% direct to alice, 60% claimable to bob
        IRealmFactory.FeeShare[] memory fs = new IRealmFactory.FeeShare[](2);
        fs[0] = IRealmFactory.FeeShare({account: alice, shares: 4_000, directFeesEnabled: true});
        fs[1] = IRealmFactory.FeeShare({account: bob, shares: 6_000, directFeesEnabled: false});

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("DFS", "DFS", salt, fs, _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg());

        uint256 aliceBefore = alice.balance;

        testToken = token;
        _graduateToken();

        // Two creator deposits split 40/60: the graduation compensation and the creator's share of
        // the LP fee on the graduating buy. alice (direct) receives 40% of each immediately.
        uint256 missingForGraduation = (GRADUATION_THRESHOLD * 10_000) / (10_000 - BASE_BUY_FEE_BPS);
        uint256 tradingFee = (missingForGraduation * BASE_BUY_FEE_BPS) / 10_000;
        uint256 creatorTradingShare = tradingFee - _treasuryShareOf(tradingFee);

        // alice gets 40% of each creator deposit directly (floored per deposit)
        uint256 expectedAlice =
            (CREATOR_GRADUATION_COMPENSATION * 4_000) / 10_000 + (creatorTradingShare * 4_000) / 10_000;
        assertEq(alice.balance - aliceBefore, expectedAlice, "alice direct portion");

        // bob's pending in the master handler is the remaining 60% of both deposits
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256 bobClaimable = feeHandler.getClaimable(tokens, bob)[0];
        uint256 expectedBob =
            (CREATOR_GRADUATION_COMPENSATION * 6_000) / 10_000 + (creatorTradingShare * 6_000) / 10_000;
        assertApproxEqAbs(bobClaimable, expectedBob, 2, "bob claimable portion");
    }
}
