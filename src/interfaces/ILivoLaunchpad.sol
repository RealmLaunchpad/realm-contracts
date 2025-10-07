// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoLaunchpad {
    function treasury() external view returns (address);
    function getTokenCreator(address token) external view returns (address);
}
