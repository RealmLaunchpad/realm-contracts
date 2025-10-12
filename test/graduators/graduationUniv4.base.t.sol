// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LivoToken} from "src/LivoToken.sol";
import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TokenState} from "src/types/tokenData.sol";
import {LivoGraduatorUniswapV4} from "src/graduators/LivoGraduatorUniswapV4.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";

/// @notice Tests for Uniswap V4 graduator functionality
contract BaseUniswapV4GraduationTests is LaunchpadBaseTestsWithUniv4Graduator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager poolManager;

    // these are copied from the graduator ...
    uint24 constant lpFee = 10000;
    int24 constant tickSpacing = 200;

    uint256 constant GRADUATION_PRICE = 39011306440; // ETH/token (eth per token, expressed in wei)

    // note this is hardcoded and should match the contract but it is not exposed as a public variable
    uint160 constant startingPriceX96 = 401129254579132618442796085280768;

    function setUp() public virtual override {
        super.setUp();
        poolManager = IPoolManager(poolManagerAddress);
    }

    //////////////////////////////////// modifiers and utilities ///////////////////////////////

    function _getPoolKey(address tokenAddress) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _graduateToken() internal {
        uint256 graduationThreshold = BASE_GRADUATION_THRESHOLD;
        uint256 ethAmountToGraduate = _increaseWithFees(graduationThreshold);

        _launchpadBuy(testToken, ethAmountToGraduate);
    }

    function _readSqrtX96TokenPrice() internal view returns (uint160) {
        // Check price is as expected
        PoolKey memory poolKey = _getPoolKey(testToken);
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        return sqrtPriceX96;
    }

    function _convertSqrtX96ToEthPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // price expressed as token1/token0 == tokens per native ETH
        // price = (sqrtPriceX96 / 2^96)^2 = (sqrtPriceX96^2) / 2^192
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
    }

    function _convertSqrtX96ToTokenPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // revert the sqrtprice and convert it as token price (how many tokens purchased with 1 ETH) with 18 decimals
        return (1e18 * 2 ** 192) / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
    }

    function _swapBuy(address caller, uint256 amountIn, uint256 minAmountOut, bool expectSuccess) internal {
        _swap(caller, testToken, amountIn, minAmountOut, true, expectSuccess);
    }

    function _swapSell(address caller, uint256 amountIn, uint256 minAmountOut, bool expectSuccess) internal {
        _swap(caller, testToken, amountIn, minAmountOut, false, expectSuccess);
    }

    function _swap(
        address caller,
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBuy,
        bool expectSuccess
    ) internal {
        vm.startPrank(caller);
        IERC20(token).approve(address(permit2Address), type(uint256).max);
        IPermit2(permit2Address).approve(address(token), universalRouter, type(uint160).max, type(uint48).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(token)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        bytes[] memory params = new bytes[](3);

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy, // true if we're swapping token0 for token1 (buying tokens with eth)
                amountIn: uint128(amountIn), // amount of tokens we're swapping
                amountOutMinimum: uint128(minAmountOut), // minimum amount we expect to receive
                hookData: bytes("") // no hook data needed
            })
        );

        // Encode the Universal Router command
        uint256 V4_SWAP = 0x10;
        bytes memory commands = abi.encodePacked(uint8(V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // the token we are getting rid of
        Currency tokenIn = isBuy ? key.currency0 : key.currency1;
        params[1] = abi.encode(tokenIn, amountIn);
        // the token we are receiving
        Currency tokenOut = isBuy ? key.currency1 : key.currency0;
        params[2] = abi.encode(tokenOut, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        if (!expectSuccess) {
            vm.expectRevert();
        }
        // Execute the swap
        uint256 valueIn = isBuy ? amountIn : 0;
        IUniversalRouter(universalRouter).execute{value: valueIn}(commands, inputs, block.timestamp);
        vm.stopPrank();
    }

    function _addEthLiquidity(address caller, uint256 ethValue) internal {
        // current price pool (starting price), which is a tick of 170600
        uint160 graduationPriceX96_tokensPerEth = 401129254579132618442796085280768;
        // the liquidity position added with eth needs to be higher in sqrt (lower token price as it is a buy order)
        // token price below graduation (eth position as a buy order)

        // tick to sqrtX96: tick: 190000 -> sqrtX96: 1057963989655568602524443675197440 -> price: 178312834.58383808 tokens/ETH
        int24 tickUpper = 190000;
        uint160 highTickSqrtPriceX96 = 1057963989655568602524443675197440;
        // tick to sqrtX96: tick: 180000 -> sqrtX96: 641703637919055130081021191520256 -> price: 65600905.68504753 tokens/ETH
        int24 tickLower = 180000;
        uint160 lowTickSqrtPriceX96 = 641703637919055130081021191520256;
        _addLiquidity(
            caller,
            ethValue,
            0, // no tokens
            tickUpper,
            tickLower,
            graduationPriceX96_tokensPerEth, // current price
            lowTickSqrtPriceX96,
            highTickSqrtPriceX96,
            true // false if expectRevert
        );
    }

    function _addMixedLiquidity(address caller, uint256 ethValue, uint256 tokenAmount, bool expectSuccess) internal {
        // current price pool (starting price), which is a tick of 170600
        uint160 graduationPriceX96_tokensPerEth = 401129254579132618442796085280768;

        // tick to sqrtX96: tick: 160600 -> sqrtX96: 243270762183760163063399461158912 -> price: 178312834.58383808 tokens/ETH
        int24 tickLower = 160600;
        uint160 lowTickSqrtPriceX96 = 243270762183760163063399461158912;
        // tick to sqrtX96: tick: 180000 -> sqrtX96: 641703637919055130081021191520256 -> price: 65600905.68504753 tokens/ETH
        int24 tickUpper = 180000;
        uint160 highTickSqrtPriceX96 = 641703637919055130081021191520256;

        _addLiquidity(
            caller,
            ethValue,
            tokenAmount, // some tokens
            tickUpper,
            tickLower,
            graduationPriceX96_tokensPerEth, // current price
            lowTickSqrtPriceX96,
            highTickSqrtPriceX96,
            expectSuccess // false if expectRevert
        );
    }

    function _addLiquidity(
        address caller,
        uint256 ethValue,
        uint256 tokenAmount,
        int24 tickUpper,
        int24 tickLower,
        uint160 currentX96price,
        uint160 sqrtPriceX96Lower,
        uint160 sqrtPriceX96Upper,
        bool expectSuccess
    ) internal {
        vm.startPrank(caller);

        // approve permit2 as a spender
        IERC20(testToken).approve(address(permit2Address), type(uint256).max);

        // approve `PositionManager` as a spender
        IAllowanceTransfer(address(permit2Address)).approve(
            address(testToken), // approved token
            address(positionManagerAddress), // spender
            type(uint160).max, // amount
            type(uint48).max // expiration
        );

        PoolKey memory pool = _getPoolKey(testToken);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            uint160(currentX96price), // current pool price --> presumably the starting price which cannot be modified until graduation
            uint160(sqrtPriceX96Lower), // lower tick price -> max token price denominated in eth
            uint160(sqrtPriceX96Upper), // upper tick price -> min token price denominated in eth
            ethValue, // desired amount0
            tokenAmount // desired amount1
        );

        // Actions for ETH liquidity positions
        // 1. Mint position
        // 2. Settle pair (send ETH and tokens)
        // 3. Sweep any remaining native ETH back to the treasury (only required with native eth positions)
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);

        // parameters for MINT_POSITION action
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, address(this), "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, caller); // sweep all remaining native ETH to recipient

        if (!expectSuccess) vm.expectRevert();
        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(positionManagerAddress).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );

        vm.stopPrank();
    }
}
