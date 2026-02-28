// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoFeeBaseHandler} from "src/feeHandlers/LivoFeeBaseHandler.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// @title LivoFeeV4Handler
/// @notice Fee handler that extends LivoFeeBaseHandler with Uniswap V4 LP fee accrual,
///         position tracking, and treasury fee management.
contract LivoFeeV4Handler is LivoFeeBaseHandler, Ownable, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Associated liquidity positionIds for each graduated token
    /// @dev Each token has two liquidity positions added (one of them is one-sided, only ETH)
    mapping(address token => uint256[] tokenId) public positionIds;

    /// @notice Authorized registrars that can register positions (graduators)
    mapping(address registrar => bool authorized) public authorizedRegistrars;

    /// @notice Treasury LP fees already accrued into contract accounting
    uint256 public treasuryPendingFees;

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Contract where the liquidity NFTs are locked
    ILiquidityLockUniv4WithFees public immutable LIQUIDITY_LOCK;

    /// @notice Uniswap V4 pool manager contract
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Uniswap V4 position manager contract
    address public immutable UNIV4_POSITION_MANAGER;

    /// @notice Hook contract address for pool interactions
    address public immutable HOOK_ADDRESS;

    /////////////////////// Errors ///////////////////////

    error NoTokensGiven();
    error TooManyTokensGiven();
    error InvalidPositionIndex();
    error InvalidPositionIndexes();
    error UnauthorizedRegistrar();

    /////////////////////// Events ///////////////////////

    event TreasuryFeesAccrued(address indexed token, uint256 amount);
    event TreasuryFeesClaimed(address indexed caller, address indexed treasury, uint256 amount);
    event PositionRegistered(address indexed token, uint256 indexed positionId);
    event AuthorizedRegistrarSet(address indexed registrar, bool authorized);

    //////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V4 fee handler
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _liquidityLock Address of the liquidity lock contract
    /// @param _poolManager Address of the Uniswap V4 pool manager
    /// @param _positionManager Address of the Uniswap V4 position manager
    /// @param _hook Address of the hook contract
    constructor(
        address _launchpad,
        address _liquidityLock,
        address _poolManager,
        address _positionManager,
        address _hook
    ) Ownable(msg.sender) {
        LIVO_LAUNCHPAD = _launchpad;
        LIQUIDITY_LOCK = ILiquidityLockUniv4WithFees(_liquidityLock);
        UNIV4_POOL_MANAGER = IPoolManager(_poolManager);
        UNIV4_POSITION_MANAGER = _positionManager;
        HOOK_ADDRESS = _hook;
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice To receive ETH from the liquidity lock when accruing fees
    receive() external payable {}

    /// @notice Sets or revokes an authorized registrar (e.g., a graduator)
    /// @param registrar Address to authorize or deauthorize
    /// @param authorized Whether the registrar is authorized
    function setAuthorizedRegistrar(address registrar, bool authorized) external onlyOwner {
        authorizedRegistrars[registrar] = authorized;
        emit AuthorizedRegistrarSet(registrar, authorized);
    }

    /// @notice Registers a liquidity position ID for a token
    /// @dev Only callable by authorized registrars (graduators) during graduation
    /// @param token Address of the graduated token
    /// @param positionId The Uniswap V4 position NFT ID
    function registerPosition(address token, uint256 positionId) external {
        require(authorizedRegistrars[msg.sender], UnauthorizedRegistrar());
        positionIds[token].push(positionId);
        emit PositionRegistered(token, positionId);
    }

    /// @notice Accrues fresh LP fees for each token and deposits creator share into each token's fee handler accounting
    /// @dev Creator claims are handled by `claim(address[] calldata tokens)` inherited from LivoFeeBaseHandler
    /// @param tokens Array of token addresses
    /// @param positionIndexes Array of position indexes to accrue fees from (only 0 or 1 are valid values)
    function creatorClaim(address[] calldata tokens, uint256[] calldata positionIndexes) public nonReentrant {
        // todo this function is basically the same as accrueTokenFees so we can remove it
        uint256 nTokens = _validateClaimInputs(tokens, positionIndexes);

        for (uint256 i = 0; i < nTokens; i++) {
            _accrueLpFees(tokens[i], positionIndexes);
        }
    }

    /// @notice Accrues LP fees for tokens and deposits creator/treasury shares
    /// @dev Creator shares are deposited in fee handler accounting. Treasury shares are accrued in storage.
    /// @param tokens Array of token addresses
    /// @param positionIndexes Array of position indexes to accrue fees from (only 0 or 1 are valid values)
    function accrueTokenFees(address[] calldata tokens, uint256[] calldata positionIndexes) external nonReentrant {
        uint256 nTokens = _validateClaimInputs(tokens, positionIndexes);

        for (uint256 i = 0; i < nTokens; i++) {
            _accrueLpFees(tokens[i], positionIndexes);
        }
    }

    /// @notice Claims the pending treasury LP fees to the treasury address
    /// @dev Callable by anyone since funds always go to treasury
    function treasuryClaim() public {
        uint256 pending = treasuryPendingFees;
        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        if (pending > 0) {
            treasuryPendingFees = 0;
            _transferEth(treasury, pending);
        }

        emit TreasuryFeesClaimed(msg.sender, treasury, pending);
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns claimable creator amounts (fee handler claimable + current unaccrued LP-fee estimate)
    /// @dev LP-fee estimates are included only when `tokenOwner` is the current token owner
    /// @param tokens Array of token addresses
    /// @param positionIndexes Array of position indexes to estimate LP fees from. PositionIndex 0 accrues most fees
    /// @param tokenOwner Address for which pending and claimable amounts are computed
    /// @return creatorClaimable Array of claimable ETH amounts per token for `tokenOwner`
    function getClaimable(address[] calldata tokens, uint256[] calldata positionIndexes, address tokenOwner)
        public
        view
        returns (uint256[] memory creatorClaimable)
    {
        uint256 nTokens = tokens.length;
        uint256 nPositions = positionIndexes.length;

        require(1 <= nPositions && nPositions <= 2, InvalidPositionIndexes());

        creatorClaimable = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            // Include already-accrued pending claims from this fee handler
            creatorClaimable[i] = pendingClaims[token][tokenOwner];

            if (ILivoToken(token).owner() != tokenOwner) {
                continue;
            }

            for (uint256 posIndex = 0; posIndex < nPositions; posIndex++) {
                require(positionIndexes[posIndex] < 2, InvalidPositionIndex());
                creatorClaimable[i] += _viewClaimableEthFees(token, positionIndexes[posIndex]);
            }
        }
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    function _validateClaimInputs(address[] calldata tokens, uint256[] calldata positionIndexes)
        internal
        pure
        returns (uint256 nTokens)
    {
        nTokens = tokens.length;
        require(nTokens > 0, NoTokensGiven());
        require(nTokens < 100, TooManyTokensGiven());
        require(1 <= positionIndexes.length && positionIndexes.length <= 2, InvalidPositionIndexes());

        for (uint256 p = 0; p < positionIndexes.length; p++) {
            require(positionIndexes[p] <= 1, InvalidPositionIndex());
        }
    }

    function _accrueLpFees(address token, uint256[] calldata positionIndexes) internal {
        uint256 creatorAccrued;
        uint256 treasuryAccrued;

        for (uint256 p = 0; p < positionIndexes.length; p++) {
            uint256 positionId = positionIds[token][positionIndexes[p]];
            (uint256 creatorFees, uint256 treasuryFees) = _accrueFromUniswapLock(token, positionId);
            creatorAccrued += creatorFees;
            treasuryAccrued += treasuryFees;
        }

        if (creatorAccrued > 0) {
            _depositCreatorFees(token, creatorAccrued);
        }

        if (treasuryAccrued > 0) {
            treasuryPendingFees += treasuryAccrued;
            emit TreasuryFeesAccrued(token, treasuryAccrued);
        }
    }

    function _depositCreatorFees(address token, uint256 amount) internal {
        ILivoToken.FeeConfig memory feeConfig = ILivoToken(token).getFeeConfigs();
        // Deposit into this handler's own accounting (inherited from LivoFeeBaseHandler)
        pendingClaims[token][feeConfig.feeReceiver] += amount;
        emit FeesDeposited(token, feeConfig.feeReceiver, amount);
    }

    function _accrueFromUniswapLock(address token, uint256 positionId)
        internal
        returns (uint256 creatorFees, uint256 treasuryFees)
    {
        // accruing fees results in an ETH transfer to this contract
        uint256 balanceBefore = address(this).balance;

        // accrue fees to this contract and distribute between livo treasury and token owner
        LIQUIDITY_LOCK.claimUniV4PositionFees(positionId, address(0), token, address(this));

        // ETH fees accrued in this call
        uint256 accruedEthFees = address(this).balance - balanceBefore;

        // 50/50 split of the eth fees between livo treasury and token owner
        treasuryFees = accruedEthFees / 2;
        creatorFees = accruedEthFees - treasuryFees;
    }

    function _viewClaimableEthFees(address token, uint256 positionIndex)
        internal
        view
        returns (uint256 creatorEthFees)
    {
        if (positionIndex > 1) return 0;

        PoolKey memory poolKey = _getPoolKey(token);

        PoolId poolId = poolKey.toId();
        uint256 positionId = positionIds[token][positionIndex];

        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside0X128;

        if (positionIndex == 0) {
            (liquidity, feeGrowthInside0LastX128,) = UNIV4_POOL_MANAGER.getPositionInfo(
                poolId,
                UNIV4_POSITION_MANAGER,
                UniswapV4PoolConstants.TICK_LOWER,
                UniswapV4PoolConstants.TICK_UPPER,
                bytes32(positionId)
            );
            (feeGrowthInside0X128,) = UNIV4_POOL_MANAGER.getFeeGrowthInside(
                poolId, UniswapV4PoolConstants.TICK_LOWER, UniswapV4PoolConstants.TICK_UPPER
            );
        } else {
            (liquidity, feeGrowthInside0LastX128,) = UNIV4_POOL_MANAGER.getPositionInfo(
                poolId,
                UNIV4_POSITION_MANAGER,
                UniswapV4PoolConstants.TICK_LOWER_2,
                UniswapV4PoolConstants.TICK_UPPER_2,
                bytes32(positionId)
            );
            (feeGrowthInside0X128,) = UNIV4_POOL_MANAGER.getFeeGrowthInside(
                poolId, UniswapV4PoolConstants.TICK_LOWER_2, UniswapV4PoolConstants.TICK_UPPER_2
            );
        }

        uint128 tokenAmount = (FullMath.mulDiv(
                feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128
            ))
        .toUint128();

        creatorEthFees = tokenAmount - tokenAmount / 2;
    }

    function _getPoolKey(address tokenAddress) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: UniswapV4PoolConstants.LP_FEE,
            tickSpacing: UniswapV4PoolConstants.TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });
    }

    function _transferEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        require(success, EthTransferFailed());
    }
}
