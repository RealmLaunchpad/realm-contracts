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
    event PairInitialized(address indexed token, address indexed pair);

    ////////////////// Custom errors //////////////////////
    error OnlyLaunchpadAllowed();
    error NoTokensToGraduate();
    error NoETHToGraduate();

    constructor(address _uniswapRouter, address _launchpad) Ownable(msg.sender) {
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
        uint256 ethBalance = msg.value;
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethBalance > 0, NoETHToGraduate());

        // the pair should have been pre-created at token launch.
        // If not, pair==address(0) and graduation will revert
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, WETH);

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // Approve the router to handle the tokens for liquidity additiontokens for router
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokenBalance);

        // Add liquidity to Uniswap
        // Explanation about the lack of slippage protection when adding liquidity:
        // Before graduation, it is forbidden to transfer tokens to the pair, so the price cannot be artificially set pre-graduation
        // Although it is possible to transfer eth to the pair, it comes at a net cost to the attacker.
        // And the overall impact at graduation is that the price in uniswap will be higher than in the bonding curve,
        // but this is at a cost of who tried to inflate the price, benefiting any other token holders
        // So I don't see any economic incentives, nor the token holders would be negatively affected
        (uint256 amountToken, uint256 amountEth, uint256 liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethBalance}(
            tokenAddress,
            tokenBalance,
            0, // Accept any amount of tokens
            0, // Accept any amount of ETH
            DEAD_ADDRESS, // Send LP tokens to lock contract
            block.timestamp // no deadline
        );

        emit TokenGraduated(tokenAddress, pair, amountToken, amountEth, liquidity);
    }
}
