// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountEth, uint256 liquidity);
}
