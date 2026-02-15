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

    /// @notice Where LP tokens are sent at graduation, effectively locking the liquidity
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Uniswap V2 router contract
    IUniswapV2Router internal immutable UNISWAP_ROUTER;

    /// @notice Uniswap V2 factory contract
    IUniswapV2Factory internal immutable UNISWAP_FACTORY;

    /// @notice Wrapped ETH address
    address internal immutable WETH;

    /// @notice Graduation ETH fee split between creator and treasury
    uint256 public constant GRADUATION_ETH_FEE = 0.5 ether;

    /// @notice ETH compensation paid to token creator at graduation
    /// @dev this is part of the GRADUATION_ETH_FEE
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.1 ether;

    /// @notice Token supply burned at graduation
    uint256 public constant BURNABLE_SUPPLY_AT_GRADUATION = 0;

    //////////////////////// EVENTS ////////////////////////

    event SweepedRemainingEth(address graduatedToken, uint256 amount);
    event TokenGraduated(
        address indexed token, address indexed pair, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );

    //////////////////////// ERRORS ////////////////////////

    error NotEnoughEthForGraduation();
    error EtherTransferFailed();

    ////////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V2 graduator
    /// @param _uniswapRouter Address of the Uniswap V2 router
    /// @param _launchpad Address of the LivoLaunchpad contract
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

    /// @notice Creates a Uniswap V2 pair for the token to reserve the pair and know the pair address
    /// @param tokenAddress Address of the token
    /// @return pair Address of the created Uniswap V2 pair
    function initialize(address tokenAddress) external override onlyLaunchpad returns (address pair) {
        pair = UNISWAP_FACTORY.createPair(tokenAddress, WETH);
        emit PairInitialized(tokenAddress, pair);
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V2
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);
        require(tokenAmount > 0, NoTokensToGraduate());
        require(msg.value > 0, NoETHToGraduate());

        // 1. Burn tokens
        token.safeTransfer(DEAD_ADDRESS, BURNABLE_SUPPLY_AT_GRADUATION);

        // 2. Handle fee split and payments
        uint256 ethForLiquidity = _handleGraduationFees(tokenAddress);

        // 3. Mark graduated and add liquidity
        address pair = UNISWAP_FACTORY.getPair(tokenAddress, WETH);
        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        uint256 tokensForLiquidity = tokenAmount - BURNABLE_SUPPLY_AT_GRADUATION;
        token.safeIncreaseAllowance(address(UNISWAP_ROUTER), tokensForLiquidity);

        uint256 ethReserve = _syncedEthReserves(pair, tokenAddress);

        uint256 amountToken;
        uint256 amountEth;
        uint256 liquidity;
        if (ethReserve == 0) {
            (amountToken, amountEth, liquidity) =
                _naiveLiquidityAddition(tokenAddress, tokensForLiquidity, ethForLiquidity);
        } else {
            (amountToken, amountEth, liquidity) =
                _addLiquidityWithPriceMatching(tokenAddress, ethReserve, tokensForLiquidity, ethForLiquidity, pair);
        }

        _cleanup(tokenAddress);
        emit TokenGraduated(tokenAddress, pair, amountToken, amountEth, liquidity);
    }

    /// @dev Reads the actual eth reserves after syncing
    function _syncedEthReserves(address pair, address tokenAddress) internal returns (uint256 ethReserve) {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
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

    /// @dev Adds liquidity trying to match the intended price (derived from the ratio of eth/tokens for graduation)
    /// @dev The number one priority is that liquidity addition doesn't revert
    /// @dev The number two priority is that the resulting price in the pool is GREATER than the last price given by the launchpad before graduation
    function _addLiquidityWithPriceMatching(
        address tokenAddress,
        uint256 ethReserve,
        uint256 tokenBalance,
        uint256 ethValue,
        address pair
    ) internal returns (uint256 amountToken, uint256 amountEth, uint256 liquidity) {
        // Calculate tokens needed to match target price
        uint256 tokensToTransfer = (tokenBalance * ethReserve) / (ethValue + ethReserve);

        // Note: tokensToTransfer is always < tokenBalance due to (ethReserve < ethValue + ethReserve)
        ILivoToken(tokenAddress).safeTransfer(pair, tokensToTransfer);
        IUniswapV2Pair(pair).sync();

        // Add remaining tokens and ETH as liquidity
        uint256 remainingTokens = tokenBalance - tokensToTransfer;
        (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
            tokenAddress, remainingTokens, 0, 0, DEAD_ADDRESS, block.timestamp
        );
        // the tokens sent as sync also count as liquidity added ofc
        amountToken += tokensToTransfer;
    }

    /// @dev This blindly adds the liquidity, accepting any LPs, so accepting whatever price ratio is in the pair already
    function _naiveLiquidityAddition(address tokenAddress, uint256 tokenBalance, uint256 ethValue)
        internal
        returns (uint256 amountToken, uint256 amountEth, uint256 liquidity)
    {
        (amountToken, amountEth, liquidity) = UNISWAP_ROUTER.addLiquidityETH{value: ethValue}(
            tokenAddress, tokenBalance, 0, 0, DEAD_ADDRESS, block.timestamp
        );
    }

    function _handleGraduationFees(address tokenAddress) internal returns (uint256 ethForLiquidity) {
        require(msg.value > GRADUATION_ETH_FEE, NotEnoughEthForGraduation());

        // todo make sure this doesn't revert with underflow
        ethForLiquidity = msg.value - GRADUATION_ETH_FEE;
        uint256 treasuryShare = GRADUATION_ETH_FEE;

        address tokenOwner = ILivoLaunchpad(LIVO_LAUNCHPAD).getTokenOwner(tokenAddress);
        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        // Pay creator (non-reverting, fallback to treasury if fails)
        if (_transferEth(tokenOwner, CREATOR_GRADUATION_COMPENSATION, false)) {
            treasuryShare -= CREATOR_GRADUATION_COMPENSATION;
        }

        // Pay treasury
        _transferEth(treasury, treasuryShare, true);
    }

    function _transferEth(address recipient, uint256 amount, bool requireSuccess) internal returns (bool) {
        if (amount == 0) return true;
        (bool success,) = recipient.call{value: amount}("");
        require(!requireSuccess || success, EtherTransferFailed());
        return success;
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
            require(success, EtherTransferFailed());

            // for transparency, to be able to detect if some graduation went completely wrong
            emit SweepedRemainingEth(tokenAddress, remainingEth);
        }
    }
}
