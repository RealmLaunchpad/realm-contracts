// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoGraduator {
    ////////////////// Events //////////////////////

    event PairInitialized(address indexed token, address indexed pair);
    event TokenGraduated(address indexed token, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity);
    event TreasuryGraduationFeeDeposited(address token, uint256 amount);
    event CreatorGraduationFeeDeposited(address token, address feeReceiver, uint256 amount);

    ////////////////// Custom errors //////////////////////

    error OnlyLaunchpadAllowed();
    error NoTokensToGraduate();
    error NoETHToGraduate();

    ////////////////// Functions //////////////////////

    function initialize(address tokenAddress) external returns (address pair);
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable;

    function whitelistFactory(address factory) external;
    function blacklistFactory(address factory) external;
}
