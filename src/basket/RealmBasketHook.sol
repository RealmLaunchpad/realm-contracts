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

import {RealmBasket} from "src/basket/RealmBasket.sol";
import {RealmBasketAssets} from "src/basket/RealmBasketAssets.sol";
import {RealmBasketFactory} from "src/basket/RealmBasketFactory.sol";

/// @title RealmBasketHook
/// @notice Makes basket shares tradable as a normal V4 token: a shares/USDG pool that holds NO liquidity,
///         where every swap is filled by the basket itself. A buy deposits the USDG into the basket and
///         pays out the minted shares; a sell redeems the shares and pays out the USDG. Same code, same
///         price as calling the basket directly; this is only a second entrance, the one routers reach.
///
/// @dev THE CORE CURVE NEVER RUNS. `beforeSwap` returns a delta covering the whole input, so the pool
///      swaps 0 and its `slot0` stays at whatever it was initialized to. That price means nothing; NAV
///      lives in the basket.
///
/// @dev EXACT INPUT ONLY, mirroring the basket's `deposit`/`redeem` (it has no `mint`/`withdraw`).
///
/// @dev THE INPUT ARRIVES AFTER THE SWAP. Standard routers pay what they owe once the swap returns.
///      - A buy `take`s the USDG from the pool manager before it is paid. A basket that buys through V3
///        pools therefore needs the pool manager to hold that much USDG from other pools (V4 legs hand it
///        straight back). On Robinhood, where USDG is the main V4 quote, that ceiling is high, but it is one.
///      - A sell cannot do the same: the pool manager holds no shares. The basket pays out on credit
///        (`redeemOnCredit`) and the hook mints itself claims on the incoming shares, which locks them in
///        the pool manager for good and takes them out of the basket's `totalSupply`.
contract RealmBasketHook is BaseHook {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Pools are accepted only for baskets this factory deployed. Deployed by this hook.
    RealmBasketFactory public immutable FACTORY;

    /// @notice The other side of every basket pool.
    address public immutable USDG;

    error NotBasketPool();
    error LiquidityNotAccepted();
    error ExactOutputNotSupported();

    constructor(IPoolManager manager, RealmBasketAssets registry) BaseHook(manager) {
        FACTORY = new RealmBasketFactory(registry);
        USDG = registry.USDG();
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

    /// @dev Only a basket/USDG pool may use this hook. Anyone may initialize it.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        _basketOf(key);
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
        require(params.amountSpecified < 0, ExactOutputNotSupported());
        RealmBasket basket = _basketOf(key);
        uint256 amountIn = uint256(-params.amountSpecified);
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 amountOut;
        if (Currency.unwrap(cIn) == USDG) {
            poolManager.take(cIn, address(this), amountIn);
            IERC20(USDG).forceApprove(address(basket), amountIn);
            amountOut = basket.deposit(amountIn, address(this));
        } else {
            amountOut = basket.redeemOnCredit(amountIn, address(this));
            poolManager.mint(address(this), cIn.toId(), amountIn);
        }
        poolManager.sync(cOut);
        IERC20(Currency.unwrap(cOut)).safeTransfer(address(poolManager), amountOut);
        poolManager.settle();

        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(amountIn.toInt256().toInt128(), -amountOut.toInt256().toInt128()),
            0
        );
    }

    function _basketOf(PoolKey calldata key) private view returns (RealmBasket basket) {
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        address other = c0 == USDG ? c1 : c1 == USDG ? c0 : address(0);
        require(other != address(0) && FACTORY.isBasket(other), NotBasketPool());
        return RealmBasket(other);
    }
}
