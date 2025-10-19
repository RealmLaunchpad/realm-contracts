// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    /// @notice how many tokens can be purchased with a given amount of ETH
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived);

    /// @notice how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external view returns (uint256 ethReceived);

    /// @notice Returns the graduation threshold and the margin above it that ETH reserves can reach at graduation
    function getGraduationSettings() external view returns (uint256 graduationThreshold, uint256 maxExcessOverThreshold);
}
