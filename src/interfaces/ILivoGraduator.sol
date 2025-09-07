// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoGraduator {
    function initializePair(address tokenAddress) external payable returns (address pair);
    function graduateToken(address tokenAddress) external payable;
}
