// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {RealmEtf} from "src/etf/RealmEtf.sol";
import {RealmEtfFactory} from "src/etf/RealmEtfFactory.sol";

/// @title RealmEtfHook
/// @notice Makes ETF shares tradable as a normal V4 token: a shares/USDG pool that holds NO liquidity,
///         where every swap is filled by the ETF itself. A buy deposits the USDG into the ETF and
///         pays out the minted shares; a sell redeems the shares and pays out the USDG. Same code, same
///         price as calling the ETF directly; this is only a second entrance, the one routers reach.
///
/// @dev THE CORE CURVE NEVER RUNS. `beforeSwap` returns a delta covering the whole input, so the pool
///      swaps 0 and its `slot0` stays at whatever it was initialized to. That price means nothing; NAV
///      lives in the ETF.
///
/// @dev EXACT INPUT both ways, mirroring the ETF's `deposit`/`redeem`; EXACT OUTPUT for buys only, through its
///      `mint`. The ETF has no `withdraw`, so exact-output sells revert.
///
/// @dev THE INPUT ARRIVES AFTER THE SWAP. Standard routers pay what they owe once the swap returns.
///      - A buy `take`s the USDG from the pool manager before it is paid. An ETF that buys through V3
///        pools therefore needs the pool manager to hold that much USDG from other pools (V4 legs hand it
///        straight back). On Robinhood, where USDG is the main V4 quote, that ceiling is high, but it is one.
///      - An exact-output buy learns its price only once `mint` has bought every holding, so it `take`s ALL
///        the pool manager's USDG first, lets `mint` pull what it spends, and settles the rest straight back.
///        Same ceiling: the mint's whole cost.
///      - A sell cannot do the same: the pool manager holds no shares. The ETF pays out on credit
///        (`redeemOnCredit`) and the hook mints itself claims on the incoming shares, which locks them in
///        the pool manager for good and takes them out of the ETF's `totalSupply`.
contract RealmEtfHook is BaseHook {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Pools are accepted only for ETFs this factory deployed with this hook.
    RealmEtfFactory public immutable FACTORY;

    /// @notice The other side of every ETF pool.
    address public immutable USDG;

    error NotEtfPool();
    error LiquidityNotAccepted();
    error ExactOutputNotSupported();

    constructor(IPoolManager manager, RealmEtfFactory factory) BaseHook(manager) {
        FACTORY = factory;
        USDG = factory.REGISTRY().USDG();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Only an ETF/USDG pool may use this hook. Anyone may initialize it.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        _etfOf(key);
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAccepted();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        RealmEtf etf = _etfOf(key);
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bool exactIn = params.amountSpecified < 0;
        require(exactIn || Currency.unwrap(cIn) == USDG, ExactOutputNotSupported());

        uint256 amountIn;
        uint256 amountOut;
        if (!exactIn) {
            amountOut = uint256(params.amountSpecified);
            uint256 taken = IERC20(USDG).balanceOf(address(poolManager));
            poolManager.take(cIn, address(this), taken);
            IERC20(USDG).forceApprove(address(etf), taken);
            amountIn = etf.mint(amountOut, address(this));
            poolManager.sync(cIn);
            IERC20(USDG).safeTransfer(address(poolManager), taken - amountIn);
            poolManager.settle();
        } else if (Currency.unwrap(cIn) == USDG) {
            amountIn = uint256(-params.amountSpecified);
            poolManager.take(cIn, address(this), amountIn);
            IERC20(USDG).forceApprove(address(etf), amountIn);
            amountOut = etf.deposit(amountIn, address(this));
        } else {
            amountIn = uint256(-params.amountSpecified);
            amountOut = etf.redeemOnCredit(amountIn, address(this));
            poolManager.mint(address(this), cIn.toId(), amountIn);
        }
        poolManager.sync(cOut);
        IERC20(Currency.unwrap(cOut)).safeTransfer(address(poolManager), amountOut);
        poolManager.settle();

        // The specified side is the input on exact-input swaps and the output on exact-output ones.
        (int128 inDelta, int128 outDelta) = (amountIn.toInt256().toInt128(), -amountOut.toInt256().toInt128());
        return (
            this.beforeSwap.selector,
            exactIn ? toBeforeSwapDelta(inDelta, outDelta) : toBeforeSwapDelta(outDelta, inDelta),
            0
        );
    }

    function _etfOf(PoolKey calldata key) private view returns (RealmEtf etf) {
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        address other = c0 == USDG ? c1 : c1 == USDG ? c0 : address(0);
        require(other != address(0) && FACTORY.isEtf(other) && RealmEtf(other).HOOK() == address(this), NotEtfPool());
        return RealmEtf(other);
    }
}
