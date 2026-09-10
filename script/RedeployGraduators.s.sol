// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UpgradeRealmFactories} from "script/UpgradeRealmFactories.s.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {RealmGraduatorUniswapV2} from "src/graduators/RealmGraduatorUniswapV2.sol";
import {RealmGraduatorUniswapV4} from "src/graduators/RealmGraduatorUniswapV4.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";

/// @title Redeploy the graduators and rewire the live factories to them
/// @notice For a chain whose stack is already live and whose graduation policy has to change: deploys a
///         fresh `RealmGraduatorUniswapV2` and the three per-tier `RealmGraduatorUniswapV4` (DEFAULT /
///         THIN / THICK) from the current build, then does what `UpgradeRealmFactories` does with them —
///         new factory implementations, both proxies repointed. One run, nothing to paste in between.
///         Same launchpad, hook, liquidity adder and tier prices as `DeployRealmStack`, read from the
///         manifest and `UniswapV4PoolConstants`. Tokens already created keep the graduator their
///         factory held at creation; only tokens created afterwards graduate through the new ones.
///
///         Written for the 70/30 fee split: the creator's graduation compensation is an immutable of
///         every graduator.
///
/// @dev    Run: just redeploy-graduators-<sepolia|robinhood|robinhood-testnet>
///         Dry-run first: the same `forge script` without --broadcast, plus --sender <realm.dev address>
///         so the proxy-owner checks pass in simulation.
contract RedeployGraduators is UpgradeRealmFactories {
    function run() public override {
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);
        require(m.liquidityAdder != address(0), "manifest: UNIV4_LIQUIDITY_ADDER missing");
        ChainConfig.Infra memory infra = ChainConfig.infra();
        address hook = ChainConfig.swapHook();

        console.log("=== Redeploy the graduators ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Old GRADUATOR_UNIV2:       ", m.graduatorV2);
        console.log("Old GRADUATOR_UNIV4:       ", m.graduatorV4);
        console.log("Old GRADUATOR_UNIV4_THIN:  ", m.graduatorV4Thin);
        console.log("Old GRADUATOR_UNIV4_THICK: ", m.graduatorV4Thick);
        console.log("");

        vm.startBroadcast();
        m.graduatorV2 =
            address(new RealmGraduatorUniswapV2(infra.univ2Router, m.launchpad, infra.univ2PairInitCodeHash));
        m.graduatorV4 = _deployGraduatorV4(
            infra, m, hook, UniswapV4PoolConstants.SQRT_PRICEX96_GRADUATION_DEFAULT, UniswapV4PoolConstants.TICK_UPPER
        );
        m.graduatorV4Thin = _deployGraduatorV4(
            infra, m, hook, UniswapV4PoolConstants.SQRT_PRICEX96_GRADUATION_THIN, UniswapV4PoolConstants.TICK_UPPER_THIN
        );
        m.graduatorV4Thick = _deployGraduatorV4(
            infra, m, hook, UniswapV4PoolConstants.SQRT_PRICEX96_GRADUATION_THICK, UniswapV4PoolConstants.TICK_UPPER
        );
        (address v2Impl, address v4Impl) = _upgradeFactories(m);
        vm.stopBroadcast();

        console.log("=== Done. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  GRADUATOR_UNIV2            =", m.graduatorV2);
        console.log("  GRADUATOR_UNIV4            =", m.graduatorV4);
        console.log("  GRADUATOR_UNIV4_THIN       =", m.graduatorV4Thin);
        console.log("  GRADUATOR_UNIV4_THICK      =", m.graduatorV4Thick);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL =", v2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL =", v4Impl);
        console.log("");
        console.log("Then: just export-deployments");
    }

    /// @dev Mirrors `DeployRealmStack._deployGraduatorV4`, fed from the manifest instead of a fresh core.
    function _deployGraduatorV4(
        ChainConfig.Infra memory infra,
        ChainConfig.Manifest memory m,
        address hook,
        uint160 sqrtPriceGraduation,
        int24 tickUpper
    ) internal returns (address) {
        RealmGraduatorUniswapV4 g = new RealmGraduatorUniswapV4(
            m.launchpad,
            infra.univ4PoolManager,
            infra.univ4PositionManager,
            infra.permit2,
            hook,
            sqrtPriceGraduation,
            tickUpper,
            m.liquidityAdder
        );
        require(g.HOOK_ADDRESS() == hook, "graduator hook mismatch");
        return address(g);
    }
}
