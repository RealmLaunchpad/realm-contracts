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

    // ======================== distribute ========================

    function test_distribute_splitsCorrectly() public {
        // deposit fees for the splitter address
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        splitter.distribute(tokens);

        assertEq(alice.balance - aliceBefore, 7 ether, "alice should get 70%");
        assertEq(bob.balance - bobBefore, 3 ether, "bob should get 30%");
    }

    function test_distribute_lastRecipientGetsRoundingDust() public {
        // deposit an amount that doesn't divide evenly
        feeHandler.depositFees{value: 1 ether + 1}(address(token), address(splitter));

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        splitter.distribute(tokens);

        uint256 total = 1 ether + 1;
        uint256 aliceExpected = (total * 7000) / 10000;
        uint256 bobExpected = total - aliceExpected;

        assertEq(alice.balance - aliceBefore, aliceExpected);
        assertEq(bob.balance - bobBefore, bobExpected);
        // verify no dust left in splitter
        assertEq(address(splitter).balance, 0);
    }

    function test_distribute_noopWhenNoFees() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        // should not revert
        splitter.distribute(tokens);
    }

    function test_distribute_emitsEvents() public {
        feeHandler.depositFees{value: 10 ether}(address(token), address(splitter));

        vm.expectEmit(true, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesDistributed(alice, 7 ether);
        vm.expectEmit(true, false, false, true, address(splitter));
        emit ILivoFeeSplitter.FeesDistributed(bob, 3 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        splitter.distribute(tokens);
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
