// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoFeeHandlerBase} from "src/feeHandlers/LivoFeeHandlerBase.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";

/// @dev Minimal mock that returns a configurable treasury address
contract MockLaunchpad {
    address public treasury;

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external {
        treasury = _treasury;
    }
}

/// @dev Contract that rejects ETH transfers — used to test EthTransferFailed
contract EthRejecter {
    receive() external payable {
        revert("rejected");
    }
}

// ---------------------------------------------------------------------------
// Base test contract with modifiers
// ---------------------------------------------------------------------------
contract LivoFeeHandlerBaseTests is Test {
    LivoFeeHandlerBase public handler;
    MockLaunchpad public mockLaunchpad;

    address public treasuryAddr = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address public tokenA = makeAddr("tokenA");
    address public tokenB = makeAddr("tokenB");
    address public tokenC = makeAddr("tokenC");

    function setUp() public virtual {
        mockLaunchpad = new MockLaunchpad(treasuryAddr);
        handler = new LivoFeeHandlerBase();
        vm.deal(address(this), 1000 ether);
    }

    // ======================== Modifiers ========================

    /// @dev Deposits `amount` of ETH fees for `token` credited to `feeReceiver`
    modifier depositFees(address token, address feeReceiver, uint256 amount) {
        handler.depositFees{value: amount}(token, feeReceiver);
        _;
    }

    /// @dev Claims fees for `claimer` across the given `tokens`
    modifier claimAs(address claimer, address[] memory tokens) {
        vm.prank(claimer);
        handler.claim(tokens);
        _;
    }

    // ======================== Helpers ========================

    function _toArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _toArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _toArray(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    /// @dev Returns the claimable ETH for `account` on a single `token`
    function _claimable(address token, address account) internal view returns (uint256) {
        return handler.getClaimable(_toArray(token), account)[0];
    }

    // ====================================================================
    //                        depositFees() tests
    // ====================================================================

    /// @dev when 1 ether of fees is deposited for tokenA/creator, then getClaimable returns 1 ether
    function test_depositFees_assertClaimableIncreases() public depositFees(tokenA, creator, 1 ether) {
        assertEq(_claimable(tokenA, creator), 1 ether, "claimable should equal deposited amount");
    }

    /// @dev when fees are deposited twice for the same token/receiver, then getClaimable is the cumulative total
    function test_depositFeesTwice_assertCumulativeClaimable()
        public
        depositFees(tokenA, creator, 1 ether)
        depositFees(tokenA, creator, 2 ether)
    {
        assertEq(_claimable(tokenA, creator), 3 ether, "claimable should be cumulative");
    }

    /// @dev when fees are deposited for two different receivers on the same token, then each receiver's claimable is independent
    function test_depositFeesDifferentReceivers_assertIndependent()
        public
        depositFees(tokenA, alice, 1 ether)
        depositFees(tokenA, bob, 2 ether)
    {
        assertEq(_claimable(tokenA, alice), 1 ether, "alice claimable incorrect");
        assertEq(_claimable(tokenA, bob), 2 ether, "bob claimable incorrect");
    }

    /// @dev when fees are deposited with msg.value = 0, then getClaimable remains 0
    function test_depositFeesZero_assertClaimableUnchanged() public depositFees(tokenA, creator, 0) {
        assertEq(_claimable(tokenA, creator), 0, "claimable should remain 0");
    }

    /// @dev when fees are deposited, then a CreatorFeesDeposited event is emitted with correct params
    function test_depositFees_assertEventEmitted() public {
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.CreatorFeesDeposited(tokenA, creator, 1 ether);
        handler.depositFees{value: 1 ether}(tokenA, creator);
    }

    // ====================================================================
    //                          claim() tests
    // ====================================================================

    /// @dev when a receiver claims fees for a single token, then they receive the ETH and getClaimable becomes 0
    function test_claimSingleToken_assertBalanceAndClaimable() public depositFees(tokenA, creator, 3 ether) {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_toArray(tokenA));

        assertEq(creator.balance - balanceBefore, 3 ether, "creator should receive 3 ether");
        assertEq(_claimable(tokenA, creator), 0, "claimable should be 0 after claim");
    }

    /// @dev when a receiver claims fees for multiple tokens, then they receive the total ETH across all tokens
    function test_claimMultipleTokens_assertTotalBalance()
        public
        depositFees(tokenA, creator, 1 ether)
        depositFees(tokenB, creator, 2 ether)
        depositFees(tokenC, creator, 0.5 ether)
    {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_toArray(tokenA, tokenB, tokenC));

        assertEq(creator.balance - balanceBefore, 3.5 ether, "creator should receive total across tokens");
    }

    /// @dev when a receiver claims but has no pending fees, then no ETH is transferred
    function test_claimNoPending_assertNoTransfer() public {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_toArray(tokenA));

        assertEq(creator.balance, balanceBefore, "balance should be unchanged");
    }

    /// @dev when a receiver claims, then CreatorClaimed events are emitted per token
    function test_claim_assertCreatorClaimedEvents()
        public
        depositFees(tokenA, creator, 1 ether)
        depositFees(tokenB, creator, 2 ether)
    {
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.CreatorClaimed(tokenA, creator, 1 ether);
        vm.expectEmit(true, true, false, true, address(handler));
        emit ILivoFeeHandler.CreatorClaimed(tokenB, creator, 2 ether);

        vm.prank(creator);
        handler.claim(_toArray(tokenA, tokenB));
    }

    /// @dev when a receiver claims for multiple tokens but only some have fees, then only those with fees are claimed
    function test_claimPartialFees_assertSelectiveClaim() public depositFees(tokenA, creator, 1 ether) {
        uint256 balanceBefore = creator.balance;

        // tokenB has no deposits for creator
        vm.prank(creator);
        handler.claim(_toArray(tokenA, tokenB));

        assertEq(creator.balance - balanceBefore, 1 ether, "should only claim from tokenA");
        assertEq(_claimable(tokenA, creator), 0, "tokenA claimable should be 0");
        assertEq(_claimable(tokenB, creator), 0, "tokenB claimable should be 0");
    }

    /// @dev when a receiver claims and the ETH transfer fails, then the transaction reverts with EthTransferFailed
    function test_claimEthTransferFails_assertReverts() public {
        EthRejecter rejecter = new EthRejecter();
        address rejecterAddr = address(rejecter);

        handler.depositFees{value: 1 ether}(tokenA, rejecterAddr);

        vm.prank(rejecterAddr);
        vm.expectRevert(ILivoFeeHandler.EthTransferFailed.selector);
        handler.claim(_toArray(tokenA));
    }

    // ====================================================================
    //                      getClaimable() tests
    // ====================================================================

    /// @dev when queried for multiple tokens, then returns an array with correct per-token amounts
    function test_getClaimableMultipleTokens_assertCorrectAmounts()
        public
        depositFees(tokenA, alice, 1 ether)
        depositFees(tokenB, alice, 2 ether)
    {
        uint256[] memory claimable = handler.getClaimable(_toArray(tokenA, tokenB), alice);
        assertEq(claimable.length, 2, "array length should be 2");
        assertEq(claimable[0], 1 ether, "tokenA claimable incorrect");
        assertEq(claimable[1], 2 ether, "tokenB claimable incorrect");
    }

    /// @dev when queried for a token with no deposits, then returns 0
    function test_getClaimableNoDeposits_assertZero() public view {
        assertEq(_claimable(tokenA, alice), 0, "should be 0 for no deposits");
    }

    /// @dev when queried after a claim, then returns 0 for claimed tokens
    function test_getClaimableAfterClaim_assertZero()
        public
        depositFees(tokenA, alice, 1 ether)
        claimAs(alice, _toArray(tokenA))
    {
        assertEq(_claimable(tokenA, alice), 0, "should be 0 after claim");
    }
}
