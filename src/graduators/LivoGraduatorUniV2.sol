// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract LivoGraduatorUniV2 is ILivoGraduator, Ownable {
    using SafeERC20 for ILivoToken;

    /// @notice where LP tokens are sent at graduation, effectively locking the liquidity
    address internal constant DEAD_ADDRESS = address(0xdead);

    address public immutable LIVO_LAUNCHPAD;

    /// @notice Uniswap router and factory addresses
    IUniswapV2Router internal immutable UNISWAP_ROUTER;
    IUniswapV2Factory internal immutable UNISWAP_FACTORY;
    address internal immutable WETH;

    ////////////////// Events //////////////////////
    event TokenGraduated(
        address indexed token, address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );

    ////////////////// Custom errors //////////////////////
    error OnlyLaunchpadAllowed();
    error TokenAlreadyGraduated();
    error NoTokensToGraduate();
    error NoETHToGraduate();

    constructor(address _uniswapRouter, address _launchpad) Ownable(msg.sender) {
        LIVO_LAUNCHPAD = _launchpad;

        UNISWAP_ROUTER = IUniswapV2Router(_uniswapRouter);
        UNISWAP_FACTORY = IUniswapV2Factory(UNISWAP_ROUTER.factory());

        WETH = UNISWAP_ROUTER.WETH();
    }

    modifier onlyLaunchpad() {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        _;
    }

    function initializePair(address tokenAddress) external payable override onlyLaunchpad returns (address pair) {
        pair = UNISWAP_FACTORY.createPair(tokenAddress, WETH);
    }

    /// @dev if the graduation fails, the eth goes back, but the tokens are stuck here. review a solution for this
    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 ethBalance = msg.value;

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethBalance > 0, NoETHToGraduate());

        // the pair should have been pre-created at token launch.
        // If not, pair==address(0) and graduation will revert
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, WETH);

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // Approve tokens for router
        // question review when safeApprove doesn't work properly
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokenBalance);

        // Add liquidity to Uniswap
        (uint256 amountToken, uint256 amountEth, uint256 liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethBalance}(
            tokenAddress,
            tokenBalance,
            0, // Accept any amount of tokens // review
            0, // Accept any amount of ETH // review
            DEAD_ADDRESS, // Send LP tokens to lock contract // review
            block.timestamp // no deadline
        );

        emit TokenGraduated(tokenAddress, pair, amountToken, amountEth, liquidity);
    }
}
