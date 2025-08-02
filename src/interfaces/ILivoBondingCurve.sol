// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILivoBondingCurve {
    function getBuyPrice(uint256 ethAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256);
    function getSellPrice(uint256 tokenAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256);
    function getTokensForEth(uint256 ethAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256);
    function getEthForTokens(uint256 tokenAmount, uint256 totalSupply, uint256 ethSupply) external pure returns (uint256);
}