// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV4ClaimFeesViewFunctionsBase} from "test/graduators/graduationUniv4.claimFees.t.sol";

contract UniswapV4ClaimFeesViewFunctions_NormalToken is UniswapV4ClaimFeesViewFunctionsBase {
    function setUp() public override {
        super.setUp();
    }

    function _expectsSellTaxes() internal pure override returns (bool) {
        return false;
    }

    /// @notice When feeReceiver != tokenOwner at creation, getClaimable returns non-zero for feeReceiver
    function test_viewFunction_getClaimable_feeReceiverDifferentFromOwner() public {
        // Create token with creator as msg.sender (owner), alice as feeReceiver
        vm.prank(creator);
        testToken = factoryV4.createToken("TestToken", "TEST", alice, "0x12");

        _graduateToken();

        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        uint256[] memory feeReceiverFees = feeHandler.getClaimable(_singleTokenArray(), alice);
        assertGt(feeReceiverFees[0], 0, "feeReceiver should have non-zero claimable");
    }

    /// @notice When feeReceiver != tokenOwner at creation, getClaimable returns zero for tokenOwner
    function test_viewFunction_getClaimable_tokenOwnerGetsZeroWhenNotFeeReceiver() public {
        // Create token with creator as msg.sender (owner), alice as feeReceiver
        vm.prank(creator);
        testToken = factoryV4.createToken("TestToken", "TEST", alice, "0x12");

        _graduateToken();

        deal(buyer, 10 ether);
        _swapBuy(buyer, 1 ether, 10e18, true);

        uint256[] memory ownerFees = feeHandler.getClaimable(_singleTokenArray(), creator);
        assertEq(ownerFees[0], 0, "tokenOwner should have zero claimable when not feeReceiver");
    }
}
