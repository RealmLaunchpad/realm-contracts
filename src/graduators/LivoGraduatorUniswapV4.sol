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
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {PositionConfig, PositionConfigLibrary} from "lib/v4-periphery/src/libraries/PositionConfig.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {ILiquidityLockUniv4WithFees} from "src/interfaces/ILiquidityLockUniv4WithFees.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator {
    using SafeERC20 for ILivoToken;
    using PositionConfigLibrary for PositionConfig;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Associated liquidity positionIds for each graduated token
    mapping(address token => uint256 tokenId) public positionIds;

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Contract where the liquidity NFTs will be locked
    ILiquidityLockUniv4WithFees public immutable liquidityLock;

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

    /// @notice Uniswap V4 pool manager contract
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 position manager contract
    IPositionManager public immutable positionManager;

    /// @notice Uniswap V4 NFT positions contract
    IERC721 public immutable univ4NftPositions;

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
    /// @dev Graduation price: 39011306440 tokens per ETH -> 0.000000000025633594 eth per token -> sqrtX96price: 401129254579132618442796085280768 -> tick: 170600
    uint160 constant SQRT_PRICEX96_GRADUATION = 401129254579132618442796085280768;

    /// @notice The sqrtX96 price at the high tick, i.e., the minimum token price denominated in ETH
    /// @dev Derived from the high-tick in constructor
    uint160 immutable SQRT_PRICEX96_UPPER_TICK;

    /// @notice The sqrtX96 price at the low tick, i.e., the maximum token price denominated in ETH
    /// @dev Derived from the low-tick in constructor
    uint160 immutable SQRT_PRICEX96_LOWER_TICK;

    /////////////////////// Errors ///////////////////////

    error EthTransferFailed();
    error NoTokensToCollectFees();
    error TooManyTokensToCollectFees();

    //////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V4 graduator
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _liquidityLock Address of the liquidity lock contract
    /// @param _poolManager Address of the Uniswap V4 pool manager
    /// @param _positionManager Address of the Uniswap V4 position manager
    /// @param _permit2 Address of the Permit2 contract
    /// @param _univ4NftPositions Address of the Uniswap V4 NFT positions contract
    constructor(
        address _launchpad,
        address _liquidityLock,
        address _poolManager,
        address _positionManager,
        address _permit2,
        address _univ4NftPositions
    ) {
        LIVO_LAUNCHPAD = _launchpad;
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(_permit2);
        univ4NftPositions = IERC721(_univ4NftPositions);
        liquidityLock = ILiquidityLockUniv4WithFees(_liquidityLock);

        SQRT_PRICEX96_LOWER_TICK = uint160(TickMath.getSqrtPriceAtTick(TICK_LOWER));
        SQRT_PRICEX96_UPPER_TICK = uint160(TickMath.getSqrtPriceAtTick(TICK_UPPER));

        // approve the liquidityLock to pull any NFT liquidity in this contract
        // instead of having to approve every NFT on every graduation to save gas
        univ4NftPositions.setApprovalForAll(_liquidityLock, true);
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
        poolManager.initialize(pool, SQRT_PRICEX96_GRADUATION);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, which forbids token transfers to the pool until graduation
        // to prevent liquidity deposits & trades before being graduated
        emit PairInitialized(tokenAddress, address(poolManager));

        return address(poolManager);
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V4
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        uint256 ethValue = msg.value;
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethValue > 0, NoETHToGraduate());

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // no tokens balance is expected in this contract for more than the graduation transaction,
        // so no problem with having these dangling approvals

        // approve permit2 as a spender
        token.approve(address(permit2), type(uint256).max);
        // approve `PositionManager` as a spender
        IAllowanceTransfer(address(permit2)).approve(
            address(token), // approved token
            address(positionManager), // spender
            type(uint160).max, // amount
            type(uint48).max // expiration
        );

        // uniswap v4 liquidity position creation
        uint256 liquidity = _depositLiquidity(tokenAddress, tokenBalance, ethValue);

        // there may be a smal leftover of tokens not deposited
        uint256 tokenBalanceAfterDeposit = token.balanceOf(address(this));
        uint256 tokensDeposited = tokenBalance - tokenBalanceAfterDeposit;

        emit TokenGraduated(tokenAddress, address(poolManager), tokensDeposited, ethValue, liquidity);
    }

    /// @notice Collects ETH fees from graduated tokens and distributes them to creators and treasury
    /// @dev Any account can call this function.
    /// @dev Token fees are left in this contract (effectively burned, but without gas waste)
    /// @dev Each token fees are claimed and distributed independently
    /// @param tokens Array of token addresses to collect fees from
    function collectEthFees(address[] calldata tokens) external {
        uint256 len = tokens.length;
        require(len > 0, NoTokensToCollectFees());
        require(len < 100, TooManyTokensToCollectFees());

        uint256 totalTreasuryFees = 0;
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            // collect fees from uniswap4 into this contract (both eth and tokens)
            (uint256 creatorFees, uint256 treasuryFees) = _claimFromUniswap(token);
            totalTreasuryFees += treasuryFees;

            address tokenCreator = ILivoLaunchpad(LIVO_LAUNCHPAD).getTokenCreator(token);
            _transferEth(tokenCreator, creatorFees);
        }

        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
        // put together all the treasury transfers into one tx for gas efficiency
        _transferEth(treasury, totalTreasuryFees);
    }

    /// @notice Sweeps any remaining ETH in this contract to the treasury
    /// @dev No ETH balance should be in this contract at any point.
    ///      It should be either deposited as liquidity or collected as fees and immediately transferred out
    ///      So this is just a cautionary measure
    function sweep() external {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            _transferEth(treasury, ethBalance);
        }
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Returns the claimable ETH fees for each token in the array
    /// @dev For each amount in creatorEthFees, the treasury can expect the same amount as well
    /// @param tokens Array of token addresses
    /// @return creatorEthFees Array of claimable ETH fees for creators
    function getClaimableFees(address[] calldata tokens) public view returns (uint256[] memory creatorEthFees) {
        uint256 len = tokens.length;
        creatorEthFees = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            creatorEthFees[i] = _viewClaimableEthFees(tokens[i]);
        }
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    function _getPoolKey(address tokenAddress) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // no hooks
        });
    }

    function _depositLiquidity(address tokenAddress, uint256 tokenAmount, uint256 ethValue)
        internal
        returns (uint128 liquidity)
    {
        address excessEthRecipient = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        PoolKey memory pool = _getPoolKey(tokenAddress);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            uint160(SQRT_PRICEX96_GRADUATION), // current pool price --> presumably the starting price which cannot be modified until graduation
            uint160(SQRT_PRICEX96_LOWER_TICK), // lower tick price -> max token price denominated in eth
            uint160(SQRT_PRICEX96_UPPER_TICK), // upper tick price -> min token price denominated in eth
            ethValue, // desired amount0
            tokenAmount // desired amount1
        );

        // Actions for ETH liquidity positions
        // 1. Mint position
        // 2. Settle pair (send ETH and tokens)
        // 3. Sweep any remaining native ETH back to the treasury (only required with native eth positions)
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);

        // parameters for MINT_POSITION action. Receive the NFT here, and then lock it in the liquidity lock
        params[0] = abi.encode(pool, TICK_LOWER, TICK_UPPER, liquidity, ethValue, tokenAmount, address(this), "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, excessEthRecipient); // sweep all remaining native ETH to recipient

        // read the next positionId before minting the position
        uint256 positionId = positionManager.nextTokenId();
        positionIds[tokenAddress] = positionId;

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(positionManager).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );

        // locks the liquidity position NFT in the liquidity lock contract
        liquidityLock.lockUniV4Position(positionId);
    }

    function _claimFromUniswap(address token) internal returns (uint256 creatorFees, uint256 treasuryFees) {
        // collect fees will result in an eth transfer to this contract
        uint256 balanceBefore = address(this).balance;

        // claim fees to this contract and distribute between livo treasury and token creator
        liquidityLock.claimUniV4PositionFees(positionIds[token], address(0), token, address(this));

        // eth fees collected in this call
        uint256 collectedEthFees = address(this).balance - balanceBefore;

        // 50/50 split of the eth fees between livo treasury and token creator
        treasuryFees = collectedEthFees / 2;
        creatorFees = collectedEthFees - treasuryFees;
    }

    function _viewClaimableEthFees(address token) internal view returns (uint256 creatorEthFees) {
        PoolKey memory poolKey = _getPoolKey(token);

        PoolId poolId = poolKey.toId();
        uint256 positionId = positionIds[token];

        (uint128 liquidity, uint256 feeGrowthInside0LastX128,) =
            poolManager.getPositionInfo(poolId, address(positionManager), TICK_LOWER, TICK_UPPER, bytes32(positionId));

        (uint256 feeGrowthInside0X128,) = poolManager.getFeeGrowthInside(poolId, TICK_LOWER, TICK_UPPER);

        uint128 tokenAmount = (
            FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128)
        ).toUint128();

        creatorEthFees = tokenAmount / 2;
    }

    function _transferEth(address to, uint256 value) internal {
        (bool success,) = address(to).call{value: value}("");
        require(success, EthTransferFailed());
    }
}
