// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {LivoToken} from "src/LivoToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";

contract BasicGraduationManager is ILivoGraduator, Ownable, ReentrancyGuard {
    IUniswapV2Router public immutable uniswapRouter;
    IUniswapV2Factory public immutable uniswapFactory;
    address public immutable launchpad;
    address public liquidityLockContract;

    mapping(address => bool) public graduatedTokens;

    event TokenGraduated(
        address indexed token, address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );

    constructor(address _uniswapRouter, address _launchpad, address _liquidityLockContract) Ownable(msg.sender) {
        uniswapRouter = IUniswapV2Router(_uniswapRouter);
        uniswapFactory = IUniswapV2Factory(IUniswapV2Router(_uniswapRouter).factory());
        launchpad = _launchpad;
        liquidityLockContract = _liquidityLockContract;
    }

    modifier onlyLaunchpad() {
        require(msg.sender == launchpad, "BasicGraduationManager: Only launchpad can call");
        _;
    }

    function checkGraduationEligibility(address tokenAddress) external view override returns (bool) {
        // This is handled by the launchpad based on ETH collected threshold
        // This function exists for interface compliance
        return !graduatedTokens[tokenAddress];
    }

    function graduateToken(address tokenAddress) external payable override onlyLaunchpad nonReentrant {
        require(!graduatedTokens[tokenAddress], "BasicGraduationManager: Token already graduated");

        LivoToken token = LivoToken(tokenAddress);
        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 ethBalance = msg.value;

        require(tokenBalance > 0, "BasicGraduationManager: No tokens to graduate");
        require(ethBalance > 0, "BasicGraduationManager: No ETH to graduate");

        // Create Uniswap pair if it doesn't exist
        address pair = uniswapFactory.getPair(tokenAddress, uniswapRouter.WETH());
        if (pair == address(0)) {
            pair = uniswapFactory.createPair(tokenAddress, uniswapRouter.WETH());
        }

        // Approve tokens for router
        token.approve(address(uniswapRouter), tokenBalance);

        // Add liquidity to Uniswap
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = uniswapRouter.addLiquidityETH{value: ethBalance}(
            tokenAddress,
            tokenBalance,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            liquidityLockContract, // Send LP tokens to lock contract
            block.timestamp + 300 // 5 minute deadline
        );

        graduatedTokens[tokenAddress] = true;

        emit TokenGraduated(tokenAddress, pair, amountToken, amountETH, liquidity);
    }

    function setLiquidityLockContract(address _liquidityLockContract) external onlyOwner {
        liquidityLockContract = _liquidityLockContract;
    }
}
