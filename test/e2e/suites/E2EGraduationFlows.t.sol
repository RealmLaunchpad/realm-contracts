// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmE2EBase} from "test/e2e/base/RealmE2EBase.t.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice E2E graduation flows. Drives a token from creation, through bonding curve buys, into
///         graduation, then exercises a post-graduation swap on the appropriate AMM (V2 pair or
///         V4 pool depending on the variant's graduator).
abstract contract E2EGraduationFlows is RealmE2EBase {
    function test_e2e_graduates_via_launchpad_buy() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        // Reuse the inherited graduation helper, which sizes the buy to push reserves over the
        // graduation threshold from whatever they currently are.
        _graduateE2E(token);

        assertTrue(launchpad.getTokenState(token).graduated, "launchpad must mark token graduated");
        assertTrue(IRealmToken(token).graduated(), "token must mark itself graduated");
    }

    function test_e2e_postGrad_swap_buy_returnsTokens() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateE2E(token);

        // Move past any tax/sniper window so the post-grad swap happens in steady state. Sniper
        // is bypassed by `graduated == true` regardless, but this keeps the assertions clean.
        if (_hasTax()) _warpPastTaxWindow(token);

        uint256 balBefore = IERC20(token).balanceOf(alice);
        vm.deal(alice, 1 ether);
        _swapBuyAuto(alice, token, 0.1 ether, 0);
        uint256 balAfter = IERC20(token).balanceOf(alice);

        assertGt(balAfter, balBefore, "post-grad swap should deliver tokens");
    }

    function test_e2e_postGrad_swap_sell_returnsEth() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateE2E(token);

        if (_hasTax()) _warpPastTaxWindow(token);

        // First buy some tokens to sell back.
        vm.deal(alice, 1 ether);
        _swapBuyAuto(alice, token, 0.5 ether, 0);
        uint256 tokenBal = IERC20(token).balanceOf(alice);
        assertGt(tokenBal, 0, "alice must hold tokens before selling");

        uint256 sellAmount = tokenBal / 2;
        uint256 ethReceived = _swapSellAuto(alice, token, sellAmount, 0);
        assertGt(ethReceived, 0, "post-grad sell should deliver ETH");
    }

    function test_e2e_creator_canClaimFees_afterGraduation() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);
        _graduateE2E(token);

        // Creator should have non-zero claimable from the graduation creator fee
        // (CREATOR_GRADUATION_COMPENSATION = 0.125 ether for both V2 and V4).
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256 ethBefore = creator.balance;
        vm.prank(creator);
        feeHandler.claim(tokens);
        assertGt(creator.balance, ethBefore, "creator should claim non-zero ETH after graduation");
    }

    function test_e2e_multiRecipient_canClaim_afterGraduation() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        IRealmFactory.FeeShare[] memory fees = _fsTwo(alice, bob);
        address token = _createTestTokenWithSplit(salt, fees);
        _graduateE2E(token);

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        feeHandler.claim(tokens);
        vm.prank(bob);
        feeHandler.claim(tokens);

        uint256 aliceGain = alice.balance - aliceBefore;
        uint256 bobGain = bob.balance - bobBefore;

        assertGt(aliceGain, 0, "alice should receive ETH");
        assertGt(bobGain, 0, "bob should receive ETH");
        // 60/40 split with tolerance for rounding
        assertApproxEqRel(aliceGain * 4, bobGain * 6, 1e15, "alice/bob ratio should be ~60/40");
    }
}
