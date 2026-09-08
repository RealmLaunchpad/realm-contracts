// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    MasterFeeHandlerTestHelpers,
    MockMasterFeeToken,
    MasterFeeEthRejecter
} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";

contract RealmMasterFeeHandlerDirectFeesTest is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal tokenA;
    MockMasterFeeToken internal tokenB;

    function setUp() public override {
        super.setUp();
        tokenA = _newRegisteredToken(creator, _fsDirect(alice));
        tokenB = _newRegisteredToken(creator, _fsDirect(bob));
    }

    // ===================== direct receiver registration =====================

    function test_registerToken_withDirectReceiver_storesDirectStatus() public view {
        assertTrue(handler.isDirectReceiver(address(tokenA), alice));
    }

    function test_registerToken_perTokenIsolation() public view {
        assertTrue(handler.isDirectReceiver(address(tokenA), alice));
        assertFalse(handler.isDirectReceiver(address(tokenA), bob));
        assertTrue(handler.isDirectReceiver(address(tokenB), bob));
    }

    function test_registerToken_multipleDirectReceivers_supportedByHandler() public {
        MockMasterFeeToken token = _newRegisteredToken(creator, _fs2(alice, 5_000, true, bob, 5_000, true));

        assertTrue(handler.isDirectReceiver(address(token), alice));
        assertTrue(handler.isDirectReceiver(address(token), bob));
        assertFalse(handler.isDirectReceiver(address(token), charlie));

        address[] memory directs = handler.getDirectReceivers(address(token));
        assertEq(directs.length, 2, "direct receiver count");
        assertEq(directs[0], alice, "first direct");
        assertEq(directs[1], bob, "second direct");
    }

    function test_registerToken_emitsEventPerDirectReceiver() public {
        MockMasterFeeToken token = _newToken(creator);

        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRegistered(address(token), alice);
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRegistered(address(token), bob);

        _register(token, _fs2(alice, 5_000, true, bob, 5_000, true));
    }

    function test_registerToken_zeroDirect_claimableOnly() public {
        MockMasterFeeToken token = _newRegisteredToken(creator, _fs(alice));

        assertFalse(handler.isDirectReceiver(address(token), alice));
        assertEq(handler.getDirectReceivers(address(token)).length, 0, "no direct receivers");
    }

    // ===================== depositFees direct path =====================

    function test_deposit_direct_forwardsImmediately() public {
        uint256 before = alice.balance;
        _deposit(tokenA, 1 ether);

        assertEq(alice.balance - before, 1 ether, "alice received forwarded ETH");
        assertEq(handler.getClaimable(_single(address(tokenA)), alice)[0], 0, "no pending after forward");
        assertEq(address(handler).balance, 0, "handler should retain no ETH after successful forward");
    }

    function test_deposit_direct_emitsBothEvents() public {
        vm.expectEmit(true, false, false, true, address(handler));
        emit IRealmMasterFeeHandler.CreatorFeesDeposited(address(tokenA), 1 ether);
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmClaims.CreatorClaimed(address(tokenA), alice, 1 ether);

        _deposit(tokenA, 1 ether);
    }

    function test_deposit_direct_hostileReceiver_fallbackToPending() public {
        MasterFeeEthRejecter hostile = new MasterFeeEthRejecter();
        MockMasterFeeToken hostileToken = _newRegisteredToken(creator, _fsDirect(address(hostile)));

        _deposit(hostileToken, 1 ether);

        assertEq(address(handler).balance, 1 ether, "failed forward remains in handler");
        assertEq(handler.getClaimable(_single(address(hostileToken)), address(hostile))[0], 1 ether, "hostile pending");
    }

    function test_deposit_direct_zeroValue_noForwardOrPending() public {
        uint256 before = alice.balance;
        _deposit(tokenA, 0);

        assertEq(alice.balance, before, "alice balance unchanged");
        assertEq(handler.getClaimable(_single(address(tokenA)), alice)[0], 0, "no pending");
    }

    function test_deposit_multiDirect_forwardsProRata() public {
        MockMasterFeeToken token = _newRegisteredToken(creator, _fs2(alice, 4_000, true, bob, 6_000, true));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 4 ether, "alice direct share");
        assertEq(bob.balance - bobBefore, 6 ether, "bob direct share");
        assertEq(address(handler).balance, 0, "all funds forwarded");
    }

    // ===================== claim after failed forward =====================

    function test_claim_recoverFailedForward() public {
        MasterFeeEthRejecter hostile = new MasterFeeEthRejecter();
        MockMasterFeeToken hostileToken = _newRegisteredToken(creator, _fsDirect(address(hostile)));

        _deposit(hostileToken, 1 ether);

        vm.etch(address(hostile), hex"");

        uint256 before = address(hostile).balance;
        vm.prank(address(hostile));
        handler.claim(_single(address(hostileToken)));
        assertEq(address(hostile).balance - before, 1 ether, "failed-forward residue should be claimable");
    }

    // ===================== mutable direct status =====================

    function test_setShares_canMoveDirectFeesToNewClaimableReceiver() public {
        vm.prank(creator);
        handler.setShares(address(tokenA), _fs(bob));

        assertFalse(handler.isDirectReceiver(address(tokenA), alice), "alice demoted/removed");
        assertFalse(handler.isDirectReceiver(address(tokenA), bob), "bob is claimable");

        uint256 bobBefore = bob.balance;
        _deposit(tokenA, 1 ether);

        assertEq(bob.balance, bobBefore, "claimable receiver not forwarded");
        assertEq(handler.getClaimable(_single(address(tokenA)), bob)[0], 1 ether, "bob has pending");
        assertEq(handler.getClaimable(_single(address(tokenA)), alice)[0], 0, "alice gets nothing");
    }

    function test_setShares_canMoveDirectFeesToNewDirectReceiver() public {
        vm.prank(creator);
        handler.setShares(address(tokenA), _fsDirect(bob));

        assertFalse(handler.isDirectReceiver(address(tokenA), alice), "alice no longer direct");
        assertTrue(handler.isDirectReceiver(address(tokenA), bob), "bob now direct");

        uint256 bobBefore = bob.balance;
        _deposit(tokenA, 1 ether);

        assertEq(bob.balance - bobBefore, 1 ether, "bob receives directly");
        assertEq(handler.getClaimable(_single(address(tokenA)), bob)[0], 0, "bob has no pending");
    }
}
