// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoGraduationManager {
    function checkGraduationEligibility(address tokenAddress) external view returns (bool);
    function graduateToken(address tokenAddress) external payable;
}
