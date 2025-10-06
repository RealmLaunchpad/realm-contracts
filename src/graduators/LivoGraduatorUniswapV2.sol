// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

contract LivoGraduatorUniswapV2 is ILivoGraduator {
    using SafeERC20 for ILivoToken;

    /// @notice where LP tokens are sent at graduation, effectively locking the liquidity
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    address public immutable LIVO_LAUNCHPAD;

    /// @notice Uniswap router and factory addresses
    IUniswapV2Router internal immutable UNISWAP_ROUTER;
    IUniswapV2Factory internal immutable UNISWAP_FACTORY;
    address internal immutable WETH;

    constructor(address _uniswapRouter, address _launchpad) {
        LIVO_LAUNCHPAD = _launchpad;
        UNISWAP_ROUTER = IUniswapV2Router(_uniswapRouter);

        WETH = UNISWAP_ROUTER.WETH();
        UNISWAP_FACTORY = IUniswapV2Factory(UNISWAP_ROUTER.factory());
    }

    modifier onlyLaunchpad() {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        _;
    }

    function initializePair(address tokenAddress) external override onlyLaunchpad returns (address pair) {
        pair = UNISWAP_FACTORY.createPair(tokenAddress, WETH);
        emit PairInitialized(tokenAddress, pair);
    }

    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        // eth can only enter through msg.value, and all of it is deposited as liquidity
        uint256 ethValue = msg.value;
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethValue > 0, NoETHToGraduate());

        // the pair should have been pre-created at token launch.
        // If not, pair==address(0) and graduation will revert
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, WETH);

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // Approve the router to handle the tokens for liquidity addition
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokenBalance);

        // syncs and reads the actual reserves in the pair (in case there is unsynced ETH)
        uint256 ethReserve = _getUpdatedEthReserves(pair, tokenAddress);

        uint256 amountToken;
        uint256 amountEth;
        uint256 liquidity;
        // We ensure that the token reserve is zero by forbidding transfers to the pair pre-graduation
        // Therefore, here we only need to check if there is ETH in the pair
        if (ethReserve == 0) {
            (amountToken, amountEth, liquidity) = _naiveLiquidityAddition(tokenAddress, tokenBalance, ethValue);
        } else {
            // This path would almost never be executed. But we need to protect against attacks
            // trying to DOS the graduation by sending ETH to the pair pre-graduation
            (amountToken, amountEth, liquidity) =
                _addLiquidityWithPriceMatching(tokenAddress, ethReserve, tokenBalance, ethValue, pair);
        }

        // handle any remaining balance in this contract
        _cleanup(tokenAddress);

        emit TokenGraduated(tokenAddress, pair, amountToken, amountEth, liquidity);
    }

    /// @notice Reads the actual reserves after syncing, and returns them in the order of (token, eth)
    function _getUpdatedEthReserves(address pair, address tokenAddress) internal returns (uint256 ethReserve) {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);

        // in case there is unsynced ETH
        pairContract.sync();

        (uint112 reserve0, uint112 reserve1,) = pairContract.getReserves();

        // Determine which reserve corresponds to which token
        address token0 = pairContract.token0();

        if (token0 == tokenAddress) {
            ethReserve = reserve1;
        } else {
            ethReserve = reserve0;
        }
    }

    function _addLiquidityWithPriceMatching(
        address tokenAddress,
        uint256 ethReserve,
        uint256 tokenBalance,
        uint256 ethValue,
        address pair
    ) internal returns (uint256 amountToken, uint256 amountEth, uint256 liquidity) {
        // Calculate tokens needed to match existing price
        // review this calculation
        uint256 tokensToTransfer = (tokenBalance * ethReserve) / (ethValue + ethReserve);

        // if there was eth in the contract, then it is guaranteed that tokensToTransfer > 0
        if (tokensToTransfer < tokenBalance) {
            // Transfer calculated tokens directly to pair and sync
            ILivoToken(tokenAddress).safeTransfer(pair, tokensToTransfer);
            IUniswapV2Pair(pair).sync();

            // Add remaining tokens and ETH as liquidity
            uint256 remainingTokens = tokenBalance - tokensToTransfer;
            (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
                tokenAddress, remainingTokens, 0, 0, DEAD_ADDRESS, block.timestamp + 3600
            );
            // the tokens sent as sync also count as liquidity added ofc
            amountToken += tokensToTransfer;
        } else {
            // Fallback: add all as liquidity
            // This would only happen if some weirdo sent enough ETH so that the remaining tokens supply cannot match the price
            // Although highly unlikely, it is important to protect against this scenario
            (amountToken, amountEth, liquidity) = _naiveLiquidityAddition(tokenAddress, tokenBalance, ethValue);
        }
    }

    /// @dev This blindly adds the liquidity, accepting any LPs, so accepting whatever price ratio is in the pair already
    function _naiveLiquidityAddition(address tokenAddress, uint256 tokenBalance, uint256 ethValue)
        internal
        returns (uint256 amountToken, uint256 amountEth, uint256 liquidity)
    {
        (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
            tokenAddress, tokenBalance, 0, 0, DEAD_ADDRESS, block.timestamp + 3600
        );
    }

    function _cleanup(address tokenAddress) internal {
        uint256 remainingTokenBalance = ILivoToken(tokenAddress).balanceOf(address(this));
        // burn any remaining tokens
        if (remainingTokenBalance > 0) {
            ILivoToken(tokenAddress).safeTransfer(DEAD_ADDRESS, remainingTokenBalance);
        }

        // send any remaining ETH to the owner (launchpad)
        uint256 remainingEth = address(this).balance;
        if (remainingEth > 0) {
            address livoTreasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            (bool success,) = livoTreasury.call{value: remainingEth}("");
            require(success, "ETH transfer to treasury failed");
        }
    }
}
