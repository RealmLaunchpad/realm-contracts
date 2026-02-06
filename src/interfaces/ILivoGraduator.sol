// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoGraduator {
    ////////////////// Events //////////////////////

    event PairInitialized(address indexed token, address indexed pair);

    ////////////////// Custom errors //////////////////////

    error OnlyLaunchpadAllowed();
    error NoTokensToGraduate();
    error NoETHToGraduate();

    ////////////////// Functions //////////////////////

    function initialize(address tokenAddress) external returns (address pair);
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable;
}
