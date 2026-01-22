// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator, Ownable {
    using SafeERC20 for ILivoToken;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Associated liquidity positionIds for each graduated token
    /// @dev Each token has two liquidity positions added (one of them is one-sided, only ETH)
    mapping(address token => uint256[] tokenId) public positionIds;

    /// @notice Treasury eth fees collected
    uint256 public treasuryEthFees;

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

    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    /// @dev 10000 pips = 1%
    uint24 constant LP_FEE = 10000;

    /// @notice Tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev The larger the spacing the cheaper to swap gas-wise
    int24 constant TICK_SPACING = 200;

    //////////////////////////// price set-point ///////////////////////////////

    // In the uniswapV4 pool, the pair is (currency0,currency1) = (nativeEth, token)
    // The `sqrtPriceX96` is denominated as sqrt(amountToken1/amountToken0) * 2^96,
    // so tokens/ETH (eth price of one token).
    // Thus, the max token price is found at the low tick, and the min token price at the high tick

    /// @notice The upper boundary of the liquidity range when the position is created (minimum token price in ETH)
    /// @dev High tick: 203600 -> 2088220564709554551739049874292736 -> 694694034.078335 tokens per ETH
    /// @dev Ticks need to be multiples of TICK_SPACING
    int24 constant TICK_UPPER = 203600;

    /// @notice The lower boundary of the liquidity range when the position is created (maximum token price in ETH)
    /// @dev Low tick: -7000 -> sqrtX96price: 55832119482513121612260179968 -> 0.49660268342258984 tokens per ETH
    /// @dev At this tick, the token price would imply a market cap of 2,000,000,000 ETH (8,000,000,000,000 USD with ETH at 4000 USD)
    int24 constant TICK_LOWER = -7000;

    /// @notice Starting price when graduation occurs, which must be inside the liquidity range
    /// @dev Graduation price: 39011306440 wei per token -> 0.000000000025633594 tokens per eth -> sqrtX96price: 401129254579132618442796085280768 -> tick: 170600
    uint160 constant SQRT_PRICEX96_GRADUATION = 401129254579132618442796085280768;

    /// @notice The sqrtX96 price at the high tick, i.e., the minimum token price denominated in ETH
    /// @dev Derived from the high-tick in constructor
    uint160 immutable SQRT_PRICEX96_UPPER_TICK;

    /// @notice The sqrtX96 price at the low tick, i.e., the maximum token price denominated in ETH
    /// @dev Derived from the low-tick in constructor
    uint160 immutable SQRT_PRICEX96_LOWER_TICK;

    //////////////////////// SECOND LIQUIDITY POSITION (ONLY ETH) ////////////////////////////

    // Second position (single-sided ETH only) to use remaining eth (~1.43 ETH)
    int24 constant TICK_GRADUATION = 170600;
    // this position is concentrated right below the graduation price
    int24 constant TICK_LOWER_2 = TICK_GRADUATION + TICK_SPACING;
    int24 constant TICK_UPPER_2 = TICK_UPPER - (110 * TICK_SPACING);

    uint160 immutable SQRT_LOWER_2;
    uint160 immutable SQRT_UPPER_2;

    /////////////////////// Errors ///////////////////////

    error EthTransferFailed();
    error NoTokensToCollectFees();
    error TooManyTokensToCollectFees();
    error InvalidPositionIndex();
    error InvalidPositionIndexes();
    error UnauthorizedFeeCollection();

    /////////////////////// Events ///////////////////////

    event TokenGraduated(
        address indexed token, bytes32 poolId, uint256 tokenAmount, uint256 ethAmount, uint256 liquidity
    );

    event LpFeesCollected(
        address indexed token,
        uint256 indexed positionId,
        address tokenOwner,
        uint256 positionIndex,
        uint256 creatorFees
    );
    event LpFeesCollectionTransferFailed(
        address indexed token,
        uint256 indexed positionId,
        address tokenOwner,
        uint256 positionIndex,
        uint256 creatorFees
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

        SQRT_PRICEX96_LOWER_TICK = uint160(TickMath.getSqrtPriceAtTick(TICK_LOWER));
        SQRT_PRICEX96_UPPER_TICK = uint160(TickMath.getSqrtPriceAtTick(TICK_UPPER));

        // secondary eth liquidity position
        SQRT_LOWER_2 = uint160(TickMath.getSqrtPriceAtTick(TICK_LOWER_2));
        SQRT_UPPER_2 = uint160(TickMath.getSqrtPriceAtTick(TICK_UPPER_2));

        // approve the LIQUIDITY_LOCK to pull any NFT liquidity in this contract
        // instead of having to approve every NFT on every graduation to save gas
        IERC721(_positionManager).setApprovalForAll(_liquidityLock, true);
    }

    modifier onlyLaunchpad() {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        _;
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice To receive eth when collecting fees from the position manager
    /// @dev this function assumes that there is never eth balance in this contract
    /// @dev Any eth balance will be considered as fees collected by the next call to collect fees
    receive() external payable {}

    /// @notice Initializes a Uniswap V4 pool for the token
    /// @param tokenAddress Address of the token
    /// @return Address of the pool manager (same for all tokens, but to comply with the ILivoGraduator interface)
    function initializePair(address tokenAddress) external override onlyLaunchpad returns (address) {
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
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        // the tokenAmount needs to be in this contract balance before the call. Otherwise it reverts
        uint256 ethValue = msg.value;
        require(tokenAmount > 0, NoTokensToGraduate());
        require(ethValue > 0, NoETHToGraduate());

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
        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
        uint256 ethBalanceBefore = address(this).balance;

        // uniswap v4 liquidity position creation
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICEX96_GRADUATION, // current pool price --> presumably the starting price which cannot be modified until graduation
            SQRT_PRICEX96_LOWER_TICK, // lower tick price -> max token price denominated in eth
            SQRT_PRICEX96_UPPER_TICK, // upper tick price -> min token price denominated in eth
            ethValue, // desired amount0
            tokenAmount // desired amount1
        );
        // receive the excess eth here, to add the next position
        _addLiquidity(pool, tokenAddress, TICK_LOWER, TICK_UPPER, liquidity1, ethValue, tokenAmount, address(this));

        // remaining eth = eth value - (deposited ETH liquidity 1)
        uint256 remainingEth = ethValue - (ethBalanceBefore - address(this).balance);
        uint128 liquidity2 = LiquidityAmounts.getLiquidityForAmount0(SQRT_LOWER_2, SQRT_UPPER_2, remainingEth);
        // single sided ETH liquidity position to utilize remaining eth
        _addLiquidity(pool, tokenAddress, TICK_LOWER_2, TICK_UPPER_2, liquidity2, remainingEth, 0, treasury);

        // there may be a small leftover of tokens not deposited
        uint256 tokenBalanceAfterDeposit = token.balanceOf(address(this));
        uint256 tokensDeposited = tokenAmount - tokenBalanceAfterDeposit;

        bytes32 poolId = PoolId.unwrap(pool.toId());
        emit TokenGraduated(tokenAddress, poolId, tokensDeposited, ethValue, liquidity1 + liquidity2);
    }

    /// @notice Collects ETH fees from graduated tokens and distributes them to token owners and treasury
    /// @dev Token owners can only claim for their own tokens. Contract owner can claim on behalf of anyone.
    /// @dev Token fees are left in this contract (effectively burned, but without gas waste)
    /// @dev Each token fees are claimed and distributed independently
    /// @param tokens Array of token addresses to collect fees from
    /// @param positionIndexes Array of position indexes to collect fees from (only 0 or 1 are valid values)
    function collectEthFees(address[] calldata tokens, uint256[] calldata positionIndexes) external {
        uint256 nTokens = tokens.length;
        require(nTokens > 0, NoTokensToCollectFees());
        require(nTokens < 100, TooManyTokensToCollectFees());
        require(positionIndexes.length > 0, InvalidPositionIndexes());
        require(positionIndexes.length <= 2, InvalidPositionIndexes());

        // Validate all position indexes upfront
        for (uint256 p = 0; p < positionIndexes.length; p++) {
            require(positionIndexes[p] <= 1, InvalidPositionIndex());
        }

        // Access control: only contract owner can claim on behalf of others
        // Token owners can only claim for their own tokens
        bool isContractOwner = msg.sender == owner();

        // Iterate over tokens first (outer loop) to cache tokenOwner and reduce external calls
        for (uint256 i = 0; i < nTokens; i++) {
            address token = tokens[i];
            // Cache token owner once per token (instead of calling getTokenOwner multiple times)
            // the token owner can be updated in the launchpad even after graduation (only by the current owner)
            address tokenOwner = ILivoLaunchpad(LIVO_LAUNCHPAD).getTokenOwner(token);
            
            // Authorization check: verify caller owns this token (unless they're the contract owner)
            if (!isContractOwner) {
                require(msg.sender == tokenOwner, UnauthorizedFeeCollection());
            }

            // Iterate over position indexes (inner loop)
            for (uint256 p = 0; p < positionIndexes.length; p++) {
                uint256 positionIndex = positionIndexes[p];
                
                // collect fees from uniswap4 into this contract (both eth and tokens)
                uint256 positionId = positionIds[token][positionIndex];
                (uint256 creatorFees,) = _claimFromUniswapLock(token, positionId);
                // skip eth transfer if no fees collected for token owner. Eth balance is considered part of the treasury
                if (creatorFees == 0) continue;

                // attempt to transfer ether. If it fails, the transfer is skip and the funds are considered part of the treasury
                // This is to prevent fallback functions DOS the fee collection for the treasury.
                (bool success,) = address(tokenOwner).call{value: creatorFees}("");

                if (success) {
                    emit LpFeesCollected(token, positionId, tokenOwner, positionIndex, creatorFees);
                } else {
                    // emit event for transparency, in case we needed to manually transfer the funds later
                    emit LpFeesCollectionTransferFailed(token, positionId, tokenOwner, positionIndex, creatorFees);
                }
            }
        }
        // the remaining eth balance is considered part of the treasury, and can be collected with sweep()
    }

    /// @notice Sweeps the ETH fees collected in this contract to the treasury
    /// @dev Any ETH in this contract balance is considered part of the treasury
    /// @dev When claiming LPfees, the treasury ETH is left here to save gas and to avoid that the treasury can cause reverts on fee claims
    function sweep() external {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            (bool success,) = address(treasury).call{value: ethBalance}("");
            require(success, EthTransferFailed());
        }
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the claimable ETH fees for each token in the array
    /// @dev For each amount in creatorEthFees, the treasury can expect the same amount as well
    /// @param tokens Array of token addresses
    /// @param positionIndex Index of the position to check for each token. Use 0 as default, as it collects the majority of the fees
    /// @return creatorEthFees Array of claimable ETH fees for token owners
    function getClaimableFees(address[] calldata tokens, uint256 positionIndex)
        external
        view
        returns (uint256[] memory creatorEthFees)
    {
        uint256 len = tokens.length;
        creatorEthFees = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            creatorEthFees[i] = _viewClaimableEthFees(tokens[i], positionIndex);
        }
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    function _getPoolKey(address tokenAddress) internal view virtual returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });
    }

    function _addLiquidity(
        PoolKey memory pool,
        address token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 ethValue,
        uint256 tokenAmount,
        address excessEthReceiver
    ) internal {
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
        uint256 positionId = IPositionManager(UNIV4_POSITION_MANAGER).nextTokenId();
        positionIds[token].push(positionId);

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(UNIV4_POSITION_MANAGER).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );

        // locks the liquidity position NFT in the liquidity lock contract
        LIQUIDITY_LOCK.lockUniV4Position(positionId, address(this));
    }

    function _claimFromUniswapLock(address token, uint256 positionId)
        internal
        returns (uint256 creatorFees, uint256 treasuryFees)
    {
        // collect fees will result in an eth transfer to this contract
        uint256 balanceBefore = address(this).balance;

        // claim fees to this contract and distribute between livo treasury and token owner
        LIQUIDITY_LOCK.claimUniV4PositionFees(positionId, address(0), token, address(this));

        // eth fees collected in this call
        uint256 collectedEthFees = address(this).balance - balanceBefore;

        // 50/50 split of the eth fees between livo treasury and token owner
        treasuryFees = collectedEthFees / 2;
        creatorFees = collectedEthFees - treasuryFees;
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
                poolId, address(UNIV4_POSITION_MANAGER), TICK_LOWER, TICK_UPPER, bytes32(positionId)
            );
            (feeGrowthInside0X128,) = UNIV4_POOL_MANAGER.getFeeGrowthInside(poolId, TICK_LOWER, TICK_UPPER);
        } else {
            (liquidity, feeGrowthInside0LastX128,) = UNIV4_POOL_MANAGER.getPositionInfo(
                poolId, address(UNIV4_POSITION_MANAGER), TICK_LOWER_2, TICK_UPPER_2, bytes32(positionId)
            );
            (feeGrowthInside0X128,) = UNIV4_POOL_MANAGER.getFeeGrowthInside(poolId, TICK_LOWER_2, TICK_UPPER_2);
        }

        uint128 tokenAmount = (FullMath.mulDiv(
                feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128
            ))
        .toUint128();

        creatorEthFees = tokenAmount - tokenAmount / 2;
    }
}
