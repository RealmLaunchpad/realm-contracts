// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {Vm, VmSafe} from "lib/forge-std/src/Vm.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// The whitelist is compiled against `lib/v4-core`, the router interface against the remapped copy.
import {PoolKey as CorePoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {DummyRStock} from "script/DeployDummyRStocks.s.sol";
import {IUniversalRouter, IV4RouterSwaps} from "src/interfaces/IUniswapV4UniversalRouter.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigsWithDirectAllocation} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @notice Testnet fixture mimicking mainnet's hook-priced pools (USDG/ETH, PONS, AI): the pool's fee is
///         dynamic, never stored in slot0, and returned by `beforeSwap` as an override, per direction.
/// @dev Flags BEFORE_INITIALIZE | BEFORE_SWAP only (low bits 0x2080), no return-delta flags.
contract DynamicFeeHook {
    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;

    /// @notice LP fee in pips applied to zeroForOne swaps.
    uint24 public feeZeroForOne = 2700;
    /// @notice LP fee in pips applied to oneForZero swaps.
    uint24 public feeOneForZero = 2970;

    event FeesSet(uint24 zeroForOne, uint24 oneForZero);

    constructor(IPoolManager poolManager, address owner) {
        POOL_MANAGER = poolManager;
        OWNER = owner;
    }

    function setFees(uint24 zeroForOne, uint24 oneForZero) external {
        require(msg.sender == OWNER, "not owner");
        require(zeroForOne <= LPFeeLibrary.MAX_LP_FEE && oneForZero <= LPFeeLibrary.MAX_LP_FEE, "fee too high");
        (feeZeroForOne, feeOneForZero) = (zeroForOne, oneForZero);
        emit FeesSet(zeroForOne, oneForZero);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view returns (bytes4) {
        require(msg.sender == address(POOL_MANAGER), "not pool manager");
        require(key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "fee not dynamic");
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(POOL_MANAGER), "not pool manager");
        uint24 fee = params.zeroForOne ? feeZeroForOne : feeOneForZero;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @notice Robinhood testnet: deploys DYN, a `DynamicFeeHook` mined to 0x2080, the (ETH, DYN) dynamic-fee
///         pool with full-range depth, lists DYN in the assets whitelist as a V4 source, launches a
///         Realm token with an ETH pool and a DYN pool, and swaps the DYN pool once each way, checking
///         the `Swap` event's fee against the hook's.
/// @dev The broadcaster must be a whitelist approver. Fixture for the arbitrage bot.
///
/// Usage (dry run):  forge script DeployDynamicFeePool --rpc-url rh-testnet --sender <deployer>
/// Usage (deploy):   just deploy-dynamic-fee-pool-rh-testnet
///
/// Env (optional): ETH_DEPTH (default 3 ether), DYN_PER_ETH (default 10_000e18).
contract DeployDynamicFeePool is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev The PRE-`eab6fab2` direct venue (whitelist + factory, graduator 0xDB19…), still live and the one the
    ///      arbitrage bot indexes.
    address internal constant ASSETS_WHITELIST = 0x9C777eB8A40Dd70612148Daa39B4a6B1358aa00D;
    address internal constant DIRECT_FACTORY = 0xAB24A7B6b7CA47B64C4EC3BCCDd53FB91b5EBeC2;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
    int24 internal constant TICK_UPPER = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function run() external {
        require(ChainConfig.isRobinhoodTestnet(), "Robinhood testnet only");
        ChainConfig.Infra memory infra = ChainConfig.infra();

        vm.startBroadcast();
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast, "no broadcast");

        address dyn = address(new DummyRStock("Dynamic Fee Dummy", "DYN", deployer, SUPPLY));
        DynamicFeeHook hook = _deployHook(IPoolManager(infra.univ4PoolManager), deployer);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(dyn),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        _seedPool(key, dyn, deployer, infra);

        RealmAssetsWhitelist(ASSETS_WHITELIST)
            .setWhitelisted(
                dyn,
                RealmAssetsWhitelist.PriceSource({
                    venue: RealmAssetsWhitelist.Venue.V4,
                    pool: address(0),
                    key: abi.decode(abi.encode(key), (CorePoolKey))
                })
            );

        address realmToken = _launch(dyn, deployer);

        IAllowanceTransfer(infra.permit2).approve(dyn, infra.univ4UniversalRouter, type(uint160).max, type(uint48).max);
        _swapAndCheck(key, true, 0.01 ether, hook.feeZeroForOne(), infra);
        _swapAndCheck(key, false, 100e18, hook.feeOneForZero(), infra);
        vm.stopBroadcast();

        console.log("DYN:          %s", dyn);
        console.log("hook:         %s", address(hook));
        console.log("Realm token:  %s", realmToken);
        console.log("pool id:");
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _deployHook(IPoolManager poolManager, address owner) internal returns (DynamicFeeHook hook) {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        bytes memory args = abi.encode(poolManager, owner);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(DynamicFeeHook).creationCode, args);
        hook = new DynamicFeeHook{salt: salt}(poolManager, owner);
        require(address(hook) == mined && uint160(mined) & Hooks.ALL_HOOK_MASK == 0x2080, "hook address");
    }

    /// @dev Initializes at `DYN_PER_ETH` and mints one full-range position, ETH-bound, to `deployer`.
    function _seedPool(PoolKey memory key, address dyn, address deployer, ChainConfig.Infra memory infra) internal {
        uint256 ethDepth = vm.envOr("ETH_DEPTH", uint256(3 ether));
        // Price is currency1 (DYN) per currency0 (ETH); both 18 decimals.
        uint160 sqrtPriceX96 =
            uint160(Math.sqrt(Math.mulDiv(vm.envOr("DYN_PER_ETH", uint256(10_000e18)), 1 << 192, 1e18)));
        IPoolManager(infra.univ4PoolManager).initialize(key, sqrtPriceX96);

        IERC20(dyn).approve(infra.permit2, type(uint256).max);
        IAllowanceTransfer(infra.permit2).approve(dyn, infra.univ4PositionManager, type(uint160).max, type(uint48).max);

        uint256 maxDyn = SUPPLY / 2;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            ethDepth,
            maxDyn
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, TICK_LOWER, TICK_UPPER, liquidity, ethDepth, maxDyn, deployer, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, deployer); // refund unused ETH
        IPositionManager(infra.univ4PositionManager).modifyLiquidities{value: ethDepth}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)), params
            ),
            block.timestamp + 1 hours
        );
    }

    /// @dev Non-taxable token, half its supply in an ETH pool and half in a DYN pool, no dev buy.
    function _launch(address dyn, address deployer) internal returns (address) {
        RealmFactoryUniV4Direct factory = RealmFactoryUniV4Direct(DIRECT_FACTORY);
        IRealmFactory.FeeShare[] memory shares = new IRealmFactory.FeeShare[](1);
        shares[0] = IRealmFactory.FeeShare({account: deployer, shares: 10_000, directFeesEnabled: false});
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: "Dyn Arb Test", symbol: "DYNARB", salt: 0, feeShares: shares, renounceOwnership: false, lpFeeBps: 100
        });
        RealmFactoryUniV4Direct.DirectPair[] memory pairs = new RealmFactoryUniV4Direct.DirectPair[](2);
        pairs[0] = RealmFactoryUniV4Direct.DirectPair({quote: address(0), weightBps: 5_000});
        pairs[1] = RealmFactoryUniV4Direct.DirectPair({quote: dyn, weightBps: 5_000});
        TaxConfigsWithDirectAllocation memory noTax;
        AntiSniperConfigs memory noSniper;
        IRealmFactory.CreatorVault[] memory noVaults;
        RealmFactoryUniV4Direct.DevBuy memory noDevBuy;

        address impl = factory.previewTokenImplementation(setup, pairs, noTax, noSniper, noVaults, noDevBuy, address(0));
        // One reused buffer: a fresh `abi.encodePacked` per iteration grows memory quadratically.
        bytes memory buf = abi.encodePacked(deployer, bytes32(0));
        for (uint256 i;; ++i) {
            assembly ("memory-safe") {
                mstore(add(buf, 52), i)
            }
            if (uint16(uint160(Clones.predictDeterministicAddress(impl, keccak256(buf), DIRECT_FACTORY))) == 0xeeaa) {
                setup.salt = bytes32(i);
                break;
            }
        }
        return factory.createToken(setup, pairs, noTax, noSniper, noVaults, noDevBuy, address(0));
    }

    /// @dev Exact-in swap through the universal router; asserts the pool's `Swap` event carries `fee`.
    function _swapAndCheck(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint24 fee,
        ChainConfig.Infra memory infra
    ) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4RouterSwaps.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );

        vm.recordLogs();
        IUniversalRouter(infra.univ4UniversalRouter).execute{value: zeroForOne ? amountIn : 0}(
            abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 id = PoolId.unwrap(key.toId());
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == infra.univ4PoolManager && logs[i].topics[0] == SWAP_TOPIC && logs[i].topics[1] == id)
            {
                (,,,,, uint24 swapFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                require(swapFee == fee, "Swap fee != hook fee");
                console.log("swap zeroForOne=%s fee=%d", zeroForOne, swapFee);
                return;
            }
        }
        revert("no Swap event");
    }
}
