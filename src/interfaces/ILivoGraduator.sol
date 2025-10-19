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

    function initializePair(address tokenAddress) external returns (address pair);
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable;

    /// @notice Returns the graduation threshold, the margin above it that ETH reserves can reach at graduation and the graduation fee
    /// @dev These need to be linked as they would have an effect on the effective price post graduation
    function getGraduationSettings()
        external
        returns (uint256 graduationThreshold, uint256 maxExcessOverThreshold, uint256 graduationEthFee);
}
