// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoFeeBaseHandler} from "src/feeHandlers/LivoFeeBaseHandler.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
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

    /// @notice Authorized graduators that can register positions
    mapping(address graduator => bool authorized) public authorizedGraduators;

    /// @notice Contract where the liquidity NFTs are locked
    ILiquidityLockUniv4WithFees public immutable LIQUIDITY_LOCK;

    /// @notice Hook contract address for pool interactions
    address public immutable HOOK_ADDRESS;

    /////////////////// Uniswap v4 related ///////////////

    /// @notice Uniswap V4 pool manager contract
    IPoolManager internal immutable _UNIV4_POOL_MANAGER;

    /// @notice Uniswap V4 position manager contract
    address internal immutable _UNIV4_POSITION_MANAGER;

    /////////////////////// Errors ///////////////////////

    error NoTokens();
    error TooManyTokens();
    error UnauthorizedGraduator();

    /////////////////////// Events ///////////////////////

    event PositionIdRegistered(address indexed token, uint256 indexed positionId);
    event AuthorizedGraduatorSet(address indexed graduator, bool authorized);

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
    ) LivoFeeBaseHandler(_launchpad) Ownable(msg.sender) {
        HOOK_ADDRESS = _hook;
        LIQUIDITY_LOCK = ILiquidityLockUniv4WithFees(_liquidityLock);

        _UNIV4_POOL_MANAGER = IPoolManager(_poolManager);
        _UNIV4_POSITION_MANAGER = _positionManager;
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice To receive ETH from the liquidity lock when accruing fees
    receive() external payable {}

    /// @notice Sets or revokes an authorized graduator
    /// @param graduator Address to authorize or deauthorize
    /// @param authorized Whether the graduator is authorized
    function setAuthorizedGraduator(address graduator, bool authorized) external onlyOwner {
        // owner is trusted. No need for address(0) checks
        authorizedGraduators[graduator] = authorized;
        emit AuthorizedGraduatorSet(graduator, authorized);
    }

    /// @notice Registers liquidity position IDs for a token
    /// @dev Only callable by authorized graduators during graduation
    /// @param token Address of the graduated token
    /// @param positionIds_ The Uniswap V4 position NFT IDs
    function registerPositionIds(address token, uint256[] calldata positionIds_) external {
        require(authorizedGraduators[msg.sender], UnauthorizedGraduator());

        uint256 nPositions = positionIds_.length;
        for (uint256 i = 0; i < nPositions; i++) {
            uint256 positionId = positionIds_[i];
            positionIds[token].push(positionId);
            emit PositionIdRegistered(token, positionId);
        }
    }

    /// @notice Accrues LP fees for tokens and deposits creator/treasury shares
    /// @dev intentionally not protected, as it only accrues but doesn't send fees to final destination
    /// @dev Creator shares are deposited in fee handler accounting. Treasury shares are accrued in storage.
    ///      Iterates all registered positions for each token automatically.
    ///      Creator claims are handled by `claim(address[] calldata tokens)` in this contract.
    /// @param tokens Array of token addresses
    function accrueTokenFees(address[] calldata tokens) external nonReentrant {
        uint256 nTokens = tokens.length;
        require(nTokens > 0, NoTokens());
        require(nTokens < 100, TooManyTokens());

        for (uint256 i = 0; i < nTokens; i++) {
            _accrueLpFees(tokens[i]);
        }
    }

    /// @notice Claims accumulated ETH fees for msg.sender from the provided `tokens`
    /// @dev Accrues LP fees before claiming and clears claimed storage balances.
    function claim(address[] calldata tokens) external override nonReentrant {
        uint256 claimable;
        uint256 nTokens = tokens.length;

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];

            // increases storage pending fees for the token fee receiver & treasury
            _accrueLpFees(token);

            uint256 tokenClaimable = pendingClaims[token][msg.sender];
            if (tokenClaimable == 0) continue;

            claimable += tokenClaimable;
            delete pendingClaims[token][msg.sender];

            emit CreatorClaimed(token, msg.sender, tokenClaimable);
        }

        if (claimable == 0) return;

        _transferEth(msg.sender, claimable);
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns claimable creator amounts (fee handler claimable + current unaccrued LP-fee estimate)
    /// @dev LP-fee estimates are included only when `receiver` is the current fee receiver.
    ///      Iterates all registered positions for each token automatically.
    /// @param tokens Array of token addresses
    /// @param receiver Address for which pending and claimable amounts are computed
    /// @return creatorClaimable Array of claimable ETH amounts per token for `receiver`
    function getClaimable(address[] calldata tokens, address receiver)
        external
        view
        override
        returns (uint256[] memory creatorClaimable)
    {
        uint256 nTokens = tokens.length;

        creatorClaimable = new uint256[](nTokens);

        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            // Include already-accrued pending claims from this fee handler
            creatorClaimable[i] = pendingClaims[token][receiver];

            if (ILivoToken(token).feeReceiver() != receiver) {
                continue;
            }

            // LP fees are split 50/50 between creator and treasury
            uint256 _pendingLpFees = _viewLpUniClaimableFees(token);
            (uint256 creatorFee,) = _creatorTreasurySplit(_pendingLpFees);

            creatorClaimable[i] += creatorFee;
        }
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Accrues LP fees from all Uniswap V4 positions for a token and splits them between creator and treasury
    function _accrueLpFees(address token) internal {
        uint256 totalCreatorFees;
        uint256 totalTreasuryAccrued;
        address feeReceiver = ILivoToken(token).feeReceiver();

        uint256 nPositions = positionIds[token].length;
        for (uint256 p = 0; p < nPositions; p++) {
            uint256 positionId = positionIds[token][p];
            (uint256 creatorFees, uint256 treasuryFees) = _accrueFromUniswapLock(token, positionId);
            totalCreatorFees += creatorFees;
            totalTreasuryAccrued += treasuryFees;
        }

        if (totalCreatorFees > 0) {
            pendingClaims[token][feeReceiver] += totalCreatorFees;
            emit CreatorFeesDeposited(token, feeReceiver, totalCreatorFees);
        }

        if (totalTreasuryAccrued > 0) {
            treasuryPendingFees += totalTreasuryAccrued;
            emit TreasuryFeesDeposited(token, totalTreasuryAccrued);
        }
    }

    /// @notice Claims LP fees from a single locked Uniswap V4 position and splits them
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
        (creatorFees, treasuryFees) = _creatorTreasurySplit(accruedEthFees);
    }

    /// @notice Estimates claimable ETH fees across all positions for a given token
    /// @param token Address of the token
    /// @return pendingLpFees Total estimated LP ETH fees across all positions (creator + treasury)
    function _viewLpUniClaimableFees(address token) internal view returns (uint256 pendingLpFees) {
        PoolId poolId = _getPoolKey(token).toId();

        uint256 nPositions = positionIds[token].length;
        // this would never happen for valid tokens, but just in case invalid tokens are passed
        if (nPositions == 0) return 0;

        // position 1 (always present)
        pendingLpFees += _claimableLpEthFeesInPosition(
            poolId, // poolId (bytes32)
            UniswapV4PoolConstants.TICK_LOWER,
            UniswapV4PoolConstants.TICK_UPPER,
            positionIds[token][0] // first positionId
        );

        // add fees from position 2 if existing
        if (nPositions > 1) {
            pendingLpFees += _claimableLpEthFeesInPosition(
                poolId, // poolId (bytes32)
                UniswapV4PoolConstants.TICK_LOWER_2,
                UniswapV4PoolConstants.TICK_UPPER_2,
                positionIds[token][1] // second positionId
            );
        }
    }

    /// @notice returns the pending LP fees in a liquidity position (creator + treasury)
    function _claimableLpEthFeesInPosition(PoolId poolId_, int24 tickLower_, int24 tickUpper_, uint256 positionId_)
        internal
        view
        returns (uint128)
    {
        (uint128 liquidity, uint256 feeGrowthInside0LastX128,) = _UNIV4_POOL_MANAGER.getPositionInfo(
            poolId_, _UNIV4_POSITION_MANAGER, tickLower_, tickUpper_, bytes32(positionId_)
        );

        (uint256 feeGrowthInside0X128,) = _UNIV4_POOL_MANAGER.getFeeGrowthInside(poolId_, tickLower_, tickUpper_);

        return
            (FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128))
            .toUint128();
    }

    /// @notice Constructs the Uniswap V4 PoolKey for a given token paired with native ETH
    function _getPoolKey(address tokenAddress) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: UniswapV4PoolConstants.LP_FEE,
            tickSpacing: UniswapV4PoolConstants.TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });
    }

    /// @dev 50/50 split of the eth fees between livo treasury and token owner
    function _creatorTreasurySplit(uint256 amount) internal pure returns (uint256 creatorFees, uint256 treasuryFees) {
        treasuryFees = amount / 2;
        creatorFees = amount - treasuryFees;
    }
}
