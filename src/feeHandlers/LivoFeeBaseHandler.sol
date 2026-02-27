// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.28;

// import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

// contract LivoFeeBaseHandler is ILivoFeeHandler {
//     error EthTransferFailed();

//     event FeesDeposited(address indexed account, uint256 amount);
//     event FeesClaimed(address indexed account, uint256 amount);

//     /// @notice pending balance to claim
//     mapping(address account => uint256 amount) pendingClaims;

//     /// @notice Deposits msg.value into `account` balance
//     function depositFees(address account) external payable {
//         pendingClaims[account] += msg.value;

//         emit FeesDeposited(account, msg.value);
//     }

//     /// @notice Claims accumulated ETH fees for msg.sender
//     function claim() external {
//         uint256 claimable = pendingClaims[msg.sender];

//         if (claimable == 0) return;

//         delete pendingClaims[msg.sender];

//         emit FeesClaimed(msg.sender, claimable);

//         (bool success,) = msg.sender.call{value: claimable}("");
//         require(success, EthTransferFailed());
//     }

//     /////////////////// view ////////////////////////

//     /// @notice Returns the pending ETH fees for `account`
//     function getClaimable(address account) public view returns (uint256) {
//         return pendingClaims[account];
//     }
// }
