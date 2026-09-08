// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests} from "test/launchpad/base.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// @notice Reusable V4 swap helpers for end-to-end tests. Mirrors the swap logic from
///         test/graduators/graduationUniv4.base.t.sol and test/graduators/taxToken.base.t.sol so
///         the E2E suite can swap on any Realm-graduated V4 pool regardless of token variant.
abstract contract V4SwapHelpers is LaunchpadBaseTests {
    uint24 internal constant E2E_LP_FEE = UniswapV4PoolConstants.LP_FEE;
    int24 internal constant E2E_TICK_SPACING = UniswapV4PoolConstants.TICK_SPACING;

    function _v4PoolKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: E2E_LP_FEE,
            tickSpacing: E2E_TICK_SPACING,
            hooks: IHooks(address(taxHook))
        });
    }

    function _swapBuyV4(address caller, address token, uint256 ethIn, uint256 minOut, bool expectSuccess) internal {
        _swapV4(caller, token, ethIn, minOut, true, expectSuccess);
    }

    function _swapSellV4(address caller, address token, uint256 tokenIn, uint256 minEth, bool expectSuccess)
        internal
        returns (uint256 ethReceived)
    {
        uint256 before = caller.balance;
        _swapV4(caller, token, tokenIn, minEth, false, expectSuccess);
        if (expectSuccess) ethReceived = caller.balance - before;
    }

    function _swapV4(address caller, address token, uint256 amountIn, uint256 minOut, bool isBuy, bool expectSuccess)
        internal
    {
        vm.startPrank(caller);
        IERC20(token).approve(permit2Address, type(uint256).max);
        IPermit2(permit2Address).approve(token, universalRouter, type(uint160).max, type(uint48).max);

        PoolKey memory key = _v4PoolKey(token);
        bytes[] memory params = new bytes[](3);

        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: bytes("")
            })
        );

        Currency tokenIn = isBuy ? key.currency0 : key.currency1;
        params[1] = abi.encode(tokenIn, amountIn);
        Currency tokenOut = isBuy ? key.currency1 : key.currency0;
        params[2] = abi.encode(tokenOut, minOut);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes memory commands = abi.encodePacked(uint8(0x10)); // V4_SWAP
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        if (!expectSuccess) vm.expectRevert();

        uint256 valueIn = isBuy ? amountIn : 0;
        IUniversalRouter(universalRouter).execute{value: valueIn}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }
}
