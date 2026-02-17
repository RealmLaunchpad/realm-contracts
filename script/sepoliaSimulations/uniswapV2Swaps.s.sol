// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentAddressesSepolia} from "../../src/config/DeploymentAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2Router02.sol";

/*
  Buy swap (ETH -> Token via WETH):
  TOKEN_ADDRESS=0x... IS_BUY=true AMOUNT_IN=1000000000000000 forge script UniswapV2SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --broadcast

  Sell swap (Token -> WETH):
  TOKEN_ADDRESS=0x... IS_BUY=false AMOUNT_IN=1000000000000000000 forge script UniswapV2SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --broadcast
*/

/// @title Uniswap V2 Swap Simulations for Sepolia
/// @notice Script to perform Uniswap V2 swaps (buy/sell) on Sepolia testnet
/// @dev Uses environment variables for configuration
contract UniswapV2Swaps is Script {
    IWETH constant WETH = IWETH(DeploymentAddressesSepolia.WETH);
    IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(DeploymentAddressesSepolia.UNIV2_ROUTER);

    /// @notice Executes a buy swap (ETH -> WETH -> Token)
    /// @param token The token to buy
    /// @param ethAmount Amount of ETH to spend
    /// @param minTokens Minimum tokens to receive (0 accepts any slippage)
    function _swapBuy(address token, uint256 ethAmount, uint256 minTokens) internal {
        // Deposit ETH to WETH
        WETH.deposit{value: ethAmount}();

        // Approve WETH to router
        WETH.approve(address(ROUTER), ethAmount);

        // Build swap path: WETH -> Token
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = token;

        // Execute swap
        ROUTER.swapExactTokensForTokens(ethAmount, minTokens, path, msg.sender, block.timestamp + 1 hours);
    }

    /// @notice Executes a sell swap (Token -> WETH)
    /// @param token The token to sell
    /// @param tokenAmount Amount of tokens to sell
    /// @param minWeth Minimum WETH to receive (0 accepts any slippage)
    function _swapSell(address token, uint256 tokenAmount, uint256 minWeth) internal {
        // Approve token to router
        IERC20(token).approve(address(ROUTER), tokenAmount);

        // Build swap path: Token -> WETH
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(WETH);

        // Execute swap
        ROUTER.swapExactTokensForTokens(tokenAmount, minWeth, path, msg.sender, block.timestamp + 1 hours);
    }

    /// @notice Main entry point for the script
    /// @dev Reads configuration from environment variables:
    ///      - TOKEN_ADDRESS: The token to swap
    ///      - IS_BUY: true for ETH->Token, false for Token->WETH
    ///      - AMOUNT_IN: Amount of input token (in wei)
    ///      - MIN_AMOUNT_OUT: Minimum output (optional, defaults to 0)
    function run() public {
        vm.startBroadcast();

        address token = vm.envAddress("TOKEN_ADDRESS");
        bool isBuy = vm.envBool("IS_BUY");
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        uint256 minAmountOut = vm.envOr("MIN_AMOUNT_OUT", uint256(0));

        console.log("Executing V2 swap on Sepolia");
        console.log("Token:", token);
        console.log("Direction:", isBuy ? "BUY" : "SELL");
        console.log("Amount In:", amountIn);

        if (isBuy) {
            _swapBuy(token, amountIn, minAmountOut);
        } else {
            _swapSell(token, amountIn, minAmountOut);
        }

        console.log("Swap completed");

        vm.stopBroadcast();
    }
}
