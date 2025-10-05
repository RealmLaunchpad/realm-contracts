// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILivoGraduator} from "src/interfaces/ILivoGraduator.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {ILivoLaunchpad} from "src/interfaces/ILivoLaunchpad.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
// import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
// import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
// import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

// import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
// import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// // import {BasicHooks} from "src/BasicHooks.sol";

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
// import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
// import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
// import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
// import {Commands} from "src/dependencies/Univ4UniversalRouterCommands.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";

contract LivoGraduatorUniswapV4 is ILivoGraduator {
    using SafeERC20 for ILivoToken;

    // to burn excess tokens not deposited as liquidity at graduation
    address internal constant DEAD_ADDRESS = address(0xdEaD);

    IPermit2 public immutable permit2;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    /// @notice Address of the livo launchpad
    address public immutable LIVO_LAUNCHPAD;

    // todo make hook to distribute lp fees to treasury & token creator
    // todo perhaps eth on buys, token on sells
    /// @notice LP fees in pips, i.e. 1e6 = 100%, so 10000 = 1%
    uint24 constant lpFee = 10000;

    /// @notice tick spacing used to be 200 for volatile pairs in univ3. (60 for 0.3% fee tier)
    /// @dev the larger the spacing the cheaper to swap gas-wise
    int24 constant tickSpacing = 200;

    //////////////////////////// price set-point ///////////////////////////////

    // In the uniswapV4 pool, the pair is (currency0,currency1) = (nativeEth, token)
    // The `sqrtPriceX96` is denominated as sqrt(amountToken1/amountToken0) * 2^96,
    // so tokens/ETH (eth price of one token). Thus, the starting point is a high number,
    // lots of tokens for 1 eth.

    /// @notice starting price: 333333334 tokens/ETH (equivalent to 0.000000003 ETH/token).
    uint160 constant sqrtPriceBX96_tokensPerEth = 1446501728071428127725498493042688;

    // the starting price defined above (max price) must be inside the liquidity range // review
    // thus the upper boundary of the liquidity range must be slightly higher .
    // The price above would correspond to an upper tick of 196256,
    // but to align with 200 tick spacing, and include the starting price, we round UP to 196400
    /// @notice the upper boundary of the liquidity range when the position is created.
    int24 constant tickUpper = 196400;

    // for the lower tick (max token price expressed in ETH),
    // We consider the current market cap of BTC as a reasonable maximum price (2305 billion USD)
    // With a token supply of 1 billion, this corresponds to 2305 USD/token.
    // The price is denominated in ETH. If ETH price is 2305 USD/ETH, the token price would be 1:1.
    // to be conservative, we consider the scenario in which ETH goes down significantly: ETH price (2.3$ / ETH).
    // So the max price covered by the liquidity position will be at 0.001 tokens/ETH (1000 ETH/token)
    /// @notice maximum conceivable token price of the liquidity range (0.001 tokens/ETH)
    uint160 constant sqrtPriceAX96_tokensPerEth = 2505414483750479155158843392;

    // The upper ticket for that max token price above would be 69081,
    // but to align it with -196200 and the tick spacing, we round it down to 69000, which is still pretty conservative
    /// @notice the lower boundary of the liquidity range when the position is created
    int24 constant tickLower = -69000;

    // todo perhaps the starting price can be derived from the ethvalue and tokenReserves transferred
    // this starting price is roughly 338156060 tokens for 1 wei, i.e. 0.000000003 ETH/token
    // just below the upper tick price. In range, but minimal eth required to mint the position.
    /// @notice starting price when initializing the Uniswap-v4 pair
    uint160 constant startingPriceX96 = sqrtPriceBX96_tokensPerEth - 1;

    error EthTransferFailed();

    constructor(address _launchpad, address _poolManager, address _positionManager, address _permit2) {
        LIVO_LAUNCHPAD = _launchpad;
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(_permit2);
    }

    modifier onlyLaunchpad() {
        require(msg.sender == LIVO_LAUNCHPAD, OnlyLaunchpadAllowed());
        _;
    }

    function initializePair(address tokenAddress) external override onlyLaunchpad returns (address) {
        PoolKey memory pool = _getPoolKey(tokenAddress);

        // this sets the price even if there is no liquidity yet
        // todo make sure this price is slightly higher than the last price in the bonding curve
        poolManager.initialize(pool, startingPriceX96);

        // in univ4, there is not a pair address.
        // We return the address of the pool manager, which forbids token transfers to the pool until graduation
        // to prevent liquidity deposits & trades before being graduated
        emit PairInitialized(tokenAddress, address(poolManager));

        return address(poolManager);
    }

    function graduateToken(address tokenAddress) external payable override onlyLaunchpad {
        ILivoToken token = ILivoToken(tokenAddress);

        // eth can only enter through msg.value, and all of it is deposited as liquidity
        uint256 ethValue = msg.value;
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance > 0, NoTokensToGraduate());
        require(ethValue > 0, NoETHToGraduate());

        // this opens the gate of transferring tokens to the uniswap pair
        token.markGraduated();

        // approve permit2 as a spender
        token.approve(address(permit2), type(uint256).max);

        // approve `PositionManager` as a spender
        IAllowanceTransfer(address(permit2)).approve(
            address(token), address(positionManager), type(uint160).max, type(uint48).max
        );

        // uniswap v4 liquidity position creation
        // question where should we put the nft? -> wherever we need to collect fees
        _depositLiquidity(tokenAddress, tokenBalance, ethValue);

        // burn excess tokens that are left in this contract
        _cleanUp(tokenAddress);

        // emit TokenGraduated(tokenAddress, pair, tokenBalance, amountEth, liquidity);// todo
    }

    function _getPoolKey(address tokenAddress) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(address(tokenAddress)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0)) // no hooks ? // todo build necessary hooks if relevant
        });
    }

    function _depositLiquidity(address tokenAddress, uint256 tokenAmount, uint256 ethValue) internal {
        address excessEthRecipient = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();

        PoolKey memory pool = _getPoolKey(tokenAddress);

        // todo if we specify the token amount we need to collect any excess eth back
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            uint160(sqrtPriceAX96_tokensPerEth), // lower tick price (max token price)
            uint160(sqrtPriceBX96_tokensPerEth), // upper tick price (min token price)
            tokenAmount // desired amount1
        );

        // =============== todo REMOVE ALL THESE ===============
        // review this is only for sanity check purposes, and should be removed
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
            uint160(sqrtPriceAX96_tokensPerEth), // lower tick price (max token price)
            uint160(sqrtPriceBX96_tokensPerEth), // upper tick price (min token price)
            ethValue // desired amount1
        );
        require(liquidity > 0, "NoLiquidityCreated");
        require(liquidity0 > 0, "NoLiquidity0Created");
        require(liquidity0 <= liquidity, "Eth should be the limiting factor");
        // ===========================================================

        //        // todo explore what happens when excess eth is deposited as liquidity (can I keep same range, same starting price, etc?)
        //        // calculate liquidity based on the startingPrice and the range
        //        // calculate the liquidity range, assuming we just hit graduation exactly // todo
        //        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
        //            uint160(startingPriceX96), // current pool price --> presumably the starting price which cannot be modified until graduation
        //            uint160(sqrtPriceAX96_tokensPerEth), // lower tick price
        //            uint160(sqrtPriceBX96_tokensPerEth), // upper tick price
        //            ethValue, // desired amount0
        //            tokenAmount // desired amount1  // todo make sure we are not left with any excess tokens. Allocate excess tokens/eth
        //        );

        // Actions for ETH liquidity positions
        // 1. Mint position
        // 2. Settle pair (send ETH and tokens)
        // 3. Sweep any remaining native ETH back to the treasury (only required with native eth positions)
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);

        // parameters for MINT_POSITION action
        // review if this contract should be the receiver of the position NFT
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethValue, tokenAmount, address(this), "");

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

    function _cleanUp(address token) internal returns (uint256 burnedTokens) {
        burnedTokens = ILivoToken(token).balanceOf(address(this));
        // we could include some checks here to prevent bruning too much supply,
        // but that would put graduation at risk of DOS
        ILivoToken(token).safeTransfer(DEAD_ADDRESS, burnedTokens);

        // todo do something with excess eth
        // todo remaining eth is transferred to the caller (last buyer) // review this
    }

    /// @notice Any account can collect these fees on behalf of token creators and livo treasury
    /// @notice Token creators receive fees in the form of tokens, and livo treasury in ETH (review how to enforce 50/50 split)
    function collectEthFees() external {
        address treasury = ILivoLaunchpad(LIVO_LAUNCHPAD).treasury();
        uint256 balance = treasury.balance;

        _transferEth(treasury, balance);
    }

    function _transferEth(address to, uint256 value) internal {
        (bool success,) = address(to).call{value: value}("");
        require(success, EthTransferFailed());
    }
    /// @notice Allows receiving native eth fees from uniswapV4 fees

    receive() external payable {}
}
