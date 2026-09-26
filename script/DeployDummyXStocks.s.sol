// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "lib/forge-std/src/Script.sol";
import {console} from "lib/forge-std/src/console.sol";
import {VmSafe} from "lib/forge-std/src/Vm.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
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
import {DeploymentAddressesRobinhoodTestnet as RobinhoodTestnet} from "src/config/DeploymentAddresses.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {Hop, SwapRejection} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";

/// @notice Stand-in for a Robinhood xStock: a plain 18-decimal ERC20, whole supply to the deployer.
/// @dev The real xStocks are 18-decimal ERC20s with no hooks of their own, so a stock ERC20 is a
///      faithful replica. No faucet and no mint: whatever the pool does not take stays with the
///      deployer to hand out.
contract DummyXStock is ERC20 {
    constructor(string memory name_, string memory symbol_, address holder, uint256 supply) ERC20(name_, symbol_) {
        _mint(holder, supply);
    }
}

/// @notice Deploys a handful of dummy xStocks on a testnet, each with a Uniswap V4 pool against native
///         ETH, so the dividend feature can be exercised where the real payout assets cannot be.
///
/// @dev WHY THIS EXISTS. Third-asset dividends are built for Robinhood Chain's xStocks, and NEITHER
///      testnet has a usable one. Sepolia has no xStocks at all. Robinhood testnet does — five official
///      ones (TSLA, AMZN, PLTR, NFLX, AMD) from Robinhood's `StockFactory` — but they cannot be bought:
///      there is no V2 pair, nothing in the V4 pool manager, and the only real depth sits on a
///      third-party V3 DEX quoted in USDC and in a non-canonical WETH, so no native-ETH route to them
///      exists. A payout asset that cannot be swapped for is not a payout asset. This puts the ASSET
///      SIDE of the setup on both chains instead: tokens that look like xStocks, in pools shaped like
///      the real ones, routable by the same registry.
///
/// @dev THE POOLS MIRROR THE LIVE ROBINHOOD ONES. Symbols, fee tier, tick spacing and the initial price
///      were read off the Robinhood mainnet pool manager (`AAPL` at fee 50000 / spacing 1000 / ~7.6
///      AAPL per ETH, and so on), so a route written here has the same shape as the one production
///      writes. Prices are frozen at the moment of that read; they are set dressing, not an oracle.
///
/// @dev LIQUIDITY IS FULL-RANGE, which is the one deliberate departure. It is capital-inefficient — a
///      swap of `x` ETH against a pool seeded with `e` ETH moves the price by roughly `(1 + x/e)^2` — but
///      it can never fall out of range, whatever the price does afterwards. The default is sized off the
///      conversions the pool has to absorb rather than off what a pool costs: both testnets' dividend
///      buffers convert between `DIVIDEND_THRESHOLD` (0.001 ETH) and `MAX_EARNINGS_PER_PROCESS` (1
///      ETH) at a time, so 2 ETH keeps an ordinary conversion well under one percent impact, while a
///      max-size one moves the price ~2.25x. Raise `ETH_PER_POOL` further if the max-size case needs to price
///      realistically.
///
/// @dev The position NFT goes to the BROADCASTER, not to a locked contract like graduation does, so the
///      testnet ETH can be pulled back out when the experiment is over.
///
/// @dev Routes are only VALIDATED here, against the chain's `DIVIDEND_SWAP_REGISTRY` when it is
///      deployed; nothing is written on-chain either way (see `_reportRoute`). A chain whose registry
///      constant is still a placeholder prints the routes unvalidated.
///
/// @dev DEPLOYED SO FAR. The consumer of these is the frontend's payout catalogue
///      (`dividendAssets.<chain>.mjs`), which carries the matching route bytes; they are recorded here
///      too so the set can be found without digging through broadcast logs.
///      Robinhood testnet: AAPL 0xaB04eC65d7F7cc9A83a5a9b7f498f952B4f848d3, TSLA 0x656B6560b6ADa6bB12a15931a6a0F8bd6370414B,
///                         AMZN 0xe0B058D16920bC542BBc83A3dCF5c7aFcA541464, GOOGL 0x089a31AF9EC4f18ecDD2404313a679F5f9d01A5B,
///                         META 0xd4Ad8bf17341758b3466C7c7429A1c50c7100d43, NVDA 0xd2Bc8D4d0d0E50F201b26176daa7c24592c98E99
///                         (deployed 2026-09-21, 2 ETH per pool. Supersedes an AAPL/GOOGL/MSFT set at
///                         0x1a86eAa7…, 0x08054EBb… and 0x0a4d26B9…, plus a same-day redeploy of it at
///                         0x4b8B412f…, 0xE456E445… and 0x3b80B1a4… — all six are abandoned, their pool
///                         NFTs still held by the deployer.)
///
///      USDG (dummy stablecoin, 18 decimals unlike the real one's 6): see `just deploy-dummy-xstocks-rh-testnet`.
///
/// Usage (dry run):  forge script DeployDummyXStocks --rpc-url rh-testnet --account realm.dev
/// Usage (deploy):   just deploy-dummy-xstocks-rh-testnet
///
/// Env:
///   ETH_PER_POOL   (optional) native seeded into each pool, in wei. Default 2 ETH.
contract DeployDummyXStocks is Script {
    /// @notice One dummy stock: its identity, its pool's shape, and the price the pool opens at.
    /// @param tokensPerEth 18-decimal price as `currency1 per currency0` — how many of the stock one ETH
    ///        buys, which is exactly what a V4 `sqrtPriceX96` encodes for a `(native, token)` pool.
    struct XStock {
        string name;
        string symbol;
        uint256 tokensPerEth;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @notice Supply minted to the deployer. Only a fraction ever reaches the pool; the rest is there to
    ///         hand to test wallets.
    uint256 internal constant SUPPLY = 1_000_000e18;

    uint256 internal constant DEFAULT_ETH_PER_POOL = 2 ether;

    function run() external {
        require(ChainConfig.isRobinhoodTestnet(), "Robinhood testnet only");
        uint256 ethPerPool = vm.envOr("ETH_PER_POOL", DEFAULT_ETH_PER_POOL);
        XStock[] memory stocks = _stocks();

        console.log("=== Deploy dummy xStocks (%s) ===", ChainConfig.name());
        console.log("Stocks:       %d", stocks.length);
        console.log("ETH per pool: %d wei", ethPerPool);

        RealmDividendSwapRegistry registry = RealmDividendSwapRegistry(payable(_registry()));
        address poolManager = ChainConfig.infra().univ4PoolManager;

        vm.startBroadcast();
        address deployer = _broadcaster();
        console.log("Deployer:     %s", deployer);
        bool haveRegistry = address(registry).code.length != 0;

        for (uint256 i; i < stocks.length; ++i) {
            address token = address(new DummyXStock(stocks[i].name, stocks[i].symbol, deployer, SUPPLY));

            PoolKey memory pool = PoolKey({
                currency0: Currency.wrap(address(0)), // native ETH sorts below every ERC20
                currency1: Currency.wrap(token),
                fee: stocks[i].fee,
                tickSpacing: stocks[i].tickSpacing,
                hooks: IHooks(address(0))
            });
            uint160 sqrtPriceX96 = _sqrtPriceX96(stocks[i].tokensPerEth);
            IPoolManager(poolManager).initialize(pool, sqrtPriceX96);
            uint128 liquidity = _seedLiquidity(pool, sqrtPriceX96, ethPerPool, deployer);

            console.log("%s: %s", stocks[i].symbol, token);
            console.log("   pool liquidity %d, fee %d", liquidity, stocks[i].fee);

            _reportRoute(registry, haveRegistry, token, stocks[i]);
        }
        vm.stopBroadcast();

        if (!haveRegistry) {
            console.log("");
            console.log("Registry %s is not deployed here, so the routes above", address(registry));
            console.log("could not be validated. They are still correct by construction: one hop,");
            console.log("currency = the token, fee and tickSpacing as printed, hooks = 0.");
        }
    }

    /// @notice The assets to deploy. Each run deploys EVERY entry, so the list holds only what is new.
    /// @dev The six xStocks listed in the contract docs were deployed from an earlier version of this list
    ///      (AAPL 7.621e18 / 50000 / 1000, TSLA 6.7662e18, AMZN 9.5949e18, GOOGL 7.3333e18 / 10000 / 200,
    ///      META 2.6435e18, NVDA 10.916e18). Fee/tick spacing must be one of the shapes
    ///      `discover_whitelist_assets.py` probes, or the pool can never be listed.
    function _stocks() internal pure returns (XStock[] memory stocks) {
        stocks = new XStock[](1);
        stocks[0] = XStock("USD Glitter", "USDG", 2700e18, 500, 10); // ~2700 USD per ETH
    }

    /// @dev The chain's `RealmDividendSwapRegistry` proxy.
    function _registry() internal pure returns (address) {
        return RobinhoodTestnet.DIVIDEND_SWAP_REGISTRY;
    }

    /// @dev `sqrt(price) * 2^96` with the price given as a WAD. `mulDiv` carries the 512-bit intermediate,
    ///      so the shift cannot overflow the way `tokensPerEth * 2**192` would.
    function _sqrtPriceX96(uint256 tokensPerEth) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(tokensPerEth, 1 << 192, 1e18)));
    }

    /// @notice Mints one full-range position, spending `ethIn` and whatever tokens that implies.
    /// @dev ETH is the binding side: the token budget passed in is the whole supply, so
    ///      `getLiquidityForAmounts` sizes the position off the native amount and the mint pulls only the
    ///      tokens that match. Leftover native is swept back rather than left in the position manager.
    function _seedLiquidity(PoolKey memory pool, uint160 sqrtPriceX96, uint256 ethIn, address deployer)
        internal
        returns (uint128 liquidity)
    {
        address token = Currency.unwrap(pool.currency1);
        ChainConfig.Infra memory infra = ChainConfig.infra();
        ERC20(token).approve(infra.permit2, type(uint256).max);
        IAllowanceTransfer(infra.permit2)
            .approve(token, infra.univ4PositionManager, type(uint160).max, type(uint48).max);

        // Widest range the spacing allows. Truncation toward zero keeps both ticks inside the usable band.
        int24 tickLower = (TickMath.MIN_TICK / pool.tickSpacing) * pool.tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / pool.tickSpacing) * pool.tickSpacing;

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), ethIn, SUPPLY
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        // NFT to the broadcaster, so the position can be closed and the testnet ETH recovered.
        params[0] = abi.encode(pool, tickLower, tickUpper, liquidity, ethIn, SUPPLY, deployer, "");
        params[1] = abi.encode(pool.currency0, pool.currency1);
        params[2] = abi.encode(pool.currency0, deployer);

        // A deadline an HOUR out, not `block.timestamp`. The graduator can use the latter because it
        // encodes this inside the transaction that executes it; a script encodes it during simulation and
        // broadcasts seconds or minutes later, by which point `block.timestamp` is in the past and the
        // position manager rejects every mint.
        IPositionManager(infra.univ4PositionManager).modifyLiquidities{value: ethIn}(
            abi.encode(actions, params), block.timestamp + 1 hours
        );
    }

    /// @notice Prints the one-hop native -> stock route, in the exact wire format a token creation takes.
    /// @dev NOTHING IS WRITTEN ON-CHAIN HERE ANY MORE. Routes belong to the token that converts through
    ///      them and are registered by that token at ITS creation, so a payout asset has no registry
    ///      state of its own to seed. What this script owes its caller is therefore the bytes: paste
    ///      them into the frontend's payout catalogue next to the address printed above, and a creator
    ///      picking this asset ships the route with it.
    /// @dev The validation is a dry read against the pool just seeded, and it is the point of doing it
    ///      here rather than trusting the encoding: it proves the pool is initialized and holds
    ///      liquidity, which is exactly what `registerRoute` will demand at creation time.
    function _reportRoute(RealmDividendSwapRegistry registry, bool haveRegistry, address token, XStock memory stock)
        internal
        view
    {
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({currency: token, fee: stock.fee, tickSpacing: stock.tickSpacing, hooks: address(0)});
        bytes memory route = DividendRouteLib.encodeV4(hops);
        console.logBytes(route);

        if (!haveRegistry) return;
        SwapRejection rejection = registry.validateRoute(token, route);
        if (rejection == SwapRejection.OK) console.log("   route valid");
        else console.log("   route REJECTED (rejection %d)", uint8(rejection));
    }

    /// @dev The account forge will actually send from. NOT `msg.sender`: with `--account <keystore>` the
    ///      script frame still reports forge's default sender while the transactions execute as the
    ///      keystore address, so a token minted to `msg.sender` lands on an account that cannot then
    ///      fund the liquidity position. `readCallers` reports the real one, and only inside a broadcast.
    function _broadcaster() internal returns (address broadcaster) {
        VmSafe.CallerMode mode;
        (mode, broadcaster,) = vm.readCallers();
        require(
            mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast,
            "must be called inside a broadcast"
        );
    }
}
