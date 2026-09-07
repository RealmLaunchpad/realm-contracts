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
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
// Both imports are aliased so the `chain-arc-*` recipe can import-swap them at build time.
import {UniswapV4PoolConstants as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {GraduationFeeConstants as GraduationFeeConstants} from "src/libraries/GraduationFeeConstants.sol";
import {ILivoUniV4LiquidityAdder} from "src/liquidity/LivoUniV4LiquidityAdder.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator, Ownable {
    using SafeERC20 for ILivoToken;
    using PoolIdLibrary for PoolKey;

    /// @notice Graduation native fee (creator compensation + treasury fee). Per-chain via the aliased lib.
    uint256 public constant GRADUATION_ETH_FEE = GraduationFeeConstants.GRADUATION_FEE;

    /// @notice ETH compensation paid to token creator at graduation (half of the fee)
    /// @dev this is part of the GRADUATION_ETH_FEE
    uint256 public constant CREATOR_GRADUATION_COMPENSATION = GRADUATION_ETH_FEE / 2;

    /// @notice Sink for the token dust left over after the graduation liquidity deposit.
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    /// @notice Address of the LivoLaunchpad contract
    address public immutable LIVO_LAUNCHPAD;

    /// @notice Permit2 contract for token approvals
    address public immutable PERMIT2;

    /// @notice Uniswap V4 pool manager contract
    IPoolManager public immutable UNIV4_POOL_MANAGER;

    /// @notice Uniswap V4 position manager contract
    address public immutable UNIV4_POSITION_MANAGER;

    /// @notice Hook contract address for pool interactions
    address public immutable HOOK_ADDRESS;

    //////////////////////////// price set-point ///////////////////////////////

    /// @notice Starting price when graduation occurs, which must be inside the liquidity range.
    /// @dev Per liquidity tier, set at deploy (the graduation tick is derived from it on-chain).
    ///      DEFAULT: 715832709642994126662528799866880 (12.25 ETH mcap, 12250000000 wei/token).
    ///      THIN: 1012340326367404053977557838594048 (6.125 ETH mcap). THICK:
    ///      506170163183702026988778919297024 (24.5 ETH mcap).
    uint160 immutable SQRT_PRICEX96_GRADUATION;

    /// @notice The upper tick of the primary liquidity range (tier-specific). Thinner tiers graduate at a
    ///         higher tick with a shallower pool, so they need a higher upper tick to let a holder sell
    ///         their full bag back into the pool.
    int24 immutable TICK_UPPER;

    /// @notice The sqrtX96 price at the high tick, i.e., the minimum token price denominated in ETH
    /// @dev Derived from the high-tick in constructor
    uint160 immutable SQRT_PRICEX96_UPPER_TICK;

    /// @notice The sqrtX96 price at the low tick, i.e., the maximum token price denominated in ETH
    /// @dev Derived from the low-tick in constructor
    uint160 immutable SQRT_PRICEX96_LOWER_TICK;

    //////////////////////// SECOND LIQUIDITY POSITION (ONLY ETH) ////////////////////////////

    /// @notice The lower tick of the secondary ETH-only position. Tier-specific (the first spacing
    ///         boundary above the graduation tick), so the position sits just below the graduation price.
    int24 immutable TICK_LOWER_SECONDARY;
    /// @notice The upper tick of the secondary ETH-only position. Tier-specific (a fixed offset below
    ///         `TICK_UPPER`).
    int24 immutable TICK_UPPER_SECONDARY;

    /// @notice The shared, permissionless `LivoUniV4LiquidityAdder` singleton — deployed once, independent
    ///         of any graduator, and passed in at construction. Used here for the secondary graduation
    ///         position and reused by taxable tokens' `processLiquidity` (they resolve it via this getter).
    address public immutable LIQUIDITY_ADDER;

    /////////////////////// Errors ///////////////////////

    error EtherTransferFailed();
    /// @notice Thrown if the graduation price passed at deploy is zero or falls outside the liquidity range.
    error InvalidGraduationPrice();
    /// @notice Thrown if the shared liquidity adder passed at deploy is the zero address.
    error InvalidLiquidityAdder();

    /////////////////////// Events ///////////////////////

    event PoolIdRegistered(address indexed token, bytes32 poolId, address swapHookAddress);

    //////////////////////////////////////////////////////

    /// @notice Initializes the Uniswap V4 graduator
    /// @param _launchpad Address of the LivoLaunchpad contract
    /// @param _poolManager Address of the Uniswap V4 pool manager
    /// @param _positionManager Address of the Uniswap V4 position manager
    /// @param _permit2 Address of the Permit2 contract
    /// @param _hook Address of the hook contract
    /// @param _sqrtPriceGraduation The exact pool price at graduation (tier-specific). The pool is
    ///        initialized at this price; liquidity is sized from it. The graduation tick (and hence the
    ///        secondary single-sided ETH position) is derived on-chain from it, so it is robust to how
    ///        `simulations/script/uniswapV4Settings.py` rounds the tick.
    /// @param _tickUpper The upper tick of the primary liquidity range (tier-specific, spacing-aligned).
    ///        Thinner tiers graduate higher with a shallower pool and need a higher upper tick so a holder
    ///        can sell their full bag back into the pool. Use `UniswapV4PoolConstants.TICK_UPPER` for the
    ///        DEFAULT/THICK tiers and `TICK_UPPER_THIN` for the THIN tier.
    /// @param _liquidityAdder The shared `LivoUniV4LiquidityAdder` singleton (deployed separately). All
    ///        graduators point at the same one, and it is what taxable tokens use for `processLiquidity`.
    constructor(
        address _launchpad,
        address _poolManager,
        address _positionManager,
        address _permit2,
        address _hook,
        uint160 _sqrtPriceGraduation,
        int24 _tickUpper,
        address _liquidityAdder
    ) Ownable(msg.sender) {
        // Refuse to deploy graduator bytecode built with the wrong chain's baked constants (fees + pool
        // geometry): the import-swapped fee lib knows which chain family it belongs to. Unforgettable —
        // fires on ANY deploy path; `forge script` simulates first, so a wrong build never broadcasts.
        GraduationFeeConstants.assertDeployableOn(block.chainid);

        LIVO_LAUNCHPAD = _launchpad;
        UNIV4_POOL_MANAGER = IPoolManager(_poolManager);
        UNIV4_POSITION_MANAGER = _positionManager;
        PERMIT2 = _permit2;
        HOOK_ADDRESS = _hook;

        require(_liquidityAdder != address(0), InvalidLiquidityAdder());
        LIQUIDITY_ADDER = _liquidityAdder;

        require(_sqrtPriceGraduation > 0, InvalidGraduationPrice());
        int24 spacing = UniswapV4PoolConstants.TICK_SPACING;
        // The graduation price tick (floor), derived from the price itself.
        int24 gradTick = TickMath.getTickAtSqrtPrice(_sqrtPriceGraduation);
        // The secondary single-sided ETH position starts at the first spacing boundary STRICTLY above
        // the graduation tick, so it sits just below the graduation price (in eth-per-token terms) and
        // is entirely ETH (the pool's current tick is below it). Graduation ticks are positive in the
        // supported range, so integer division floors.
        int24 tickLower2 = (gradTick / spacing + 1) * spacing;
        // The secondary position's upper tick sits a fixed offset below the primary upper tick.
        int24 tickUpper2 = _tickUpper - UniswapV4PoolConstants.TICK_UPPER_2_OFFSET;
        // Sanity: the upper tick must be spacing-aligned, and the price must sit inside the main range and
        // leave room for the secondary position below its upper bound (this also enforces gradTick < upper).
        require(
            _tickUpper % spacing == 0 && gradTick > UniswapV4PoolConstants.TICK_LOWER && tickLower2 < tickUpper2,
            InvalidGraduationPrice()
        );
        SQRT_PRICEX96_GRADUATION = _sqrtPriceGraduation;
        TICK_UPPER = _tickUpper;

        SQRT_PRICEX96_LOWER_TICK = uint160(TickMath.getSqrtPriceAtTick(UniswapV4PoolConstants.TICK_LOWER));
        SQRT_PRICEX96_UPPER_TICK = uint160(TickMath.getSqrtPriceAtTick(_tickUpper));

        // Secondary eth liquidity position, just above the (tier-specific) graduation tick. The liquidity
        // adder sizes and mints it from these ticks at graduation time.
        TICK_LOWER_SECONDARY = tickLower2;
        TICK_UPPER_SECONDARY = tickUpper2;
    }

    ////////////////////////////// EXTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice To receive ETH back from Uniswap V4 when sweeping excess ETH after liquidity provision
    receive() external payable {}

    /// @notice Rescues any ETH accidentally stuck in this contract
    /// @dev ETH is not expected to be held in this contract outside of the graduation transaction. This is just in case ETH is sent by mistake here
    function rescueEthBalance() external onlyOwner {
        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success, EtherTransferFailed());
    }

    /// @notice Initializes a Uniswap V4 pool for the token
    /// @param tokenAddress Address of the token
    /// @return Address of the pool manager (same for all tokens, but to comply with the ILivoGraduator interface)
    function initialize(address tokenAddress) external override returns (address) {
        PoolKey memory pool = _getPoolKey(tokenAddress);

        // this sets the price even if there is no liquidity yet
        UNIV4_POOL_MANAGER.initialize(pool, SQRT_PRICEX96_GRADUATION);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, which forbids token transfers to the pool until graduation
        // to prevent liquidity deposits & trades before being graduated
        emit PairInitialized(tokenAddress, address(UNIV4_POOL_MANAGER));
        emit PoolIdRegistered(tokenAddress, PoolId.unwrap(pool.toId()), HOOK_ADDRESS);

        return address(UNIV4_POOL_MANAGER);
    }

    /// @notice Graduates a token by adding liquidity to Uniswap V4
    /// @param tokenAddress Address of the token to graduate
    function graduateToken(address tokenAddress, uint256 tokenAmount) external payable override {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        ILivoToken token = ILivoToken(tokenAddress);
        require(tokenAmount > 0, NoTokensToGraduate());
        require(msg.value > 0, NoETHToGraduate());

        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        // 1. Handle fee split
        uint256 ethForLiquidity = _handleGraduationFeesV4(tokenAddress, treasury);

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
        (uint128 liquidity1, uint128 liquidity2) = _addLiquidityPositions(pool, ethForLiquidity, tokenAmount, treasury);

        // there may be a small leftover of tokens not deposited
        uint256 tokenBalanceAfterDeposit = token.balanceOf(address(this));
        // we attempt to deposit tokensForLiquidity, but this is the actual amount deposited
        uint256 tokensDeposited = tokenBalanceBeforeDeposit - tokenBalanceAfterDeposit;

        // Burn the leftover rather than hold it forever. A graduator balance is a CONTINUOUS holder of
        // the token and the graduator is NOT in `LivoTaxableToken._dividendExcluded` (adding it would put
        // a cold SLOAD on the hot transfer path), so the dust would accrue dividends nobody can ever
        // claim and permanently understate the token's sweepable balances. `DEAD_ADDRESS` is already
        // excluded, on both the tracking side and in `_dividendEligibleSupply`.
        if (tokenBalanceAfterDeposit > 0) token.safeTransfer(DEAD_ADDRESS, tokenBalanceAfterDeposit);

        emit TokenGraduated(tokenAddress, tokensDeposited, ethForLiquidity, liquidity1 + liquidity2);
    }

    ////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////////////

    /// @notice Splits graduation ETH between creator compensation, treasury, and liquidity
    function _handleGraduationFeesV4(address tokenAddress, address treasury)
        internal
        returns (uint256 ethForLiquidity)
    {
        ethForLiquidity = msg.value - GRADUATION_ETH_FEE;
        uint256 treasuryShare = GRADUATION_ETH_FEE - CREATOR_GRADUATION_COMPENSATION;

        // Deposit creator compensation through the token
        emit CreatorGraduationFeeCollected(tokenAddress, CREATOR_GRADUATION_COMPENSATION);
        ILivoToken(tokenAddress).accrueFees{value: CREATOR_GRADUATION_COMPENSATION}();

        // Send treasury share directly to treasury
        (bool success,) = treasury.call{value: treasuryShare}("");
        require(success, EtherTransferFailed());
        emit TreasuryGraduationFeeCollected(tokenAddress, treasuryShare);
    }

    /// @notice Constructs the Uniswap V4 PoolKey for a given token paired with native ETH
    function _getPoolKey(address tokenAddress) internal view virtual returns (PoolKey memory) {
        return UniswapV4PoolConstants.livoPoolKey(tokenAddress, HOOK_ADDRESS);
    }

    /// @notice Adds primary and secondary liquidity positions
    function _addLiquidityPositions(PoolKey memory pool, uint256 ethForLiquidity, uint256 tokenAmount, address treasury)
        internal
        returns (uint128 liquidity1, uint128 liquidity2)
    {
        uint256 ethBalanceBefore = address(this).balance;

        liquidity1 = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICEX96_GRADUATION, SQRT_PRICEX96_LOWER_TICK, SQRT_PRICEX96_UPPER_TICK, ethForLiquidity, tokenAmount
        );

        _addLiquidity(
            pool, UniswapV4PoolConstants.TICK_LOWER, TICK_UPPER, liquidity1, ethForLiquidity, tokenAmount, address(this)
        );

        uint256 remainingEth = ethForLiquidity - (ethBalanceBefore - address(this).balance);
        if (remainingEth > 0) {
            // Single-sided ETH wall just below the graduation price. NFT stays here (permanently locked);
            // rounding-dust ETH is swept to the treasury. Shares the mint path with tokens' liquidity leg.
            liquidity2 = ILivoUniV4LiquidityAdder(LIQUIDITY_ADDER).addSingleSidedEth{value: remainingEth}(
                pool, TICK_LOWER_SECONDARY, TICK_UPPER_SECONDARY, address(this), treasury
            );
        }
    }

    /// @notice Mints a Uniswap V4 liquidity position. NFT stays in this contract (permanently locked).
    function _addLiquidity(
        PoolKey memory pool,
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

        // parameters for MINT_POSITION action. NFT stays at this contract (permanently locked).
        address nftReceiver = address(this);
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, nftReceiver, "");

        // parameters for SETTLE_PAIR action
        params[1] = abi.encode(pool.currency0, pool.currency1);

        // parameters for SWEEP action
        params[2] = abi.encode(pool.currency0, excessEthReceiver); // sweep all remaining native ETH to recipient

        // the actual call to the position manager to mint the liquidity position
        // deadline = block.timestamp (no effective deadline)
        IPositionManager(UNIV4_POSITION_MANAGER).modifyLiquidities{value: ethValue}(
            abi.encode(actions, params), block.timestamp
        );
    }
}
