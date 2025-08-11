// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract LivoGraduatorUniV2 is ILivoGraduator, Ownable {
    using SafeERC20 for IERC20;

    /// @notice where LP tokens are sent at graduation, effectively locking the liquidity
    address public constant DEAD_ADDRESS = address(0xdead);

    /// @notice creator fee in basis points (100 bps = 1%)
    uint16 public constant CREATOR_FEE_BPS = 100;

    uint16 public constant BASIS_POINTS = 10_000; // 100%

    /// @notice Uniswap router and factory addresses
    IUniswapV2Router public immutable uniswapRouter;
    address public immutable livoLaunchpad;

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
        uniswapRouter = IUniswapV2Router(_uniswapRouter);
        livoLaunchpad = _launchpad;
    }

    modifier onlyLaunchpad() {
        require(msg.sender == livoLaunchpad, OnlyLaunchpadAllowed());
        _;
    }

    /// @dev if the graduation fails, the eth goes back, but the tokens are stuck here.  review a solution for this
    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        IERC20 token = IERC20(tokenAddress);

        /// note review what happens if the token was already graduated and this is called again (even though the launchpad wouldn't do it)
        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(IUniswapV2Router(uniswapRouter).factory());

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 ethBalance = msg.value;

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethBalance > 0, NoETHToGraduate());

        // Create Uniswap pair if it doesn't exist
        // question is there a problem if the pair is created by another account before?
        // question review if WETH is the right or should be ETH somehow
        address pair = uniswapFactory.getPair(tokenAddress, uniswapRouter.WETH());
        if (pair == address(0)) {
            pair = uniswapFactory.createPair(tokenAddress, uniswapRouter.WETH());
        }

        // Approve tokens for router
        // question review when safeApprove doesn't work properly
        token.safeIncreaseAllowance(address(uniswapRouter), tokenBalance);

        // Add liquidity to Uniswap
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = uniswapRouter.addLiquidityETH{value: ethBalance}(
            tokenAddress,
            tokenBalance,
            0, // Accept any amount of tokens // review
            0, // Accept any amount of ETH // review
            DEAD_ADDRESS, // Send LP tokens to lock contract // review
            block.timestamp // no deadline
        );

        // set the pair to detect which transfers are trades against the uniswap pool
        // this is set only after liquidity has been added, so the pair is valid,
        // and the liquidity addition is fee exempt.
        LivoToken(tokenAddress).setAutomatedMarketMakerPair(pair);

        emit TokenGraduated(tokenAddress, pair, amountToken, amountETH, liquidity);
    }
}
