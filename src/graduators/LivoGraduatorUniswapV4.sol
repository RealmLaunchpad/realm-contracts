// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoFeeHandler} from "src/interfaces/ILivoFeeHandler.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {LivoFeeV4Handler} from "src/feeHandlers/LivoFeeV4Handler.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {FactoryWhitelisting} from "src/FactoryWhitelisting.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator, Ownable, FactoryWhitelisting {
    using SafeERC20 for ILivoToken;
    using PoolIdLibrary for PoolKey;

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Contract where the liquidity NFTs will be locked
    ILiquidityLockUniv4WithFees public immutable LIQUIDITY_LOCK;

    /// @notice Permit2 contract for token approvals
    address public immutable PERMIT2;

    /// @notice Uniswap V4 pool manager contract
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Uniswap V4 position manager contract
    address public immutable UNIV4_POSITION_MANAGER;

    /// @notice Hook contract address for pool interactions
    address public immutable HOOK_ADDRESS;

    //////////////////////////// price set-point ///////////////////////////////

    /// @notice Starting price when graduation occurs, which must be inside the liquidity range
    /// @dev Graduation price: 39011306440 wei per token -> 0.000000000025633594 tokens per eth -> sqrtX96price: 401129254579132618442796085280768 -> tick: 170600
    uint160 constant SQRT_PRICEX96_GRADUATION = 395392928243069119481342754553856;

    /// @notice The sqrtX96 price at the high tick, i.e., the minimum token price denominated in ETH
    /// @dev Derived from the high-tick in constructor
    uint160 immutable SQRT_PRICEX96_UPPER_TICK;

    /// @notice The sqrtX96 price at the low tick, i.e., the maximum token price denominated in ETH
    /// @dev Derived from the low-tick in constructor
    uint160 immutable SQRT_PRICEX96_LOWER_TICK;

    //////////////////////// SECOND LIQUIDITY POSITION (ONLY ETH) ////////////////////////////

    uint160 immutable SQRT_LOWER_2;
    uint160 immutable SQRT_UPPER_2;

    /// @notice Graduation ETH fee (creator compensation + treasury fee)
    uint256 public constant GRADUATION_ETH_FEE = 0.5 ether;

    /// @notice ETH compensation paid to token creator at graduation
    /// @dev this is part of the GRADUATION_ETH_FEE
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = 0.1 ether;

    /////////////////////// Errors ///////////////////////

    error EthTransferFailed();

    /////////////////////// Events ///////////////////////

    event TokenGraduated(
        address indexed token, bytes32 poolId, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );

    //////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V4 graduator
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _liquidityLock Address of the liquidity lock contract
    /// @param _poolManager Address of the Uniswap V4 pool manager
    /// @param _positionManager Address of the Uniswap V4 position manager
    /// @param _permit2 Address of the Permit2 contract
    /// @param _hook Address of the hook contract (use DeploymentAddresses.LIVO_SWAP_HOOK for standard setup)
    constructor(
        address _launchpad,
        address _liquidityLock,
        address _poolManager,
        address _positionManager,
        address _permit2,
        address _hook
    ) Ownable(msg.sender) {
        LIVO_LAUNCHPAD = _launchpad;
        UNIV4_POOL_MANAGER = IPoolManager(_poolManager);
        UNIV4_POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        LIQUIDITY_LOCK = ILiquidityLockUniv4WithFees(_liquidityLock);
        HOOK_ADDRESS = _hook;

        SQRT_PRICEX96_LOWER_TICK = uint160(TickMath.getSqrtPriceAtTick(UniswapV4PoolConstants.TICK_LOWER));
        SQRT_PRICEX96_UPPER_TICK = uint160(TickMath.getSqrtPriceAtTick(UniswapV4PoolConstants.TICK_UPPER));

        // secondary eth liquidity position
        SQRT_LOWER_2 = uint160(TickMath.getSqrtPriceAtTick(UniswapV4PoolConstants.TICK_LOWER_2));
        SQRT_UPPER_2 = uint160(TickMath.getSqrtPriceAtTick(UniswapV4PoolConstants.TICK_UPPER_2));

        // approve the LIQUIDITY_LOCK to pull any NFT liquidity in this contract
        // instead of having to approve every NFT on every graduation to save gas
        IERC721(_positionManager).setApprovalForAll(_liquidityLock, true);
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice To receive ETH back from Uniswap V4 when sweeping excess ETH after liquidity provision
    receive() external payable {}

    /// @notice Initializes a Uniswap V4 pool for the token
    /// @param tokenAddress Address of the token
    /// @return Address of the pool manager (same for all tokens, but to comply with the ILivoGraduator interface)
    function initialize(address tokenAddress) external override onlyWhitelistedFactory returns (address) {
        PoolKey memory pool = _getPoolKey(tokenAddress);

        // this sets the price even if there is no liquidity yet
        UNIV4_POOL_MANAGER.initialize(pool, SQRT_PRICEX96_GRADUATION);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, which forbids token transfers to the pool until graduation
        // to prevent liquidity deposits & trades before being graduated
        emit PairInitialized(tokenAddress, address(UNIV4_POOL_MANAGER));

        return address(UNIV4_POOL_MANAGER);
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V4
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        ILivoToken token = ILivoToken(tokenAddress);
        require(tokenAmount > 0, NoTokensToGraduate());
        require(msg.value > 0, NoETHToGraduate());

        // 1. Handle fee split
        (uint256 ethForLiquidity, address treasury) = _handleGraduationFeesV4(tokenAddress);

        // 2. Continue with V4 liquidity logic
        uint256 tokenBalanceBeforeDeposit = token.balanceOf(address(this));

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // no tokens balance is expected in this contract for more than the graduation transaction,
        // so no problem with having these dangling approvals

        // approve PERMIT2 as a spender
        token.forceApprove(PERMIT2, type(uint256).max);
        // approve `PositionManager` as a spender
        IAllowanceTransfer(PERMIT2)
            .approve(
                address(token), // approved token
                UNIV4_POSITION_MANAGER, // spender
                type(uint160).max, // amount
                type(uint48).max // expiration
            );

        PoolKey memory pool = _getPoolKey(tokenAddress);
        (uint128 liquidity1, uint128 liquidity2) =
            _addAndRegisterLiquidityPositions(pool, tokenAddress, ethForLiquidity, tokenAmount, treasury);

        // there may be a small leftover of tokens not deposited
        uint256 tokenBalanceAfterDeposit = token.balanceOf(address(this));
        // we attempt to deposit tokensForLiquidity, but this is the actual amount deposited
        // any token not deposited is stuck here in this contract
        uint256 tokensDeposited = tokenBalanceBeforeDeposit - tokenBalanceAfterDeposit;

        bytes32 poolId = PoolId.unwrap(pool.toId());
        emit TokenGraduated(tokenAddress, poolId, tokensDeposited, ethForLiquidity, liquidity1 + liquidity2);
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    function _handleGraduationFeesV4(address tokenAddress)
        internal
        returns (uint256 ethForLiquidity, address treasury)
    {
        treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        ethForLiquidity = msg.value - GRADUATION_ETH_FEE;
        uint256 treasuryShare = GRADUATION_ETH_FEE;

        // Deposit creator compensation (non-reverting)
        if (_depositToFeeHandler(tokenAddress, CREATOR_GRADUATION_COMPENSATION, false)) {
            treasuryShare -= CREATOR_GRADUATION_COMPENSATION;
        }

        // Pay treasury
        _transferEth(treasury, treasuryShare, true);
    }

    function _transferEth(address recipient, uint256 amount, bool requireSuccess) internal returns (bool) {
        if (amount == 0) return true;
        (bool success,) = recipient.call{value: amount}("");
        require(!requireSuccess || success, EthTransferFailed());
        return success;
    }

    function _depositToFeeHandler(address tokenAddress, uint256 amount, bool requireSuccess) internal returns (bool) {
        if (amount == 0) return true;

        ILivoToken.FeeConfig memory feeConfig = ILivoToken(tokenAddress).getFeeConfigs();

        try ILivoFeeHandler(feeConfig.feeHandler).depositFees{value: amount}(tokenAddress, feeConfig.feeReceiver) {
            return true;
        } catch {
            require(!requireSuccess, EthTransferFailed());
            return false;
        }
    }

    function _getPoolKey(address tokenAddress) internal view virtual returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: UniswapV4PoolConstants.LP_FEE,
            tickSpacing: UniswapV4PoolConstants.TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });
    }

    function _addAndRegisterLiquidityPositions(
        PoolKey memory pool,
        address tokenAddress,
        uint256 ethForLiquidity,
        uint256 tokenAmount,
        address treasury
    ) internal returns (uint128 liquidity1, uint128 liquidity2) {
        uint256 ethBalanceBefore = address(this).balance;
        address feeHandlerAddress = ILivoToken(tokenAddress).feeHandler();

        liquidity1 = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICEX96_GRADUATION, SQRT_PRICEX96_LOWER_TICK, SQRT_PRICEX96_UPPER_TICK, ethForLiquidity, tokenAmount
        );

        uint256 primaryPositionId = _addLiquidity(
            pool,
            UniswapV4PoolConstants.TICK_LOWER,
            UniswapV4PoolConstants.TICK_UPPER,
            liquidity1,
            ethForLiquidity,
            tokenAmount,
            feeHandlerAddress,
            address(this)
        );

        uint256 remainingEth = ethForLiquidity - (ethBalanceBefore - address(this).balance);
        liquidity2 = LiquidityAmounts.getLiquidityForAmount0(SQRT_LOWER_2, SQRT_UPPER_2, remainingEth);

        if (liquidity2 > 0) {
            uint256[] memory positionIds = new uint256[](2);
            positionIds[0] = primaryPositionId;
            positionIds[1] = _addLiquidity(
                pool,
                UniswapV4PoolConstants.TICK_LOWER_2,
                UniswapV4PoolConstants.TICK_UPPER_2,
                liquidity2,
                remainingEth,
                0,
                feeHandlerAddress,
                treasury
            );
            LivoFeeV4Handler(payable(feeHandlerAddress)).registerPosition(tokenAddress, positionIds);
            return (liquidity1, liquidity2);
        }

        uint256[] memory onePositionId = new uint256[](1);
        onePositionId[0] = primaryPositionId;
        LivoFeeV4Handler(payable(feeHandlerAddress)).registerPosition(tokenAddress, onePositionId);
    }

    function _addLiquidity(
        PoolKey memory pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 ethValue,
        uint256 tokenAmount,
        address feeHandlerAddress,
        address excessEthReceiver
    ) internal returns (uint256 positionId) {
        // Actions for ETH liquidity positions
        // 1. Mint position
        // 2. Settle pair (send ETH and tokens)
        // 3. Sweep any remaining native ETH back to the treasury (only required with native eth positions)
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);

        // parameters for MINT_POSITION action. Receive the NFT here, and then lock it in the liquidity lock
        address nftReceiver = address(this);
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, nftReceiver, "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, excessEthReceiver); // sweep all remaining native ETH to recipient

        // read the next positionId before minting the position
        positionId = IPositionManager(UNIV4_POSITION_MANAGER).nextTokenId();

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(UNIV4_POSITION_MANAGER).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );

        // locks the liquidity position NFT in the liquidity lock contract
        // the fee handler becomes the lock owner so it can claim LP fees
        LIQUIDITY_LOCK.lockUniV4Position(positionId, feeHandlerAddress);
    }
}
