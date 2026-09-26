// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {VmSafe} from "lib/forge-std/src/Vm.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";

/// @notice Puts the Robinhood-testnet dummy xStock pools (see `DeployDummyXStocks`) back at their whitelisted
///         price, then thickens them with a fresh full-range position.
/// @dev The pools were seeded with 2 ETH each and trading pushed some of them far off (AMZN ~19x). Per pool:
///      1. swap with `sqrtPriceLimitX96` = the whitelist snapshot (`unitsPerNativeX18`), so the swap stops
///         exactly on the target price, whichever side is cheap. The swap uses a throwaway `PoolSwapTest`,
///         which settles from the broadcaster and refunds unspent ETH.
///      2. mint `ETH_PER_POOL` of full-range liquidity at that price, NFT to the broadcaster.
///      The pool key is read from the whitelist's price source, so the listing and the pool cannot disagree.
///
/// @dev The broadcaster must hold the dummy tokens (sold during the re-peg, paired in the mint); they were
///      all minted to the `DeployDummyXStocks` deployer 0x81f7d06a88223f5a2850411e72256aacc9e27035.
///
/// Usage (dry run):  forge script RepegDummyXStocks --rpc-url rh-testnet --account livo.dev
/// Usage (execute):  just repeg-dummy-xstocks-rh-testnet
///
/// Env:
///   ETH_PER_POOL  (optional) native added to each pool, in wei. Default 20 ETH (120 ETH for the six pools). Also caps the ETH spent
///                 re-pegging a pool whose token is too cheap.
contract RepegDummyXStocks is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant DEFAULT_ETH_PER_POOL = 20 ether;

    uint256 internal ethPerPool;
    address internal deployer;
    RealmAssetsWhitelist internal whitelist;
    ChainConfig.Infra internal infra;
    PoolSwapTest internal router;

    function run() external {
        require(ChainConfig.isRobinhoodTestnet(), "Robinhood testnet only");
        ethPerPool = vm.envOr("ETH_PER_POOL", DEFAULT_ETH_PER_POOL);
        whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        infra = ChainConfig.infra();

        address[6] memory assets = [
            0xaB04eC65d7F7cc9A83a5a9b7f498f952B4f848d3, // AAPL
            0x656B6560b6ADa6bB12a15931a6a0F8bd6370414B, // TSLA
            0xe0B058D16920bC542BBc83A3dCF5c7aFcA541464, // AMZN
            0x089a31AF9EC4f18ecDD2404313a679F5f9d01A5B, // GOOGL
            0xd4Ad8bf17341758b3466C7c7429A1c50c7100d43, // META
            0xd2Bc8D4d0d0E50F201b26176daa7c24592c98E99 // NVDA
        ];

        vm.startBroadcast();
        deployer = _broadcaster();
        console.log("Deployer: %s, ETH per pool: %d wei", deployer, ethPerPool);
        router = new PoolSwapTest(IPoolManager(infra.univ4PoolManager));
        for (uint256 i; i < assets.length; ++i) {
            _fix(assets[i]);
        }
        vm.stopBroadcast();
    }

    function _fix(address token) internal {
        IPoolManager manager = IPoolManager(infra.univ4PoolManager);
        PoolKey memory key = whitelist.priceSource(token).key;
        require(
            Currency.unwrap(key.currency0) == address(0) && Currency.unwrap(key.currency1) == token,
            "not a native/token pool"
        );
        uint256 rate = whitelist.unitsPerNativeX18(token);
        require(rate != 0, "not whitelisted");
        uint160 target = _sqrtPriceX96(rate);

        (uint160 before,,,) = manager.getSlot0(key.toId());
        _repeg(key, before, target);
        (uint160 afterSwap,,,) = manager.getSlot0(key.toId());
        require(afterSwap == target, "re-peg did not reach target; raise ETH_PER_POOL");

        uint128 added = _addLiquidity(key, target);
        console.log("%s %s", IERC20Metadata(token).symbol(), token);
        console.log("   tokens per ETH (1e18) %d -> %d", _perEth(before), _perEth(target));
        console.log("   +liquidity %d", added);
    }

    /// @dev Exact-input swap bounded by the price limit, so it stops on `target`. Token too expensive
    ///      (price below target in token-per-ETH terms) -> sell tokens; too cheap -> sell ETH.
    function _repeg(PoolKey memory key, uint160 current, uint160 target) internal {
        if (current == target) return;
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        bool zeroForOne = current > target;
        uint256 amountIn = zeroForOne ? ethPerPool : token.balanceOf(deployer);
        if (!zeroForOne) token.approve(address(router), amountIn);
        router.swap{value: zeroForOne ? ethPerPool : 0}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: target
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Same full-range mint as `DeployDummyXStocks._seedLiquidity`: ETH is the binding side.
    function _addLiquidity(PoolKey memory key, uint160 sqrtPriceX96) internal returns (uint128 liquidity) {
        address token = Currency.unwrap(key.currency1);
        uint256 tokenBudget = IERC20(token).balanceOf(deployer);
        IERC20(token).approve(infra.permit2, type(uint256).max);
        IAllowanceTransfer(infra.permit2)
            .approve(token, infra.univ4PositionManager, type(uint160).max, type(uint48).max);

        int24 tickLower = (TickMath.MIN_TICK / key.tickSpacing) * key.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethPerPool,
            tokenBudget
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, ethPerPool, tokenBudget, deployer, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, deployer);
        // Deadline an hour out: the script encodes it during simulation and broadcasts later.
        IPositionManager(infra.univ4PositionManager).modifyLiquidities{value: ethPerPool}(
            abi.encode(actions, params), block.timestamp + 1 hours
        );
    }

    /// @dev `sqrt(price) * 2^96` with the price as a WAD (both sides 18 decimals).
    function _sqrtPriceX96(uint256 tokensPerEth) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(tokensPerEth, 1 << 192, 1e18)));
    }

    /// @dev Inverse of `_sqrtPriceX96`, for the log.
    function _perEth(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return Math.mulDiv(uint256(sqrtPriceX96) * sqrtPriceX96, 1e18, 1 << 192);
    }

    /// @dev See `DeployDummyXStocks._broadcaster`: with `--account`, `msg.sender` is not the sender.
    function _broadcaster() internal returns (address broadcaster) {
        VmSafe.CallerMode mode;
        (mode, broadcaster,) = vm.readCallers();
        require(
            mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast,
            "must be called inside a broadcast"
        );
    }
}

