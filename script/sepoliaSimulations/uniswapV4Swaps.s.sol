// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeploymentAddressesSepolia} from "../../src/config/DeploymentAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniswapV4UniversalRouter.sol";

/*
  Approve for sell:
  TOKEN_ADDRESS=0x... ACTION=1 AMOUNT_IN=1000000000000000000 forge script UniswapV4SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

  Buy swap:
  TOKEN_ADDRESS=0x... ACTION=2 AMOUNT_IN=1000000000000000 forge script UniswapV4SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

  Sell swap:
  TOKEN_ADDRESS=0x... ACTION=3 AMOUNT_IN=1000000000000000000 forge script UniswapV4SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast
*/

/// @title Uniswap V4 Swap Simulations for Sepolia
/// @notice Script to perform direct Uniswap V4 swaps (buy/sell) on Sepolia testnet
/// @dev Uses environment variables for configuration. Assumes token is already graduated.
contract UniswapV4Swaps is Script {
    // Pool configuration constants
    uint24 constant LP_FEE = 10000; // 1% fee
    int24 constant TICK_SPACING = 200;
    uint256 constant V4_SWAP = 0x10;

    /// @notice Constructs a PoolKey for the given token paired with ETH
    /// @param token The ERC20 token address
    /// @return key The configured PoolKey
    function _getPoolKey(address token) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(DeploymentAddressesSepolia.LIVO_SWAP_HOOK)
        });
    }

    /// @notice Executes a buy swap (ETH -> Token)
    /// @param token The token to buy
    /// @param ethAmountIn Amount of ETH to spend
    /// @param minTokensOut Minimum tokens to receive (0 accepts any slippage)
    function _swapBuy(address token, uint256 ethAmountIn, uint256 minTokensOut) internal {
        _swap(token, ethAmountIn, minTokensOut, true);
    }

    /// @notice Executes a sell swap (Token -> ETH)
    /// @param token The token to sell
    /// @param tokenAmountIn Amount of tokens to sell
    /// @param minEthOut Minimum ETH to receive (0 accepts any slippage)
    function _swapSell(address token, uint256 tokenAmountIn, uint256 minEthOut) internal {
        _swap(token, tokenAmountIn, minEthOut, false);
    }

    /// @notice Approves token spending for sell operations
    /// @param token The token to approve
    function approvals(address token) internal {
        IERC20(token).approve(DeploymentAddressesSepolia.PERMIT2, type(uint256).max);

        IPermit2(DeploymentAddressesSepolia.PERMIT2)
            .approve(
                address(token), DeploymentAddressesSepolia.UNIV4_UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max
            );
    }

    /// @notice Internal swap function for both buy and sell operations
    /// @param token The token to swap
    /// @param amountIn Amount of input token
    /// @param minAmountOut Minimum amount of output token
    /// @param isBuy True for ETH->Token, false for Token->ETH
    function _swap(address token, uint256 amountIn, uint256 minAmountOut, bool isBuy) internal {
        // Construct pool key
        PoolKey memory key = _getPoolKey(token);

        // Build swap parameters
        bytes[] memory params = new bytes[](3);

        // Parameter 0: Swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy, // true if swapping token0 (ETH) for token1 (buying)
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minAmountOut),
                hookData: bytes("")
            })
        );

        // Parameter 1: SETTLE_ALL - the token we are spending
        Currency tokenIn = isBuy ? key.currency0 : key.currency1;
        params[1] = abi.encode(tokenIn, amountIn);

        // Parameter 2: TAKE_ALL - the token we are receiving
        Currency tokenOut = isBuy ? key.currency1 : key.currency0;
        params[2] = abi.encode(tokenOut, minAmountOut);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Encode Universal Router command
        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        uint256 deadline = type(uint256).max;
        uint256 valueToSend = isBuy ? amountIn : 0;
        IUniversalRouter(DeploymentAddressesSepolia.UNIV4_UNIVERSAL_ROUTER).execute{value: valueToSend}(
            commands, inputs, deadline
        );
    }

    /// @notice Main entry point for the script
    /// @dev Reads configuration from environment variables:
    ///      - TOKEN_ADDRESS: The token to swap
    ///      - ACTION: 1=approve, 2=buy, 3=sell
    ///      - AMOUNT_IN: Amount of input token (in wei)
    ///      - MIN_AMOUNT_OUT: Minimum output (optional, defaults to 0)
    function run() public {
        vm.startBroadcast();

        address token = vm.envAddress("TOKEN_ADDRESS");
        uint256 action = vm.envUint("ACTION");
        uint256 amountIn = vm.envOr("AMOUNT_IN", uint256(0));

        console.log("Executing V4 action on Sepolia");
        console.log("Token:", token);
        console.log("Amount In:", amountIn);

        if (action == 0) {
            console.log("Action: APPROVE");
            approvals(token);
            console.log("Approvals completed");
        } else if (action == 1) {
            console.log("Action: BUY");
            _swapBuy(token, amountIn, 0);
            console.log("Buy completed");
        } else if (action == 2) {
            console.log("Action: SELL");
            _swapSell(token, amountIn, 0);
            console.log("Sell completed");
        } else {
            revert("Invalid ACTION. Use 0=approve, 1=buy, 2=sell");
        }

        vm.stopBroadcast();
    }
}
