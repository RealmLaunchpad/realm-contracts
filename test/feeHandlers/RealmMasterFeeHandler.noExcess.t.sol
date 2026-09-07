// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    MasterFeeHandlerTestHelpers,
    MockMasterFeeToken,
    MasterFeeEthRejecter
} from "test/helpers/MasterFeeHandlerTestHelpers.sol";

contract RealmMasterFeeHandlerNoExcessTests is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal claimableToken;
    MockMasterFeeToken internal directToken;

    function setUp() public override {
        super.setUp();
        claimableToken = _newRegisteredToken(creator, _fs(creator));
        directToken = _newRegisteredToken(creator, _fsDirect(alice));
    }

    function test_directEthTransfer_revertsAndDoesNotCreateExcess() public {
        (bool ok,) = address(handler).call{value: 1 ether}("");

        assertFalse(ok, "handler should reject direct ETH transfers");
        assertEq(address(handler).balance, 0, "no excess ETH should enter handler");
    }

    function test_depositFees_claimableTracksAllEthAsPending() public {
        _deposit(claimableToken, 2 ether);
        _deposit(claimableToken, 0.5 ether);

        assertEq(address(handler).balance, 2.5 ether, "handler balance should equal claimable ETH");
        assertEq(_claimable(address(claimableToken), creator), 2.5 ether, "all ETH attributed to creator");
    }

    function test_claim_noPending_balanceUnchanged() public {
        _deposit(claimableToken, 1 ether);

        vm.prank(alice);
        handler.claim(_single(address(claimableToken)));

        assertEq(address(handler).balance, 1 ether, "creator pending should remain untouched");
        assertEq(_claimable(address(claimableToken), creator), 1 ether, "creator pending intact");
    }

    function test_claim_decrementsHandlerBalance() public {
        _deposit(claimableToken, 2 ether);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        handler.claim(_single(address(claimableToken)));

        assertEq(creator.balance - creatorBefore, 2 ether, "creator received pending amount");
        assertEq(address(handler).balance, 0, "handler empty after claim");
    }

    function test_directDeposit_successDoesNotLeaveBalance() public {
        uint256 aliceBefore = alice.balance;

        _deposit(directToken, 1 ether);

        assertEq(alice.balance - aliceBefore, 1 ether, "alice receives direct fees");
        assertEq(address(handler).balance, 0, "successful direct forward leaves no balance");
    }

    function test_directDeposit_failedForwardLeavesOnlyPendingResidue() public {
        MasterFeeEthRejecter hostile = new MasterFeeEthRejecter();
        MockMasterFeeToken token = _newRegisteredToken(creator, _fsDirect(address(hostile)));

        _deposit(token, 1 ether);

        assertEq(address(handler).balance, 1 ether, "failed direct residue remains in handler");
        assertEq(_claimable(address(token), address(hostile)), 1 ether, "residue attributed to hostile receiver");
    }

    function test_depositFees_unregisteredZeroValue_noop() public {
        MockMasterFeeToken unregistered = _newToken(creator);

        handler.depositFees{value: 0}(address(unregistered));

        assertEq(address(handler).balance, 0, "zero-value unregistered deposit is a no-op");
    }

    function test_getClaimable_unregisteredTokenReturnsZero() public {
        MockMasterFeeToken unregistered = _newToken(creator);

        uint256[] memory amounts = handler.getClaimable(_single(address(unregistered)), creator);

        assertEq(amounts.length, 1, "array length");
        assertEq(amounts[0], 0, "unregistered token claimable should be zero");
    }

    function test_fullLifecycle_depositClaimDirectForward() public {
        _deposit(claimableToken, 3 ether);
        assertEq(address(handler).balance, 3 ether, "claimable fees held");

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        handler.claim(_single(address(claimableToken)));
        assertEq(creator.balance - creatorBefore, 3 ether, "creator claimed");
        assertEq(address(handler).balance, 0, "claimable token emptied");

        uint256 aliceBefore = alice.balance;
        _deposit(directToken, 2 ether);
        assertEq(alice.balance - aliceBefore, 2 ether, "direct receiver paid");
        assertEq(address(handler).balance, 0, "no excess after direct deposit");
    }
}
