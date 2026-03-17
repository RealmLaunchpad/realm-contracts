// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ILivoBondingCurve {
    // thrown if trying to buy above graduation threshold + margin
    error MaxEthReservesExceeded();
    // thrown if requesting more tokens/eth than the curve can provide
    error InsufficientLiquidity();

    struct GraduationConfig {
        uint256 ethGraduationThreshold;
        uint256 maxExcessOverThreshold;
    }

    /// @notice Returns the graduation configuration
    function getGraduationConfig() external view returns (GraduationConfig memory);

    /// @notice how many tokens can be purchased with a given amount of ETH
    function buyTokensWithExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensReceived, bool canGraduate);

    /// @notice how much ETH will be received when selling an exact amount of tokens
    function sellExactTokens(uint256 ethReserves, uint256 tokenAmount) external view returns (uint256 ethReceived);

    /// @notice How much ETH is required to buy an exact amount of tokens
    function buyExactTokens(uint256 ethReserves, uint256 tokenAmount)
        external
        view
        returns (uint256 ethRequired, bool canGraduate);

    /// @notice How many tokens must be sold to receive an exact amount of ETH
    function sellTokensForExactEth(uint256 ethReserves, uint256 ethAmount)
        external
        view
        returns (uint256 tokensRequired);

    /// @notice When this eth reserves are matched, the token can graduate
    function ethGraduationThreshold() external view returns (uint256);

    /// @notice The maximum excess over the graduation threshold, above which the token cannot graduate
    function maxExcessOverThreshold() external view returns (uint256);

    /// @notice Maximum ETH reserves allowed (threshold + max excess)
    function maxEthReserves() external view returns (uint256);
}
