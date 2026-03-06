// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoFeeBaseHandler} from "src/feeHandlers/LivoFeeBaseHandler.sol";

contract MockToken {
    address public owner;
    address public feeHandler;
    address public feeReceiver;

    constructor(address _owner, address _feeHandler) {
        owner = _owner;
        feeHandler = _feeHandler;
    }

    function setFeeReceiver(address _feeReceiver) external {
        feeReceiver = _feeReceiver;
    }

    function getFeeReceivers() external view returns (address[] memory) {
        address feeReceiver_ = feeReceiver;
        if (feeReceiver_.code.length > 0) {
            try ILivoFeeSplitter(feeReceiver_).getRecipients() returns (address[] memory recipients, uint256[] memory) {
                return recipients;
            } catch {}
        }
        address[] memory result = new address[](1);
        result[0] = feeReceiver_;
        return result;
    }
}

contract LivoFeeSplitterTests is Test {
    LivoFeeSplitter public implementation;
    LivoFeeSplitter public splitter;
    LivoFeeBaseHandler public feeHandler;
    MockToken public token;

    address public tokenOwner = makeAddr("tokenOwner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public {
        feeHandler = new LivoFeeBaseHandler();
        token = new MockToken(tokenOwner, address(feeHandler));

        implementation = new LivoFeeSplitter();
        splitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 7000;
        shares[1] = 3000;

        splitter.initialize(address(feeHandler), address(token), recipients, shares);
        token.setFeeReceiver(address(splitter));

        vm.deal(address(this), 100 ether);
    }

    // ======================== Initialization ========================

    function test_initialize_setsState() public view {
        assertEq(splitter.feeHandler(), address(feeHandler));
        assertEq(splitter.token(), address(token));
        (address[] memory recipients, uint256[] memory shares) = splitter.getRecipients();
        assertEq(recipients.length, 2);
        assertEq(recipients[0], alice);
        assertEq(recipients[1], bob);
        assertEq(shares[0], 7000);
        assertEq(shares[1], 3000);
        assertEq(splitter.sharesBpsOf(alice), 7000);
        assertEq(splitter.sharesBpsOf(bob), 3000);
    }

    function test_initialize_cannotReinitialize() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.expectRevert();
        splitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnEmptyRecipients() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](0);
        uint256[] memory shares = new uint256[](0);

        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnSharesMismatch() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnSharesNotSumTo10000() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5000;
        shares[1] = 4000;

        vm.expectRevert(ILivoFeeSplitter.InvalidShares.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnZeroRecipient() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](1);
        recipients[0] = address(0);
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnDuplicateRecipient() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = alice;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5000;
        shares[1] = 5000;

        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    function test_initialize_revertsOnZeroShareBps() public {
        LivoFeeSplitter newSplitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 10000;
        shares[1] = 0;

        vm.expectRevert(ILivoFeeSplitter.InvalidShares.selector);
        newSplitter.initialize(address(feeHandler), address(token), recipients, shares);
    }

    // ======================== setShares ========================

    function test_setShares_byOwner() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = charlie;
        uint256[] memory shares = new uint256[](3);
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        (address[] memory newRecipients, uint256[] memory newShares) = splitter.getRecipients();
        assertEq(newRecipients.length, 3);
        assertEq(newRecipients[2], charlie);
        assertEq(newShares[2], 2000);
        assertEq(splitter.sharesBpsOf(charlie), 2000);
    }

    function test_setShares_revertsForNonOwner() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.prank(alice);
        vm.expectRevert(ILivoFeeSplitter.Unauthorized.selector);
        splitter.setShares(recipients, shares);
    }

    function test_setShares_emitsEvent() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.expectEmit(false, false, false, true, address(splitter));
        emit ILivoFeeSplitter.SharesUpdated(recipients, shares);

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);
    }

    // ======================== claim ========================

    function test_claim_aliceGets70Percent() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        splitter.claim();

        assertEq(alice.balance - aliceBefore, 7 ether, "alice should get 70%");
    }

    function test_claim_bobGets30Percent() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        splitter.claim();

        assertEq(bob.balance - bobBefore, 3 ether, "bob should get 30%");
    }

    function test_claim_bothClaimFullAmount() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();

        vm.prank(bob);
        splitter.claim();

        assertEq(alice.balance, 7 ether);
        assertEq(bob.balance, 3 ether);
    }

    function test_claim_noopWhenNothingToClaim() public {
        uint256 charlieBefore = charlie.balance;
        vm.prank(charlie);
        splitter.claim();
        assertEq(charlie.balance, charlieBefore);
    }

    function test_claim_noopWhenAlreadyClaimed() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, aliceBefore);
    }

    function test_claim_emitsEvents() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.expectEmit(true, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesAccrued(10 ether);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesClaimed(alice, 7 ether);

        vm.prank(alice);
        splitter.claim();
    }

    function test_claim_multipleDepositsAccumulate() public {
        feeHandler.depositFees{value: 5 ether}(address(token), address(splitter));
        feeHandler.depositFees{value: 5 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, 7 ether);
    }

    function test_claim_afterPartialClaim() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, 7 ether);

        // More fees deposited
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, 14 ether);

        // Bob claims everything at once
        vm.prank(bob);
        splitter.claim();
        assertEq(bob.balance, 6 ether);
    }

    function test_claim_noopWhenNoFees() public {
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, aliceBefore);
    }

    // ======================== claim after setShares ========================

    function test_claim_removedRecipientCanClaimPending() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // Alice claims, accruing the balance
        vm.prank(alice);
        splitter.claim();

        // Now remove bob and add charlie
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = charlie;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // Bob was snapshotted with 3 ether pending
        vm.prank(bob);
        splitter.claim();
        assertEq(bob.balance, 3 ether);
    }

    function test_claim_removedRecipientCannotClaimTwice() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();

        // Remove bob
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // Bob claims his pending
        vm.prank(bob);
        splitter.claim();

        // Bob cannot claim again (no-op)
        uint256 bobAfter = bob.balance;
        vm.prank(bob);
        splitter.claim();
        assertEq(bob.balance, bobAfter);
    }

    function test_claim_newRecipientDoesNotGetHistoricalFees() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // Alice claims to accrue
        vm.prank(alice);
        splitter.claim();

        // Add charlie
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = charlie;
        uint256[] memory shares = new uint256[](3);
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // Charlie should have nothing claimable (no-op)
        uint256 charlieBefore = charlie.balance;
        vm.prank(charlie);
        splitter.claim();
        assertEq(charlie.balance, charlieBefore);
    }

    function test_claim_afterSharesChange_existingRecipientKeepsPending() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // Accrue by alice claiming
        vm.prank(alice);
        splitter.claim();
        assertEq(alice.balance, 7 ether);

        // Change shares: alice 50%, bob 50%
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5000;
        shares[1] = 5000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // Bob's pending should have been snapshotted (3 ether)
        // New fees come in
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(bob);
        splitter.claim();
        // Bob gets: 3 ether (snapshotted) + 5 ether (50% of new 10 ether)
        assertEq(bob.balance, 8 ether);
    }

    // ======================== getClaimable after setShares ========================

    function test_getClaimable_afterSetShares_removedRecipientKeepsPending() public {
        // Setup: 10 ETH deposited, alice=70%, bob=30%
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // setShares: remove alice, keep bob, add charlie
        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = charlie;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // Alice was snapshotted with 7 ETH pending
        assertEq(splitter.getClaimable(alice), 7 ether);
        // Bob was snapshotted with 3 ETH pending
        assertEq(splitter.getClaimable(bob), 3 ether);
        // Charlie just joined, nothing claimable
        assertEq(splitter.getClaimable(charlie), 0);
    }

    function test_getClaimable_afterSetShares_withNewDeposit() public {
        // Setup: 10 ETH deposited, alice=70%, bob=30%
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // setShares: remove alice, keep bob (60%), add charlie (40%)
        address[] memory recipients = new address[](2);
        recipients[0] = bob;
        recipients[1] = charlie;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        vm.prank(tokenOwner);
        splitter.setShares(recipients, shares);

        // New deposit after setShares
        feeHandler.depositFees{value: 20 ether}(address(token), address(splitter));

        // Alice: 7 ETH snapshotted, no new share (removed)
        assertEq(splitter.getClaimable(alice), 7 ether);
        // Bob: 3 ETH snapshotted + 60% of 20 ETH = 3 + 12 = 15 ETH
        assertEq(splitter.getClaimable(bob), 15 ether);
        // Charlie: 0 snapshotted + 40% of 20 ETH = 8 ETH
        assertEq(splitter.getClaimable(charlie), 8 ether);
    }

    // ======================== getClaimable ========================

    function test_getClaimable_beforeClaim() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        // Fees are in feeHandler, not yet accrued
        uint256 aliceClaimable = splitter.getClaimable(alice);
        assertEq(aliceClaimable, 7 ether);

        uint256 bobClaimable = splitter.getClaimable(bob);
        assertEq(bobClaimable, 3 ether);
    }

    function test_getClaimable_afterPartialClaim() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim();

        // Alice has nothing left
        assertEq(splitter.getClaimable(alice), 0);
        // Bob still has his share
        assertEq(splitter.getClaimable(bob), 3 ether);
    }

    function test_getClaimable_nonRecipient() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));
        assertEq(splitter.getClaimable(charlie), 0);
    }

    // ======================== receive ========================

    function test_receiveEth() public {
        (bool success,) = address(splitter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(splitter).balance, 1 ether);
    }

    // ======================== getFeeReceivers ========================

    function test_getFeeReceivers_withSplitter() public view {
        address[] memory receivers = token.getFeeReceivers();
        assertEq(receivers.length, 2);
        assertEq(receivers[0], alice);
        assertEq(receivers[1], bob);
    }

    function test_getFeeReceivers_withEOA() public {
        token.setFeeReceiver(charlie);
        address[] memory receivers = token.getFeeReceivers();
        assertEq(receivers.length, 1);
        assertEq(receivers[0], charlie);
    }

    // ======================== Implementation cannot be initialized ========================

    function test_implementation_cannotBeInitialized() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.expectRevert();
        implementation.initialize(address(feeHandler), address(token), recipients, shares);
    }
}
