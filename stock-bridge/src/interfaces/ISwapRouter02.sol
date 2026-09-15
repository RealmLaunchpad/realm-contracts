// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal interface for Uniswap's SwapRouter02. Name and signatures must match the deployed
/// router, so they are kept verbatim.
/// @dev SwapRouter02 has NO per-call `deadline` field on exactInputSingle (removed vs the original
/// SwapRouter) — do not add one. `exactInputSingle` is `payable`: sending native ETH as `msg.value`
/// with `tokenIn == WETH` makes the router auto-wrap it, which is how the ETH deposit path works.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice The WETH functions used here: withdraw() to unwrap to native ETH on the redeem-to-ETH path,
/// deposit() to re-wrap on the send-failure fallback.
interface IWETH {
    function withdraw(uint256 amount) external;
    function deposit() external payable;
}
