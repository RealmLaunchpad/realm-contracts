// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "script/ChainConfig.sol";
import {BuildTarget} from "script/BuildTarget.sol";
import {RealmDirectGraduatorUniV4} from "src/graduators/RealmDirectGraduatorUniV4.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @title Deploy the DIRECT-launch venue
/// @notice The second venue: a Realm token that goes straight to a Uniswap V4 pool at a price its
///         creator picks, with no bonding curve and no launchpad in between. Deploys
///         `RealmDirectGraduatorUniV4` and `RealmFactoryUniV4Direct` (implementation + UUPS proxy) and
///         wires them to the infrastructure already on the chain.
///
/// @dev WHAT MUST EXIST FIRST, and why each one:
///      - `SWAP_HOOK` — `RealmHook`, for native-quoted pools. Already live; never redeployed.
///      - `SWAP_HOOK_ANY_PAIR` — `RealmHookAnyPair`, for ERC20-quoted pools. Run
///        `DeployRealmHookAnyPair` (a mined address, like every V4 hook).
///      - `UNIV4_LIQUIDITY_ADDER` — the shared `RealmUniV4LiquidityAdder`. Its constructor gained
///        `permit2` when it learned to settle an ERC20, so an existing one from before that change has
///        to be redeployed and every graduator rewired to it.
///      - `TOKEN_IMPL` / `TAXABLE_TOKEN_V4_IMPL` — the clone masters. The taxable one now takes its two
///        extensions as constructor arguments, so it too is a redeploy (`RedeployTokenImpls`).
///      - `MASTER_FEE_HANDLER` — must be the ERC20-aware handler (per-asset accounting, the token-only
///        `depositFees(token, asset, amount)`, `assetsOf`). An older one would refuse every ERC20-quoted
///        token's fees, and the any-pair hook would silently route all of them to the treasury, so the
///        script refuses to wire one (`DeployRealmStack` deploys the current handler).
///      - `CREATOR_VAULT_FACTORY` — unchanged in shape, reused as it is.
///
/// @dev The graduator names NO factory: a launch is authorised by `initialize`'s caller being the token
///      itself. That is what lets these two be deployed in either order, and what lets a future factory
///      reuse this same graduator.
///
/// @dev This venue has no launchpad, so there is nothing to whitelist afterwards — unlike the curve
///      factories, which `DeployRealmStack` registers with `RealmLaunchpad`.
///
/// Usage (dry run): forge script DeployDirectVenue --rpc-url rh-testnet --account realm.dev \
///                      --sender <realm.dev address>
/// Usage (deploy):  just deploy-direct-venue-rh-testnet
contract DeployDirectVenue is Script {
    function run() public {
        BuildTarget.assertBuiltFor(block.chainid);
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address hook = ChainConfig.swapHook();
        address anyPairHook = ChainConfig.swapHookAnyPair();
        address wrappedNative = ChainConfig.wrappedNative();

        require(m.liquidityAdder != address(0), "manifest: UNIV4_LIQUIDITY_ADDER missing");
        require(m.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        // `assetsOf` shipped with the handler's ERC20 support: its absence means a handler that predates it.
        (bool erc20Aware,) = m.masterFeeHandler.staticcall(abi.encodeWithSignature("assetsOf(address)", address(0)));
        require(erc20Aware, "manifest: MASTER_FEE_HANDLER predates ERC20 fees, redeploy it");
        require(m.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(m.taxTokenV4Impl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
        address creatorVaultFactory = ChainConfig.creatorVaultFactory();

        console.log("=== Deploy the direct-launch venue ===");
        console.log("Chain ID:            ", block.chainid);
        console.log("Deployer:            ", msg.sender);
        console.log("SWAP_HOOK:           ", hook);
        console.log("SWAP_HOOK_ANY_PAIR:  ", anyPairHook);
        console.log("LIQUIDITY_ADDER:     ", m.liquidityAdder);
        console.log("TOKEN_IMPL:          ", m.tokenImpl);
        console.log("TAXABLE_TOKEN_V4_IMPL:", m.taxTokenV4Impl);
        console.log("");

        vm.startBroadcast();

        RealmDirectGraduatorUniV4 graduator =
            new RealmDirectGraduatorUniV4(infra.univ4PoolManager, hook, anyPairHook, m.liquidityAdder);

        address factoryImpl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV4Impl}),
                address(graduator),
                m.masterFeeHandler,
                creatorVaultFactory,
                wrappedNative
            )
        );
        address factoryProxy =
            address(new ERC1967Proxy(factoryImpl, abi.encodeCall(RealmFactoryAbstract.initialize, ())));

        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("GRADUATOR_UNIV4_DIRECT:    %s", address(graduator));
        console.log("FACTORY_UNIV4_DIRECT_IMPL: %s", factoryImpl);
        console.log("FACTORY_UNIV4_DIRECT:      %s", factoryProxy);
        console.log("");
        console.log("Paste the three into src/config/manifest.%s.sol, then:", ChainConfig.name());
        console.log("  just export-deployments");
    }
}
