// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    MasterFeeHandlerTestHelpers,
    MockMasterFeeToken,
    MasterFeeEthRejecter
} from "test/helpers/MasterFeeHandlerTestHelpers.sol";
import {IRealmMasterFeeHandler} from "src/interfaces/IRealmMasterFeeHandler.sol";
import {IRealmClaims} from "src/interfaces/IRealmClaims.sol";

contract RealmMasterFeeHandlerSingleRecipientTests is MasterFeeHandlerTestHelpers {
    MockMasterFeeToken internal tokenA;
    MockMasterFeeToken internal tokenB;
    MockMasterFeeToken internal tokenC;

    function setUp() public override {
        super.setUp();
        tokenA = _newRegisteredToken(creator, _fs(creator));
        tokenB = _newRegisteredToken(creator, _fs(creator));
        tokenC = _newRegisteredToken(creator, _fs(creator));
    }

    modifier depositFees(MockMasterFeeToken token, uint256 amount) {
        _deposit(token, amount);
        _;
    }

    modifier claimAs(address claimer, address[] memory tokens) {
        _claimAs(claimer, tokens);
        _;
    }

    // ======================== depositFees() ========================

    function test_depositFees_assertClaimableIncreases() public depositFees(tokenA, 1 ether) {
        assertEq(_claimable(address(tokenA), creator), 1 ether, "claimable should equal deposited amount");
    }

    function test_depositFeesTwice_assertCumulativeClaimable()
        public
        depositFees(tokenA, 1 ether)
        depositFees(tokenA, 2 ether)
    {
        assertEq(_claimable(address(tokenA), creator), 3 ether, "claimable should be cumulative");
    }

    function test_depositFeesDifferentTokens_assertIndependent()
        public
        depositFees(tokenA, 1 ether)
        depositFees(tokenB, 2 ether)
    {
        assertEq(_claimable(address(tokenA), creator), 1 ether, "tokenA claimable incorrect");
        assertEq(_claimable(address(tokenB), creator), 2 ether, "tokenB claimable incorrect");
    }

    function test_depositFeesZero_assertClaimableUnchanged() public depositFees(tokenA, 0) {
        assertEq(_claimable(address(tokenA), creator), 0, "claimable should remain 0");
    }

    function test_depositFees_assertEventEmitted() public {
        vm.expectEmit(true, false, false, true, address(handler));
        emit IRealmMasterFeeHandler.CreatorFeesDeposited(address(tokenA), 1 ether);
        _deposit(tokenA, 1 ether);
    }

    function test_depositFees_unregisteredPositiveValue_panicsOnEmptyConfig() public {
        MockMasterFeeToken unregistered = _newToken(creator);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x32));
        handler.depositFees{value: 1 ether}(address(unregistered));
    }

    // ======================== claim() ========================

    function test_claimSingleToken_assertBalanceAndClaimable() public depositFees(tokenA, 3 ether) {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_single(address(tokenA)));

        assertEq(creator.balance - balanceBefore, 3 ether, "creator should receive 3 ether");
        assertEq(_claimable(address(tokenA), creator), 0, "claimable should be 0 after claim");
    }

    function test_claimMultipleTokens_assertTotalBalance()
        public
        depositFees(tokenA, 1 ether)
        depositFees(tokenB, 2 ether)
        depositFees(tokenC, 0.5 ether)
    {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_tokens(address(tokenA), address(tokenB), address(tokenC)));

        assertEq(creator.balance - balanceBefore, 3.5 ether, "creator should receive total across tokens");
    }

    function test_claimNoPending_assertNoTransfer() public {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_single(address(tokenA)));

        assertEq(creator.balance, balanceBefore, "balance should be unchanged");
    }

    function test_claim_assertCreatorClaimedEvents() public depositFees(tokenA, 1 ether) depositFees(tokenB, 2 ether) {
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmClaims.CreatorClaimed(address(tokenA), creator, 1 ether);
        vm.expectEmit(true, true, false, true, address(handler));
        emit IRealmClaims.CreatorClaimed(address(tokenB), creator, 2 ether);

        vm.prank(creator);
        handler.claim(_tokens(address(tokenA), address(tokenB)));
    }

    function test_claimPartialFees_assertSelectiveClaim() public depositFees(tokenA, 1 ether) {
        uint256 balanceBefore = creator.balance;

        vm.prank(creator);
        handler.claim(_tokens(address(tokenA), address(tokenB)));

        assertEq(creator.balance - balanceBefore, 1 ether, "should only claim from tokenA");
        assertEq(_claimable(address(tokenA), creator), 0, "tokenA claimable should be 0");
        assertEq(_claimable(address(tokenB), creator), 0, "tokenB claimable should be 0");
    }

    function test_claimDuplicateToken_doesNotDoubleCount() public depositFees(tokenA, 1 ether) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenA);

        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        handler.claim(tokens);

        assertEq(creator.balance - balanceBefore, 1 ether, "duplicate token should not double count");
        assertEq(_claimable(address(tokenA), creator), 0, "tokenA claimable should be 0");
    }

    function test_claimEthTransferFails_assertReverts() public {
        MasterFeeEthRejecter rejecter = new MasterFeeEthRejecter();
        MockMasterFeeToken rejecterToken = _newRegisteredToken(address(rejecter), _fs(address(rejecter)));

        _deposit(rejecterToken, 1 ether);

        vm.prank(address(rejecter));
        vm.expectRevert(IRealmClaims.EthTransferFailed.selector);
        handler.claim(_single(address(rejecterToken)));
    }

    // ======================== getClaimable() ========================

    function test_getClaimableMultipleTokens_assertCorrectAmounts()
        public
        depositFees(tokenA, 1 ether)
        depositFees(tokenB, 2 ether)
    {
        uint256[] memory claimable = handler.getClaimable(_tokens(address(tokenA), address(tokenB)), creator);
        assertEq(claimable.length, 2, "array length should be 2");
        assertEq(claimable[0], 1 ether, "tokenA claimable incorrect");
        assertEq(claimable[1], 2 ether, "tokenB claimable incorrect");
    }

    function test_getClaimableNoDeposits_assertZero() public view {
        assertEq(_claimable(address(tokenA), creator), 0, "should be 0 for no deposits");
    }

    function test_getClaimableAfterClaim_assertZero()
        public
        depositFees(tokenA, 1 ether)
        claimAs(creator, _single(address(tokenA)))
    {
        assertEq(_claimable(address(tokenA), creator), 0, "should be 0 after claim");
    }
}
