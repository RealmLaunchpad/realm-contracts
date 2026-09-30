// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {VmSafe} from "lib/forge-std/src/Vm.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {DummyXStock} from "script/DeployDummyXStocks.s.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";

/// @notice Deploys one dummy token on Robinhood testnet whose ONLY pool is a Uniswap V4 one against the
///         dummy USDG, so a dividend payout asset with no native pair can be exercised: its route is
///         the two-hop native -> USDG -> token, the shape mainnet's Arcus pTokens have.
/// @dev Full-range liquidity, position NFT to the broadcaster, who must hold the dummy USDG (the
///      `DeployDummyXStocks` deployer does). The route is only PRINTED: pass it at token creation, or
///      set it for every token with `DIVIDEND_SWAP_REGISTRY.setRoute(ALL_TOKENS, token, route)`.
///      The asset cannot be listed as a quote: the testnet whitelist has no reference asset.
///
/// Usage (dry run):  forge script DeployDummyUsdgPair --rpc-url rh-testnet --account realm.dev
/// Usage (deploy):   just deploy-dummy-usdg-pair-rh-testnet
///
/// Env (all optional):
///   TOKEN_NAME / TOKEN_SYMBOL  default "Dummy HOOD 3x Long" / "pHOOD3x".
///   TOKENS_PER_USDG            opening price, 18 decimals. Default 1e18.
///   USDG_PER_POOL              dummy USDG seeded, in wei. Default 5000e18 (~2 ETH of depth).
contract DeployDummyUsdgPair is Script {
    /// @dev The dummy USDG (18 decimals) and its native pool's shape, from `listings.robinhood.testnet.json`.
    address internal constant USDG = 0xd2397Fd59C825e6F34037fF2f2F541b0B727Eb24;
    uint24 internal constant USDG_NATIVE_FEE = 500;
    int24 internal constant USDG_NATIVE_TICK_SPACING = 10;

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev Widest range the spacing allows.
    int24 internal constant TICK_LOWER = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
    int24 internal constant TICK_UPPER = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;

    function run() external {
        require(ChainConfig.isRobinhoodTestnet(), "Robinhood testnet only");
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("pHOOD3x"));

        vm.startBroadcast();
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast, "no broadcast");

        address token =
            address(new DummyXStock(vm.envOr("TOKEN_NAME", string("Dummy HOOD 3x Long")), symbol, deployer, SUPPLY));
        uint128 liquidity = _seedPool(token, deployer);
        vm.stopBroadcast();

        Hop[] memory hops = new Hop[](2);
        hops[0] = Hop({currency: USDG, fee: USDG_NATIVE_FEE, tickSpacing: USDG_NATIVE_TICK_SPACING, hooks: address(0)});
        hops[1] = Hop({currency: token, fee: FEE, tickSpacing: TICK_SPACING, hooks: address(0)});

        console.log("%s: %s", symbol, token);
        console.log("   USDG pool liquidity %d, fee %d, tick spacing %d", liquidity, FEE, uint24(TICK_SPACING));
        console.log("   route native -> USDG -> %s:", symbol);
        console.logBytes(DividendRouteLib.encodeV4(hops));
    }

    /// @dev Initializes the (USDG, token) pool and mints one full-range position to `deployer`.
    function _seedPool(address token, address deployer) internal returns (uint128 liquidity) {
        uint256 tokensPerUsdg = vm.envOr("TOKENS_PER_USDG", uint256(1e18));
        ChainConfig.Infra memory infra = ChainConfig.infra();

        // A PoolKey's currencies are address-ordered, and the price is currency1 per currency0.
        bool usdgFirst = USDG < token;
        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(usdgFirst ? USDG : token),
            currency1: Currency.wrap(usdgFirst ? token : USDG),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        uint160 sqrtPriceX96 =
            uint160(Math.sqrt(Math.mulDiv(usdgFirst ? tokensPerUsdg : 1e36 / tokensPerUsdg, 1 << 192, 1e18)));
        IPoolManager(infra.univ4PoolManager).initialize(pool, sqrtPriceX96);

        _approve(USDG, infra);
        _approve(token, infra);

        // USDG is the binding side: the token budget is the whole supply.
        uint256 max0 = vm.envOr("USDG_PER_POOL", uint256(5000e18));
        uint256 max1 = SUPPLY;
        if (!usdgFirst) (max0, max1) = (max1, max0);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), max0, max1
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(pool, TICK_LOWER, TICK_UPPER, liquidity, max0, max1, deployer, "");
        params[1] = abi.encode(pool.currency0, pool.currency1);
        // Deadline an hour out: a script encodes it at simulation and broadcasts later.
        IPositionManager(infra.univ4PositionManager)
            .modifyLiquidities(
                abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
                block.timestamp + 1 hours
            );
    }

    function _approve(address token, ChainConfig.Infra memory infra) internal {
        IERC20(token).approve(infra.permit2, type(uint256).max);
        IAllowanceTransfer(infra.permit2)
            .approve(token, infra.univ4PositionManager, type(uint160).max, type(uint48).max);
    }
}
