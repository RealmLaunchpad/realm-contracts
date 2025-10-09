// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
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

contract LivoGraduatorUniswapV4 is ILivoGraduator {
    using SafeERC20 for ILivoToken;
    using PositionConfigLibrary for PositionConfig;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Each graduated token has an associated liquidity position represented by this tokenId
    mapping(address token => uint256 tokenId) public positionIds;

    // to burn excess tokens not deposited as liquidity at graduation
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    IPermit2 public immutable permit2;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    /// @notice Address of the livo launchpad
    address public immutable LIVO_LAUNCHPAD;

    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    uint24 constant lpFee = 10000;

    /// @notice tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev the larger the spacing the cheaper to swap gas-wise
    int24 constant tickSpacing = 200;

    //////////////////////////// price set-point ///////////////////////////////

    // In the uniswapV4 pool, the pair is (currency0,currency1) = (nativeEth, token)
    // The `sqrtPriceX96` is denominated as sqrt(amountToken1/amountToken0) * 2^96,
    // so tokens/ETH (eth price of one token).
    // Thus, the max token price is found at the low tick, and the min token price at the high tick

    /// @notice the upper boundary of the liquidity range when the position is created,
    /// i.e., the minimum token price denominated in ETH
    /// high tick: 203600 -> 2088220564709554551739049874292736 -> 694694034.078335 tokens per ETH
    /// (the ticks need to be multiples of tickSpacing).
    int24 constant tickUpper = 203600;

    /// @notice the lower boundary of the liquidity range when the position is created
    /// low tick: -7000 -> sqrtX96price: 55832119482513121612260179968 -> 0.49660268342258984 tokens per ETH
    /// i.e., at the maximum token price denominated in ETH
    /// At this tick, the token price would imply a market cap of 2,000,000,000 ETH (8,000,000,000,000 USD with ETH at 4000 USD)
    int24 constant tickLower = -7000;

    /// @notice the sqrtX96 price at the high tick, i.e., the minimum token price denominated in ETH
    /// @dev this is derived from the high-tick
    uint160 immutable sqrtPriceHighLimX96_minTokenPrice;

    /// @notice the sqrtX96 price at the low tick, i.e., the maximum token price denominated in ETH
    /// @dev this is derived from the low-tick
    uint160 immutable sqrtPriceLowLimX96_maxTokenPrice;

    /// @notice starting price when graduation occurs, which must be inside the liquidity range
    // The bonding curve gives an approximate graduation price of 39011306440 tokens per eth,
    // (slightly above the bonding curve which is 39011306436 tokens per eth).
    // A small increase step at graduation is expected, but fairly negligible
    // which in token/eth is 25633594.238583516 tokens per eth
    //converting that to sqrtX96 price is the price below
    // graduation price: 39011306440 tokens per ETH -> 0.000000000025633594 eth per token -> sqrtX96price: 401129254579132618442796085280768 -> tick: 170600
    uint160 constant graduationPriceX96_tokensPerEth = 401129254579132618442796085280768;

    error EthTransferFailed();
    error NoTokensToCollectFees();
    error TooManyTokensToCollectFees();

    constructor(address _launchpad, address _poolManager, address _positionManager, address _permit2) {
        LIVO_LAUNCHPAD = _launchpad;
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(_permit2);

        sqrtPriceLowLimX96_maxTokenPrice = uint160(TickMath.getSqrtPriceAtTick(tickLower));
        sqrtPriceHighLimX96_minTokenPrice = uint160(TickMath.getSqrtPriceAtTick(tickUpper));
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

    function initializePair(address tokenAddress) external override onlyLaunchpad returns (address) {
        PoolKey memory pool = _getPoolKey(tokenAddress);

        // this sets the price even if there is no liquidity yet
        poolManager.initialize(pool, graduationPriceX96_tokensPerEth);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, which forbids token transfers to the pool until graduation
        // to prevent liquidity deposits & trades before being graduated
        emit PairInitialized(tokenAddress, address(poolManager));

        return address(poolManager);
    }

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

        positionIds[tokenAddress] = positionManager.nextTokenId();

        // uniswap v4 liquidity position creation
        uint256 liquidity = _depositLiquidity(tokenAddress, tokenBalance, ethValue);

        // there may be a smal leftover of tokens not deposited
        uint256 tokenBalanceAfterDeposit = token.balanceOf(address(this));
        uint256 tokensDeposited = tokenBalance - tokenBalanceAfterDeposit;

        emit TokenGraduated(tokenAddress, address(poolManager), tokensDeposited, ethValue, liquidity);
    }

    /// @notice Any account can collect these fees on behalf of livo treasury (tokens as fees are left in the pool, so effectively burned)
    /// @dev by reentering
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

    /// @notice sweep any remaining eth in this contract to the treasury
    /// @dev no eth balance should be in this contract at any point. It should be either deposited as liquidity,
    /// or collected as fees and immediately transferred out
    function sweep() external {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
            _transferEth(treasury, ethBalance);
        }
    }

    ////////////////////////////// VIEW FUNCTIONS ///////////////////////////////////

    /// @notice Reads how many eth fees are there claimable for each tokenAddress in the array
    function getClaimableFees(address[] calldata tokens) public view returns (uint256[] memory creatorFees) {
        uint256 len = tokens.length;
        creatorFees = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            creatorFees[i] = _viewClaimableFees(tokens[i]);
        }
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    function _getPoolKey(address tokenAddress) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: lpFee,
            tickSpacing: tickSpacing,
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
            uint160(graduationPriceX96_tokensPerEth), // current pool price --> presumably the starting price which cannot be modified until graduation
            uint160(sqrtPriceLowLimX96_maxTokenPrice), // lower tick price -> max token price denominated in eth
            uint160(sqrtPriceHighLimX96_minTokenPrice), // upper tick price -> min token price denominated in eth
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

        // parameters for MINT_POSITION action
        // review if this contract should be the receiver of the position NFT
        address nftReceiver = address(this);
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, nftReceiver, "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, excessEthRecipient); // sweep all remaining native ETH to recipient

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(positionManager).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );
    }

    function _claimFromUniswap(address token) internal returns (uint256 creatorFees, uint256 treasuryFees) {
        // collecting fees is done by decreasing liquidity by 0
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        // parameters for each of the actions
        bytes[] memory params = new bytes[](2);
        // each graduated token has an associated liquidity position represented by this tokenId
        uint256 positionId = positionIds[token];
        /// @dev collecting fees is achieved by removing liquidity=0, the second parameter
        params[0] = abi.encode(positionId, 0, 0, 0, "");
        // receive the eth here, and then distribute between livo team and token creator
        Currency currency0 = Currency.wrap(address(0)); // tokenAddress1 = 0 for native ETH
        Currency currency1 = Currency.wrap(token);
        params[1] = abi.encode(currency0, currency1, address(this));

        // collect fees will result in an eth transfer to this contract
        uint256 balanceBefore = address(this).balance;

        IPositionManager(positionManager).modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp // no deadline
        );

        uint256 collectedEthFees = address(this).balance - balanceBefore;

        // 50/50 split of the eth fees between livo treasury and token creator
        treasuryFees = collectedEthFees / 2;
        creatorFees = collectedEthFees - treasuryFees;
    }

    function _viewClaimableFees(address token) internal view returns (uint256 creatorEthFees) {
        PoolKey memory poolKey = _getPoolKey(token);

        PoolId poolId = poolKey.toId();
        uint256 positionId = positionIds[token];

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
            poolManager.getPositionInfo(poolId, address(positionManager), tickLower, tickUpper, bytes32(positionId));

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

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
