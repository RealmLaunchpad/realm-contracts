// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";

interface ILivoFeeSplitter is ILivoFeeHandler {
    event FeesClaimed(address indexed account, uint256 amount);
    event FeesAccrued(uint256 amount);
    event SharesUpdated(address[] recipients, uint256[] sharesBps);

    error InvalidRecipients();
    error InvalidShares();
    error Unauthorized();

    function initialize(address feeHandler, address token, address[] calldata recipients, uint256[] calldata sharesBps)
        external;

    function setShares(address[] calldata recipients, uint256[] calldata sharesBps) external;

    function getRecipients() external view returns (address[] memory, uint256[] memory);
}
