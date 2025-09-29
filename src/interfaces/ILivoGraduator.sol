// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoGraduator {

    ////////////////// Events //////////////////////
    
    event TokenGraduated(
        address indexed token, address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );
    event PairInitialized(address indexed token, address indexed pair);


    ////////////////// Custom errors //////////////////////
    
    error OnlyLaunchpadAllowed();
    error NoTokensToGraduate();
    error NoETHToGraduate();

    ////////////////// Functions //////////////////////

    function initializePair(address tokenAddress) external returns (address pair);
    function graduateToken(address tokenAddress) external payable;
}
