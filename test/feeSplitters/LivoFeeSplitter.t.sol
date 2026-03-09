// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {LivoFeeSplitter} from "src/feeSplitters/LivoFeeSplitter.sol";
import {ILivoFeeSplitter} from "src/interfaces/ILivoFeeSplitter.sol";
import {LivoFeeHandlerUniV2} from "src/feeHandlers/LivoFeeHandlerUniV2.sol";

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
    LivoFeeHandlerUniV2 public feeHandler;
    MockToken public token;

    address public tokenOwner = makeAddr("tokenOwner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    function setUp() public {
        feeHandler = new LivoFeeHandlerUniV2();
        token = new MockToken(tokenOwner, address(feeHandler));

        implementation = new LivoFeeSplitter();
        splitter = LivoFeeSplitter(payable(Clones.clone(address(implementation))));

        splitter.initialize(address(feeHandler), address(token), _recipients(alice, bob), _shares(7000, 3000));
        token.setFeeReceiver(address(splitter));

        vm.deal(address(this), 100 ether);
    }

    // ======================== Modifiers ========================

    modifier depositFees(uint256 amount) {
        splitter.depositFees{value: amount}(address(token), address(splitter));
        _;
    }

    modifier claimedBy(address user) {
        vm.prank(user);
        splitter.claim(_tokens());
        _;
    }

    modifier withSharesUpdated(address[] memory recipients_, uint256[] memory shares_) {
        vm.prank(tokenOwner);
        splitter.setShares(recipients_, shares_);
        _;
    }

    // ======================== Helpers ========================

    function _newSplitter() internal returns (LivoFeeSplitter) {
        return LivoFeeSplitter(payable(Clones.clone(address(implementation))));
    }

    function _recipients(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _recipients(address a, address b_) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b_;
    }

    function _recipients(address a, address b_, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b_;
        r[2] = c;
    }

    function _shares(uint256 a) internal pure returns (uint256[] memory s) {
        s = new uint256[](1);
        s[0] = a;
    }

    function _shares(uint256 a, uint256 b_) internal pure returns (uint256[] memory s) {
        s = new uint256[](2);
        s[0] = a;
        s[1] = b_;
    }

    function _shares(uint256 a, uint256 b_, uint256 c) internal pure returns (uint256[] memory s) {
        s = new uint256[](3);
        s[0] = a;
        s[1] = b_;
        s[2] = c;
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(token);
    }

    function _getClaimable(address account) internal view returns (uint256) {
        return splitter.getClaimable(_tokens(), account)[0];
    }

    // ======================== Initialization ========================

    /// @dev when initialized, then state variables are set correctly
    function test_initialize_assertStateIsSet() public view {
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

    /// @dev when already initialized, then reinitialize reverts
    function test_initialize_assertRevertsOnReinitialize() public {
        vm.expectRevert();
        splitter.initialize(address(feeHandler), address(token), _recipients(alice), _shares(10000));
    }

    /// @dev when recipients array is empty, then initialize reverts with InvalidRecipients
    function test_initialize_assertRevertsOnEmptyRecipients() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        s.initialize(address(feeHandler), address(token), new address[](0), new uint256[](0));
    }

    /// @dev when recipients and shares arrays have different lengths, then initialize reverts with InvalidRecipients
    function test_initialize_assertRevertsOnLengthMismatch() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        s.initialize(address(feeHandler), address(token), _recipients(alice, bob), _shares(10000));
    }

    /// @dev when shares do not sum to 10000, then initialize reverts with InvalidShares
    function test_initialize_assertRevertsOnSharesNotSumTo10000() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidShares.selector);
        s.initialize(address(feeHandler), address(token), _recipients(alice, bob), _shares(5000, 4000));
    }

    /// @dev when a recipient is address(0), then initialize reverts with InvalidRecipients
    function test_initialize_assertRevertsOnZeroRecipient() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        s.initialize(address(feeHandler), address(token), _recipients(address(0)), _shares(10000));
    }

    /// @dev when recipients contain duplicates, then initialize reverts with InvalidRecipients
    function test_initialize_assertRevertsOnDuplicateRecipient() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidRecipients.selector);
        s.initialize(address(feeHandler), address(token), _recipients(alice, alice), _shares(5000, 5000));
    }

    /// @dev when a share is zero, then initialize reverts with InvalidShares
    function test_initialize_assertRevertsOnZeroShare() public {
        LivoFeeSplitter s = _newSplitter();
        vm.expectRevert(ILivoFeeSplitter.InvalidShares.selector);
        s.initialize(address(feeHandler), address(token), _recipients(alice, bob), _shares(10000, 0));
    }

    /// @dev when implementation is deployed with constructor, then it cannot be initialized
    function test_implementation_assertCannotBeInitialized() public {
        vm.expectRevert();
        implementation.initialize(address(feeHandler), address(token), _recipients(alice), _shares(10000));
    }

    // ======================== setShares ========================

    /// @dev when token owner calls setShares with 3 recipients, then shares are updated correctly
    function test_setShares_assertUpdatesShares() public {
        vm.prank(tokenOwner);
        splitter.setShares(_recipients(alice, bob, charlie), _shares(5000, 3000, 2000));

        (address[] memory newRecipients, uint256[] memory newShares) = splitter.getRecipients();
        assertEq(newRecipients.length, 3);
        assertEq(newRecipients[2], charlie);
        assertEq(newShares[2], 2000);
        assertEq(splitter.sharesBpsOf(charlie), 2000);
    }

    /// @dev when non-owner calls setShares, then it reverts with Unauthorized
    function test_setShares_assertRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(ILivoFeeSplitter.Unauthorized.selector);
        splitter.setShares(_recipients(alice), _shares(10000));
    }

    /// @dev when token owner calls setShares, then SharesUpdated event is emitted
    function test_setShares_assertEmitsEvent() public {
        address[] memory r = _recipients(alice);
        uint256[] memory s = _shares(10000);

        vm.expectEmit(false, false, false, true, address(splitter));
        emit ILivoFeeSplitter.SharesUpdated(r, s);

        vm.prank(tokenOwner);
        splitter.setShares(r, s);
    }

    // ======================== claim ========================

    /// @dev when 10 ETH deposited and alice has 70% share, then alice claims 7 ETH
    function test_claim_assertAliceGets70Percent() public depositFees(10 ether) {
        uint256 before = alice.balance;
        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance - before, 7 ether, "alice should get 70%");
    }

    /// @dev when 10 ETH deposited and bob has 30% share, then bob claims 3 ETH
    function test_claim_assertBobGets30Percent() public depositFees(10 ether) {
        uint256 before = bob.balance;
        vm.prank(bob);
        splitter.claim(_tokens());
        assertEq(bob.balance - before, 3 ether, "bob should get 30%");
    }

    /// @dev when 10 ETH deposited and both claim, then alice gets 7 ETH and bob gets 3 ETH
    function test_claim_assertBothClaimFullAmount() public depositFees(10 ether) {
        vm.prank(alice);
        splitter.claim(_tokens());
        vm.prank(bob);
        splitter.claim(_tokens());

        assertEq(alice.balance, 7 ether);
        assertEq(bob.balance, 3 ether);
    }

    /// @dev when no fees deposited, then claim is a no-op
    function test_claim_assertNoopWhenNoFees() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, before);
    }

    /// @dev when non-recipient claims, then it is a no-op
    function test_claim_assertNoopForNonRecipient() public depositFees(10 ether) {
        uint256 before = charlie.balance;
        vm.prank(charlie);
        splitter.claim(_tokens());
        assertEq(charlie.balance, before);
    }

    /// @dev when alice already claimed, then second claim is a no-op
    function test_claim_assertNoopWhenAlreadyClaimed() public depositFees(10 ether) claimedBy(alice) {
        uint256 before = alice.balance;
        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, before);
    }

    /// @dev when 10 ETH deposited and alice claims, then FeesClaimed event is emitted
    function test_claim_assertEmitsEvents() public depositFees(10 ether) {
        vm.expectEmit(true, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesClaimed(alice, 7 ether);

        vm.prank(alice);
        splitter.claim(_tokens());
    }

    /// @dev when two deposits of 5 ETH each, then alice claims 7 ETH total
    function test_claim_assertMultipleDepositsAccumulate() public depositFees(5 ether) depositFees(5 ether) {
        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, 7 ether);
    }

    /// @dev when two deposits of 5 ETH each, then alice claims 7 ETH total, then a new deposit
    function test_claim_assertMultipleDepositsAccumulateClaimDepositAgain()
        public
        depositFees(5 ether)
        depositFees(5 ether)
        claimedBy(alice)
        depositFees(10 ether)
    {
        assertEq(alice.balance, 7 ether);
        assertEq(_getClaimable(alice), 7 ether); // 70% of new 10

        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, 14 ether);
    }

    /// @dev when alice claims after first deposit then claims again after second deposit, then she gets correct cumulative amount
    function test_claim_assertAfterPartialClaim() public depositFees(10 ether) claimedBy(alice) {
        assertEq(alice.balance, 7 ether);

        splitter.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, 14 ether);

        vm.prank(bob);
        splitter.claim(_tokens());
        assertEq(bob.balance, 6 ether);
    }

    // ======================== claim after setShares ========================

    /// @dev when bob is removed after 10 ETH deposited and alice claimed, then bob can still claim his pending 3 ETH
    function test_claimAfterSetShares_assertRemovedRecipientClaimsPending()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_recipients(alice, charlie), _shares(6000, 4000))
    {
        vm.prank(bob);
        splitter.claim(_tokens());
        assertEq(bob.balance, 3 ether);
    }

    /// @dev when bob is removed and claims his pending, then second claim is a no-op
    function test_claimAfterSetShares_assertRemovedRecipientCannotClaimTwice()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_recipients(alice), _shares(10000))
    {
        vm.prank(bob);
        splitter.claim(_tokens());

        uint256 bobAfter = bob.balance;
        vm.prank(bob);
        splitter.claim(_tokens());
        assertEq(bob.balance, bobAfter);
    }

    /// @dev when charlie is added after fees were deposited, then charlie has nothing to claim
    function test_claimAfterSetShares_assertNewRecipientGetsNoHistoricalFees()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_recipients(alice, bob, charlie), _shares(5000, 3000, 2000))
    {
        uint256 before = charlie.balance;
        vm.prank(charlie);
        splitter.claim(_tokens());
        assertEq(charlie.balance, before);
    }

    /// @dev when shares change from 70/30 to 50/50, then bob keeps snapshotted pending and earns at new rate
    function test_claimAfterSetShares_assertExistingRecipientKeepsPending()
        public
        depositFees(10 ether)
        claimedBy(alice)
        withSharesUpdated(_recipients(alice, bob), _shares(5000, 5000))
        depositFees(10 ether)
    {
        vm.prank(bob);
        splitter.claim(_tokens());
        // Bob gets: 3 ETH (snapshotted from 30% of 10) + 5 ETH (50% of new 10)
        assertEq(bob.balance, 8 ether);
    }

    // ======================== getClaimable ========================

    /// @dev when 10 ETH deposited and no one claimed, then getClaimable returns correct shares
    function test_getClaimable_assertBeforeClaim() public depositFees(10 ether) {
        assertEq(_getClaimable(alice), 7 ether);
        assertEq(_getClaimable(bob), 3 ether);
    }

    /// @dev when alice claimed, then getClaimable returns 0 for alice and unchanged for bob
    function test_getClaimable_assertAfterPartialClaim() public depositFees(10 ether) claimedBy(alice) {
        assertEq(_getClaimable(alice), 0);
        assertEq(_getClaimable(bob), 3 ether);
    }

    /// @dev when querying non-recipient, then getClaimable returns 0
    function test_getClaimable_assertZeroForNonRecipient() public depositFees(10 ether) {
        assertEq(_getClaimable(charlie), 0);
    }

    /// @dev when shares updated to remove alice and add charlie, then snapshotted amounts are preserved
    function test_getClaimable_assertAfterSetSharesPreservesSnapshots()
        public
        depositFees(10 ether)
        withSharesUpdated(_recipients(bob, charlie), _shares(6000, 4000))
    {
        assertEq(_getClaimable(alice), 7 ether);
        assertEq(_getClaimable(bob), 3 ether);
        assertEq(_getClaimable(charlie), 0);
    }

    /// @dev when shares updated and new fees deposited, then claimable reflects snapshot plus new share
    function test_getClaimable_assertAfterSetSharesWithNewDeposit()
        public
        depositFees(10 ether)
        withSharesUpdated(_recipients(bob, charlie), _shares(6000, 4000))
        depositFees(20 ether)
    {
        assertEq(_getClaimable(alice), 7 ether);
        assertEq(_getClaimable(bob), 15 ether); // 3 + 60% of 20
        assertEq(_getClaimable(charlie), 8 ether); // 0 + 40% of 20
    }

    // ======================== receive ========================

    /// @dev when ETH is sent directly, then contract accepts it
    function test_receive_assertAcceptsEth() public {
        (bool success,) = address(splitter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(splitter).balance, 1 ether);
    }

    // ======================== getFeeReceivers ========================

    /// @dev when feeReceiver is a splitter, then getFeeReceivers returns all recipients
    function test_getFeeReceivers_assertReturnsSplitterRecipients() public view {
        address[] memory receivers = token.getFeeReceivers();
        assertEq(receivers.length, 2);
        assertEq(receivers[0], alice);
        assertEq(receivers[1], bob);
    }

    /// @dev when feeReceiver is an EOA, then getFeeReceivers returns single address
    function test_getFeeReceivers_assertReturnsSingleEOA() public {
        token.setFeeReceiver(charlie);
        address[] memory receivers = token.getFeeReceivers();
        assertEq(receivers.length, 1);
        assertEq(receivers[0], charlie);
    }

    // ======================== getClaimable with upstream fees ========================

    /// @dev when fees are pending in the upstream feeHandler, then getClaimable includes them
    function test_getClaimable_assertIncludesUpstreamPendingFees() public depositFees(10 ether) {
        // Deposit 5 ETH directly to the feeHandler as pending for the splitter
        feeHandler.depositFees{value: 5 ether}(address(token), address(splitter));

        // getClaimable should include both: 10 ETH already in splitter + 5 ETH upstream
        assertEq(_getClaimable(alice), 10.5 ether); // 70% of 15
        assertEq(_getClaimable(bob), 4.5 ether); // 30% of 15
    }

    /// @dev when fees are only in the upstream feeHandler (none in splitter), then getClaimable still reports them
    function test_getClaimable_assertReportsUpstreamOnlyFees() public {
        // Deposit 10 ETH directly to the feeHandler as pending for the splitter
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        assertEq(_getClaimable(alice), 7 ether); // 70% of 10
        assertEq(_getClaimable(bob), 3 ether); // 30% of 10
    }

    /// @dev when upstream fees exist and user claims, then they receive the full amount including upstream
    function test_claim_assertClaimsIncludeUpstreamFees() public depositFees(10 ether) {
        feeHandler.depositFees{value: 5 ether}(address(token), address(splitter));

        vm.prank(alice);
        splitter.claim(_tokens());
        assertEq(alice.balance, 10.5 ether); // 70% of 15
    }
}
