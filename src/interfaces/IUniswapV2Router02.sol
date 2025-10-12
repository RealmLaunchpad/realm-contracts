// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2Router} from "./IUniswapV2Router.sol";

interface IUniswapV2Router02 is IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
