// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LivoFeeHandlerUniV4} from "src/feeHandlers/LivoFeeHandlerUniV4.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoClaims} from "src/interfaces/ILivoClaims.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @dev Minimal mock launchpad returning a treasury address
contract MockLaunchpad {
    address public treasury;

    constructor(address _treasury) {
        treasury = _treasury;
    }
}

/// @dev Minimal mock that pretends to be a liquidity lock (not called in these tests)
contract MockLiquidityLock {}

/// @dev Minimal mock token that returns a fee receiver
contract MockToken {
    address public feeReceiver;

    constructor(address _feeReceiver) {
        feeReceiver = _feeReceiver;
    }
}

contract LivoFeeHandlerUniV4SweepExcessTests is Test {
    LivoFeeHandlerUniV4 public handler;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public creator = makeAddr("creator");
    address public alice = makeAddr("alice");
    address public tokenA;
    address public tokenB;

    function setUp() public {
        MockLaunchpad mockLaunchpad = new MockLaunchpad(treasury);
        MockLiquidityLock mockLock = new MockLiquidityLock();

        tokenA = address(new MockToken(creator));
        tokenB = address(new MockToken(alice));

        vm.prank(owner);
        handler = new LivoFeeHandlerUniV4(
            address(mockLaunchpad),
            address(mockLock),
            address(1), // poolManager (unused in these tests)
            address(2), // positionManager (unused)
            address(3) // hook (unused)
        );
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

    // ======================== depositFees tracking ========================

    function test_depositFees_tracksTotalPendingCreatorClaims() public {
        handler.depositFees{value: 1 ether}(tokenA, creator);
        assertEq(handler.totalPendingCreatorClaims(), 1 ether);

        handler.depositFees{value: 2 ether}(tokenB, creator);
        assertEq(handler.totalPendingCreatorClaims(), 3 ether);
    }

    function test_depositFees_tracksDifferentReceivers() public {
        handler.depositFees{value: 1 ether}(tokenA, creator);
        handler.depositFees{value: 0.5 ether}(tokenA, alice);
        assertEq(handler.totalPendingCreatorClaims(), 1.5 ether);
    }

    // ======================== claim decrements tracker ========================

    function test_claim_decrementsTotalPendingCreatorClaims() public {
        handler.depositFees{value: 3 ether}(tokenA, creator);
        handler.depositFees{value: 2 ether}(tokenB, creator);
        assertEq(handler.totalPendingCreatorClaims(), 5 ether);

        vm.prank(creator);
        handler.claim(_toArray(tokenA));
        assertEq(handler.totalPendingCreatorClaims(), 2 ether);

        vm.prank(creator);
        handler.claim(_toArray(tokenB));
        assertEq(handler.totalPendingCreatorClaims(), 0);
    }

    function test_claim_noPending_trackerUnchanged() public {
        handler.depositFees{value: 1 ether}(tokenA, creator);

        // alice has nothing to claim
        vm.prank(alice);
        handler.claim(_toArray(tokenA));
        assertEq(handler.totalPendingCreatorClaims(), 1 ether);
    }

    // ======================== sweepExcessEth ========================

    function test_sweepExcessEth_sweepsExcess() public {
        // deposit fees + send extra ETH
        handler.depositFees{value: 2 ether}(tokenA, creator);
        vm.deal(address(handler), 5 ether); // 3 ether excess

        uint256 balBefore = alice.balance;
        vm.prank(owner);
        handler.sweepExcessEth(alice);

        assertEq(alice.balance - balBefore, 3 ether, "should receive excess");
        assertEq(address(handler).balance, 2 ether, "pending claims untouched");
        assertEq(handler.totalPendingCreatorClaims(), 2 ether, "tracker unchanged");
    }

    function test_sweepExcessEth_noExcess_noTransfer() public {
        handler.depositFees{value: 2 ether}(tokenA, creator);

        uint256 balBefore = alice.balance;
        vm.prank(owner);
        handler.sweepExcessEth(alice);

        assertEq(alice.balance, balBefore, "no transfer when no excess");
    }

    function test_sweepExcessEth_revertsForNonOwner() public {
        vm.deal(address(handler), 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        handler.sweepExcessEth(alice);
    }

    function test_sweepExcessEth_doesNotTouchPendingClaims() public {
        handler.depositFees{value: 1 ether}(tokenA, creator);
        handler.depositFees{value: 2 ether}(tokenB, alice);
        // send extra
        vm.deal(address(handler), 4 ether); // 1 ether excess

        vm.prank(owner);
        handler.sweepExcessEth(owner);

        // verify both creators can still claim their full amounts
        uint256 creatorBal = creator.balance;
        vm.prank(creator);
        handler.claim(_toArray(tokenA));
        assertEq(creator.balance - creatorBal, 1 ether, "creator claim intact");

        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        handler.claim(_toArray(tokenB));
        assertEq(alice.balance - aliceBal, 2 ether, "alice claim intact");

        assertEq(handler.totalPendingCreatorClaims(), 0, "all claimed");
        assertEq(address(handler).balance, 0, "contract empty");
    }

    // ======================== Full lifecycle ========================

    function test_fullLifecycle_depositClaimSweep() public {
        // 1. Deposit fees
        handler.depositFees{value: 3 ether}(tokenA, creator);
        assertEq(handler.totalPendingCreatorClaims(), 3 ether);

        // 2. Someone sends ETH directly (stuck)
        vm.deal(address(handler), 5 ether); // 2 ether excess
        assertEq(handler.totalPendingCreatorClaims(), 3 ether, "tracker unaffected by direct send");

        // 3. Creator claims
        vm.prank(creator);
        handler.claim(_toArray(tokenA));
        assertEq(handler.totalPendingCreatorClaims(), 0);
        assertEq(address(handler).balance, 2 ether, "only excess remains");

        // 4. Sweep excess
        vm.prank(owner);
        handler.sweepExcessEth(treasury);
        assertEq(address(handler).balance, 0, "fully swept");
    }
}
