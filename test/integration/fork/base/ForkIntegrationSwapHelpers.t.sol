// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkIntegrationBase} from "test/integration/fork/base/ForkIntegrationBase.t.sol";

interface IUniV2RouterSwapFork {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Chain-neutral post-graduation Uniswap swap helpers for fork integration tests.
abstract contract ForkIntegrationSwapHelpers is ForkIntegrationBase {
    function _swapBuyV2(address caller, address token, uint256 ethIn, uint256 minOut) internal {
        address[] memory path = new address[](2);
        path[0] = forkCfg.weth;
        path[1] = token;

        vm.prank(caller);
        IUniV2RouterSwapFork(forkCfg.uniV2Router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            minOut, path, caller, block.timestamp
        );
    }

    function _swapSellV2(address caller, address token, uint256 tokenIn, uint256 minEth)
        internal
        returns (uint256 ethReceived)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = forkCfg.weth;

        uint256 beforeBal = caller.balance;
        vm.startPrank(caller);
        IERC20(token).approve(forkCfg.uniV2Router, type(uint256).max);
        IUniV2RouterSwapFork(forkCfg.uniV2Router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(tokenIn, minEth, path, caller, block.timestamp);
        vm.stopPrank();
        ethReceived = caller.balance - beforeBal;
    }
}
