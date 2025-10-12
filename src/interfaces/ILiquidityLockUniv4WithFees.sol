// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILiquidityLockUniv4WithFees {
    function lockUniV4Position(uint256 positionId, address positionReceiver) external;
    function claimUniV4PositionFees(uint256 positionId, address token0, address token1, address recipient) external;
    function lockOwners(uint256 positionId) external view returns (address);
}
