// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    // thrown if trying to buy above graduation threshold + margin
    error MaxEthReservesExceeded();

    /// @notice how many tokens can be purchased with a given amount of ETH
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived, bool canGraduate);

    /// @notice how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external view returns (uint256 ethReceived);

    /// @notice When this eth reserves are matched, the token can graduate
    function ethGraduationThreshold() external view returns (uint256);

    /// @notice The maximum excess over the graduation threshold, above which the token cannot graduate
    function maxExcessOverThreshold() external view returns (uint256);

    /// @notice Maximum ETH reserves allowed (threshold + max excess)
    function maxEthReserves() external view returns (uint256);
}
