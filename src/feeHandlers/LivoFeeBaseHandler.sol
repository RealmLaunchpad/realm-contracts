// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

contract LivoFeeBaseHandler is ILivoFeeHandler {
    mapping(address account => uint256 amount) pendingClaims;

    function depositFees(address account) external payable {
        pendingClaims[account] += msg.value;
        emit FeesDeposited(account, msg.value);
    }

    function claim() external {
        uint256 claimable = pendingClaims[msg.sender];
        if (claimable == 0) return;

        delete pendingClaims[msg.sender];
        emit FeesClaimed(msg.sender, claimable);

        (bool success,) = msg.sender.call{value: claimable}("");
        require(success, EthTransferFailed());
    }

    function getClaimable(address account) external view returns (uint256) {
        return pendingClaims[account];
    }
}
