// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4} from "test/launchpad/base.t.sol";
import {V4SwapHelpers} from "test/e2e/base/V4SwapHelpers.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice End-to-end coverage for direct fees: launch a direct V4 token with a direct receiver, swap,
///         and assert the receiver's wallet balance increased without ever calling `claim()`. The direct
///         venue has no graduation fee, so the creator's LP-fee share is the only creator income.
contract E2E_DirectFees is V4SwapHelpers, LaunchpadBaseTestsWithDirectV4 {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {
        super.setUp();
    }

    function _createTestToken() internal override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {
        LaunchpadBaseTestsWithDirectV4._createTestToken();
    }

    function _graduateToken() internal override(LaunchpadBaseTests, LaunchpadBaseTestsWithDirectV4) {}

    /// @dev Direct receiver auto-receives the creator share of every post-launch LP fee.
    function test_singleDirect_receiverGetsFeesWithoutClaiming() public {
        address token = _createDirectToken(_emptyTaxCfg(), _fsDirect(alice));
        assertTrue(feeHandler.isDirectReceiver(token, alice));

        uint256 aliceBefore = alice.balance;
        vm.deal(buyer, 1 ether);
        _swapBuyV4(buyer, token, 1 ether, 0, true);

        assertGt(alice.balance - aliceBefore, 0, "post-launch LP fee forwarded directly");
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
        address token = _createDirectToken(_emptyTaxCfg(), fs);

        uint256 aliceBefore = alice.balance;
        vm.deal(buyer, 1 ether);
        _swapBuyV4(buyer, token, 1 ether, 0, true);

        uint256 aliceGot = alice.balance - aliceBefore;
        assertGt(aliceGot, 0, "alice direct portion");

        // bob's pending in the master handler is the remaining 60%: 1.5x alice's 40%.
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        assertApproxEqAbs(feeHandler.getClaimable(tokens, bob)[0], aliceGot * 3 / 2, 2, "bob claimable portion");
    }
}
