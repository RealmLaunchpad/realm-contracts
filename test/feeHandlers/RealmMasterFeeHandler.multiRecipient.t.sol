// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MasterFeeHandlerTestHelpers, MockMasterFeeToken} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

contract RealmMasterFeeHandlerMultiRecipientTests is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal token;

    function setUp() public override {
        super.setUp();
        token = _newRegisteredToken(creator, _fs2(alice, 7_000, false, bob, 3_000, false));
    }

    modifier depositFees(uint256 amount) {
        _deposit(token, amount);
        _;
    }

    modifier claimedBy(address user) {
        vm.prank(user);
        handler.claim(_single(address(token)));
        _;
    }

    modifier withSharesUpdated(IRealmFactory.FeeShare[] memory feeShares) {
        vm.prank(creator);
        handler.setShares(address(token), feeShares);
        _;
    }

    // ======================== registration ========================

    function test_registerToken_assertStateIsSet() public view {
        (address[] memory recipients, uint256[] memory shares) = handler.getRecipients(address(token));
        assertEq(recipients.length, 2, "recipient length");
        assertEq(recipients[0], alice, "recipient 0");
        assertEq(recipients[1], bob, "recipient 1");
        assertEq(shares[0], 7_000, "alice shares");
        assertEq(shares[1], 3_000, "bob shares");
    }

    function test_registerToken_assertRevertsOnReinitialize() public {
        vm.expectRevert(IRealmMasterFeeHandler.AlreadyRegistered.selector);
        token.registerFees(_fs(alice));
    }

    function test_registerToken_assertRevertsOnEmptyRecipients() public {
        MockMasterFeeToken t = _newToken(creator);
        vm.expectRevert(IRealmMasterFeeHandler.InvalidFeeShares.selector);
        t.registerFees(new IRealmFactory.FeeShare[](0));
    }

    function test_registerToken_assertRevertsOnSharesNotSumTo10000() public {
        MockMasterFeeToken t = _newToken(creator);
        vm.expectRevert(IRealmMasterFeeHandler.InvalidShares.selector);
        t.registerFees(_fs2(alice, 5_000, false, bob, 4_000, false));
    }

    function test_registerToken_assertRevertsOnZeroRecipient() public {
        MockMasterFeeToken t = _newToken(creator);
        vm.expectRevert(IRealmMasterFeeHandler.InvalidFeeShares.selector);
        t.registerFees(_fs(address(0)));
    }

    function test_registerToken_assertRevertsOnDuplicateRecipient() public {
        MockMasterFeeToken t = _newToken(creator);
        vm.expectRevert(IRealmMasterFeeHandler.InvalidFeeShares.selector);
        t.registerFees(_fs2(alice, 5_000, false, alice, 5_000, false));
    }

    function test_registerToken_assertRevertsOnZeroShare() public {
        MockMasterFeeToken t = _newToken(creator);
        vm.expectRevert(IRealmMasterFeeHandler.InvalidShares.selector);
        t.registerFees(_fs2(alice, 10_000, false, bob, 0, false));
    }

    function test_registerToken_assertRevertsForNonTokenCaller() public {
        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        handler.registerToken(_fs(alice));
    }

    // ======================== setShares ========================

    function test_setShares_assertUpdatesShares() public {
        vm.prank(creator);
        handler.setShares(address(token), _fs3(alice, 5_000, false, bob, 3_000, false, charlie, 2_000, false));

        (address[] memory recipients, uint256[] memory shares) = handler.getRecipients(address(token));
        assertEq(recipients.length, 3, "recipient length");
        assertEq(recipients[2], charlie, "new recipient");
        assertEq(shares[2], 2_000, "new share");
    }

    function test_setShares_assertRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(IRealmMasterFeeHandler.Unauthorized.selector);
        handler.setShares(address(token), _fs(alice));
    }

    function test_setShares_assertHandlerOwnerCanUpdate() public {
        vm.prank(owner);
        handler.setShares(address(token), _fs(charlie));

        (address[] memory recipients, uint256[] memory shares) = handler.getRecipients(address(token));
        assertEq(recipients.length, 1, "recipient length");
        assertEq(recipients[0], charlie, "recipient");
        assertEq(shares[0], 10_000, "share");
    }

    function test_setShares_assertEmitsEvent() public {
        IRealmFactory.FeeShare[] memory feeShares = _fs(alice);
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10_000;

        vm.expectEmit(true, false, false, true, address(handler));
        emit IRealmMasterFeeHandler.SharesUpdated(address(token), recipients, shares);

        vm.prank(creator);
        handler.setShares(address(token), feeShares);
    }

    // ======================== claim ========================

    function test_claim_assertAliceGets70Percent() public depositFees(10 ether) {
        uint256 before = alice.balance;
        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance - before, 7 ether, "alice should get 70%");
    }

    function test_claim_assertBobGets30Percent() public depositFees(10 ether) {
        uint256 before = bob.balance;
        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance - before, 3 ether, "bob should get 30%");
    }

    function test_claim_assertBothClaimFullAmount() public depositFees(10 ether) {
        vm.prank(alice);
        handler.claim(_single(address(token)));
        vm.prank(bob);
        handler.claim(_single(address(token)));

        assertEq(alice.balance, 7 ether, "alice balance");
        assertEq(bob.balance, 3 ether, "bob balance");
    }

    function test_claim_assertNoopWhenNoFees() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance, before, "alice unchanged");
    }

    function test_claim_assertNoopForNonRecipient() public depositFees(10 ether) {
        uint256 before = charlie.balance;
        vm.prank(charlie);
        handler.claim(_single(address(token)));
        assertEq(charlie.balance, before, "charlie unchanged");
    }

    function test_claim_assertNoopWhenAlreadyClaimed() public depositFees(10 ether) claimedBy(alice) {
        uint256 before = alice.balance;
        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance, before, "second claim no-op");
    }

    function test_claim_assertEmitsEvents() public depositFees(10 ether) {
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmClaims.CreatorClaimed(address(token), alice, 7 ether);

        vm.prank(alice);
        handler.claim(_single(address(token)));
    }

    function test_claim_assertMultipleDepositsAccumulate() public depositFees(5 ether) depositFees(5 ether) {
        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance, 7 ether, "alice total");
    }

    function test_claim_assertMultipleDepositsAccumulateClaimDepositAgain()
        public
        depositFees(5 ether)
        depositFees(5 ether)
        claimedBy(alice)
        depositFees(10 ether)
    {
        assertEq(alice.balance, 7 ether, "alice first claim");
        assertEq(_claimable(address(token), alice), 7 ether, "new claimable");

        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance, 14 ether, "alice second claim");
    }

    function test_claim_assertAfterPartialClaim() public depositFees(10 ether) claimedBy(alice) {
        assertEq(alice.balance, 7 ether, "alice first claim");

        _deposit(token, 10 ether);

        vm.prank(alice);
        handler.claim(_single(address(token)));
        assertEq(alice.balance, 14 ether, "alice second claim");

        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance, 6 ether, "bob all fees");
    }

    // ======================== claim after setShares ========================

    function test_claimAfterSetShares_assertRemovedRecipientClaimsPending()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_fs2(alice, 6_000, false, charlie, 4_000, false))
    {
        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance, 3 ether, "bob retained prior share");
    }

    function test_claimAfterSetShares_assertRemovedRecipientCannotClaimTwice()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_fs(alice))
    {
        vm.prank(bob);
        handler.claim(_single(address(token)));

        uint256 bobAfter = bob.balance;
        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance, bobAfter, "second removed-recipient claim no-op");
    }

    function test_claimAfterSetShares_assertNewRecipientGetsNoHistoricalFees()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_fs3(alice, 5_000, false, bob, 3_000, false, charlie, 2_000, false))
    {
        uint256 before = charlie.balance;
        vm.prank(charlie);
        handler.claim(_single(address(token)));
        assertEq(charlie.balance, before, "charlie should not get historical fees");
    }

    function test_claimAfterSetShares_assertExistingRecipientKeepsPending()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_fs2(alice, 5_000, false, bob, 5_000, false))
        depositFees(10 ether)
    {
        vm.prank(bob);
        handler.claim(_single(address(token)));
        assertEq(bob.balance, 8 ether, "bob gets old 3 ETH plus new 5 ETH");
    }

    // ======================== getClaimable ========================

    function test_getClaimable_assertBeforeClaim() public depositFees(10 ether) {
        assertEq(_claimable(address(token), alice), 7 ether, "alice claimable");
        assertEq(_claimable(address(token), bob), 3 ether, "bob claimable");
    }

    function test_getClaimable_assertAfterPartialClaim() public depositFees(10 ether) claimedBy(alice) {
        assertEq(_claimable(address(token), alice), 0, "alice claimed");
        assertEq(_claimable(address(token), bob), 3 ether, "bob unclaimed");
    }

    function test_getClaimable_assertZeroForNonRecipient() public depositFees(10 ether) {
        assertEq(_claimable(address(token), charlie), 0, "charlie claimable");
    }

    function test_getClaimable_assertAfterSetSharesPreservesSnapshots()
        public
        depositFees(10 ether)
        withSharesUpdated(_fs2(bob, 6_000, false, charlie, 4_000, false))
    {
        assertEq(_claimable(address(token), alice), 7 ether, "alice preserved");
        assertEq(_claimable(address(token), bob), 3 ether, "bob preserved");
        assertEq(_claimable(address(token), charlie), 0, "charlie no history");
    }

    function test_getClaimable_assertAfterSetSharesWithNewDeposit()
        public
        depositFees(10 ether)
        withSharesUpdated(_fs2(bob, 6_000, false, charlie, 4_000, false))
        depositFees(20 ether)
    {
        assertEq(_claimable(address(token), alice), 7 ether, "alice preserved");
        assertEq(_claimable(address(token), bob), 15 ether, "bob old plus new");
        assertEq(_claimable(address(token), charlie), 8 ether, "charlie new share");
    }

    // ======================== getRecipients ========================

    function test_getRecipients_assertReturnsCurrentRecipients() public view {
        (address[] memory recipients, uint256[] memory shares) = handler.getRecipients(address(token));
        assertEq(recipients.length, 2, "recipient length");
        assertEq(recipients[0], alice, "alice recipient");
        assertEq(recipients[1], bob, "bob recipient");
        assertEq(shares.length, 2, "shares length");
        assertEq(shares[0], 7_000, "alice share");
        assertEq(shares[1], 3_000, "bob share");
    }

    function test_getRecipients_assertReturnsSingleRecipientAfterUpdate() public {
        vm.prank(creator);
        handler.setShares(address(token), _fs(charlie));

        (address[] memory recipients, uint256[] memory shares) = handler.getRecipients(address(token));
        assertEq(recipients.length, 1, "recipient length");
        assertEq(recipients[0], charlie, "charlie recipient");
        assertEq(shares.length, 1, "shares length");
        assertEq(shares[0], 10_000, "charlie share");
    }
}
