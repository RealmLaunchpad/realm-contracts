// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    MasterFeeHandlerTestHelpers,
    MockMasterFeeToken,
    MasterFeeEthRejecter
} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {Vm} from "forge-std/Vm.sol";

contract RealmMasterFeeHandlerMultiRecipientDirectFeesTest is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal token;

    function setUp() public override {
        super.setUp();
        token = _newRegisteredToken(creator, _fs2(alice, 4_000, true, bob, 6_000, false));
    }

    function _setShares(IRealmFactory.FeeShare[] memory feeShares) internal {
        vm.prank(creator);
        handler.setShares(address(token), feeShares);
    }

    // ===================== registration =====================

    function test_registerToken_storesDirectSet() public view {
        address[] memory directs = handler.getDirectReceivers(address(token));
        assertEq(directs.length, 1, "direct length");
        assertEq(directs[0], alice, "direct receiver");
        assertTrue(handler.isDirectReceiver(address(token), alice), "alice direct");
        assertFalse(handler.isDirectReceiver(address(token), bob), "bob claimable");
    }

    function test_registerToken_zeroDirect_claimableOnly() public {
        MockMasterFeeToken t = _newRegisteredToken(creator, _fs2(bob, 6_000, false, charlie, 4_000, false));
        assertEq(handler.getDirectReceivers(address(t)).length, 0, "no directs");
        assertFalse(handler.isDirectReceiver(address(t), bob), "bob claimable");
        assertFalse(handler.isDirectReceiver(address(t), charlie), "charlie claimable");
    }

    function test_registerToken_multipleDirectReceivers_supportedByHandler() public {
        MockMasterFeeToken t =
            _newRegisteredToken(creator, _fs3(alice, 3_000, true, bob, 4_000, true, charlie, 3_000, false));

        address[] memory directs = handler.getDirectReceivers(address(t));
        assertEq(directs.length, 2, "direct length");

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        _deposit(t, 10 ether);

        assertEq(alice.balance - aliceBefore, 3 ether, "alice direct");
        assertEq(bob.balance - bobBefore, 4 ether, "bob direct");
        assertEq(handler.getClaimable(_single(address(t)), charlie)[0], 3 ether, "charlie claimable");
    }

    // ===================== deposit forwarding =====================

    function test_deposit_forwardsToDirectAndAccumulatesRest() public {
        uint256 aliceBefore = alice.balance;

        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 4 ether, "alice forwarded");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "bob accumulator share");
        assertEq(handler.getClaimable(_single(address(token)), alice)[0], 0, "alice has no pending");
    }

    function test_claim_bobReceivesFullClaimableShare() public {
        _deposit(token, 10 ether);

        uint256 before = bob.balance;
        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance - before, 6 ether, "bob claim amount");
    }

    function test_deposit_hostileDirect_fallbackToPending() public {
        MasterFeeEthRejecter hostile = new MasterFeeEthRejecter();
        MockMasterFeeToken t = _newRegisteredToken(creator, _fs2(address(hostile), 4_000, true, bob, 6_000, false));

        _deposit(t, 10 ether);

        assertEq(handler.getClaimable(_single(address(t)), address(hostile))[0], 4 ether, "hostile pending");
        assertEq(handler.getClaimable(_single(address(t)), bob)[0], 6 ether, "bob accumulator");
        assertEq(address(handler).balance, 10 ether, "failed direct + claimable funds remain in handler");
    }

    function test_deposit_eventOrder_depositBeforeClaim() public {
        vm.expectEmit(true, false, false, true, address(handler));
        emit IRealmMasterFeeHandler.CreatorFeesDeposited(address(token), 10 ether);
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmClaims.CreatorClaimed(address(token), alice, 4 ether);

        _deposit(token, 10 ether);
    }

    // ===================== setShares with mutable direct set =====================

    function test_setShares_changesDirectBps() public {
        _setShares(_fs2(alice, 3_000, true, bob, 7_000, false));

        address[] memory directs = handler.getDirectReceivers(address(token));
        assertEq(directs.length, 1, "direct length");
        assertEq(directs[0], alice, "direct receiver");

        uint256 aliceBefore = alice.balance;
        _deposit(token, 10 ether);
        assertEq(alice.balance - aliceBefore, 3 ether, "alice new direct share");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 7 ether, "bob new claimable share");
    }

    function test_setShares_removingDirect_succeeds() public {
        _setShares(_fs2(bob, 6_000, false, charlie, 4_000, false));

        assertEq(handler.getDirectReceivers(address(token)).length, 0, "no directs");

        uint256 aliceBefore = alice.balance;
        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 0, "alice no longer direct");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "bob claimable");
        assertEq(handler.getClaimable(_single(address(token)), charlie)[0], 4 ether, "charlie claimable");
        assertEq(handler.getClaimable(_single(address(token)), alice)[0], 0, "alice no residue");
    }

    function test_setShares_promotingToDirect_succeeds() public {
        _deposit(token, 10 ether);
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "bob accrued before promotion");

        _setShares(_fs2(alice, 4_000, true, bob, 6_000, true));

        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "bob pre-promotion accrual preserved");
        assertTrue(handler.isDirectReceiver(address(token), bob), "bob promoted");

        uint256 bobBefore = bob.balance;
        _deposit(token, 10 ether);
        assertEq(bob.balance - bobBefore, 6 ether, "bob receives via direct forward");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "old residue remains claimable");
    }

    function test_setShares_demotingDirect_succeeds() public {
        _setShares(_fs2(alice, 4_000, false, bob, 6_000, false));

        assertEq(handler.getDirectReceivers(address(token)).length, 0, "no directs");

        uint256 aliceBefore = alice.balance;
        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 0, "alice no longer direct");
        assertEq(handler.getClaimable(_single(address(token)), alice)[0], 4 ether, "alice claimable");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 6 ether, "bob claimable");
    }

    function test_setShares_addsClaimableShareholder() public {
        _setShares(_fs3(alice, 4_000, true, bob, 3_000, false, charlie, 3_000, false));

        uint256 aliceBefore = alice.balance;
        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 4 ether, "alice forwarded");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 3 ether, "bob claimable");
        assertEq(handler.getClaimable(_single(address(token)), charlie)[0], 3 ether, "charlie claimable");
    }

    function test_setShares_addsNewDirect() public {
        _setShares(_fs3(alice, 3_000, true, charlie, 2_000, true, bob, 5_000, false));

        assertEq(handler.getDirectReceivers(address(token)).length, 2, "direct length");

        uint256 aliceBefore = alice.balance;
        uint256 charlieBefore = charlie.balance;
        _deposit(token, 10 ether);

        assertEq(alice.balance - aliceBefore, 3 ether, "alice forwarded");
        assertEq(charlie.balance - charlieBefore, 2 ether, "charlie forwarded");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 5 ether, "bob claimable");
    }

    function test_setShares_removesDirectEntirely_residueClaimable() public {
        MasterFeeEthRejecter hostile = new MasterFeeEthRejecter();
        MockMasterFeeToken t = _newRegisteredToken(creator, _fs2(address(hostile), 4_000, true, bob, 6_000, false));

        _deposit(t, 10 ether);
        assertEq(handler.getClaimable(_single(address(t)), address(hostile))[0], 4 ether, "hostile residue");

        vm.prank(creator);
        handler.setShares(address(t), _fs(bob));

        assertEq(handler.getDirectReceivers(address(t)).length, 0, "no directs");
        assertEq(handler.getClaimable(_single(address(t)), address(hostile))[0], 4 ether, "residue preserved");
    }

    // ===================== direct-set events =====================

    function test_setShares_emitsDirectReceiverRegistered_onPromotion() public {
        IRealmFactory.FeeShare[] memory feeShares = _fs2(alice, 4_000, true, bob, 6_000, true);

        vm.expectEmit(true, true, false, false, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRegistered(address(token), bob);
        vm.prank(creator);
        handler.setShares(address(token), feeShares);
    }

    function test_setShares_emitsDirectReceiverRemoved_onDemotion() public {
        IRealmFactory.FeeShare[] memory feeShares = _fs2(alice, 4_000, false, bob, 6_000, false);

        vm.expectEmit(true, true, false, false, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRemoved(address(token), alice);
        vm.prank(creator);
        handler.setShares(address(token), feeShares);
    }

    function test_setShares_emitsBoth_onSwap() public {
        IRealmFactory.FeeShare[] memory feeShares = _fs2(alice, 4_000, false, bob, 6_000, true);

        vm.expectEmit(true, true, false, false, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRemoved(address(token), alice);
        vm.expectEmit(true, true, false, false, address(handler));
        emit IRealmMasterFeeHandler.DirectReceiverRegistered(address(token), bob);
        vm.prank(creator);
        handler.setShares(address(token), feeShares);
    }

    function test_setShares_noDirectChange_emitsNeitherDirectEvent() public {
        IRealmFactory.FeeShare[] memory feeShares = _fs2(alice, 3_000, true, bob, 7_000, false);

        vm.recordLogs();
        vm.prank(creator);
        handler.setShares(address(token), feeShares);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 registeredSig = keccak256("DirectReceiverRegistered(address,address)");
        bytes32 removedSig = keccak256("DirectReceiverRemoved(address,address)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(handler)) continue;
            assertTrue(entries[i].topics[0] != registeredSig, "no DirectReceiverRegistered");
            assertTrue(entries[i].topics[0] != removedSig, "no DirectReceiverRemoved");
        }
    }

    // ===================== no unaccounted ETH path =====================

    function test_directEthTransfer_rejected_noUnaccountedFees() public {
        (bool ok,) = address(handler).call{value: 5 ether}("");
        assertFalse(ok, "master handler rejects direct ETH");
        assertEq(handler.getClaimable(_single(address(token)), bob)[0], 0, "bob claimable unchanged");
        assertEq(handler.getClaimable(_single(address(token)), alice)[0], 0, "alice claimable unchanged");
    }
}
