// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UpgradeRealmFactories} from "script/UpgradeRealmFactories.s.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {BuildTarget} from "script/BuildTarget.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";

/// @title Redeploy the taxable token masters and rewire the live factories to them
/// @notice For a chain whose stack is already live and whose taxable token implementation has to
///         change: deploys fresh `RealmTaxableTokenUniV2` / `RealmTaxableTokenUniV4` clone masters from
///         the current build, then does what `UpgradeRealmFactories` does with them — new factory
///         implementations, both proxies repointed. One run, nothing to paste in between. Tokens already
///         created keep their old master (clones are not upgradeable); only tokens created afterwards
///         get the new one. The plain `RealmToken` master bakes no per-chain constant and is left alone.
///
///         Written for the keeper-gate bug: `KeeperGated` was missing from the `just chain-*` retarget,
///         so the masters on Sepolia and Robinhood testnet baked Ethereum's placeholder keepers registry
///         and every `process*` call reverted. `BuildTarget.assertBuiltFor` now refuses to broadcast a
///         build with any per-chain constant on the wrong chain.
///
/// @dev    Run: just redeploy-tax-impls-<sepolia|robinhood-testnet>
contract RedeployTaxTokenImpls is UpgradeRealmFactories {
    function run() public override {
        BuildTarget.assertBuiltFor(block.chainid);
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);

        console.log("=== Redeploy the taxable token masters ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Old TAXABLE_TOKEN_V2_IMPL:", m.taxTokenV2Impl);
        console.log("Old TAXABLE_TOKEN_V4_IMPL:", m.taxTokenV4Impl);
        console.log("");

        vm.startBroadcast();
        m.taxTokenV2Impl = address(new RealmTaxableTokenUniV2());
        m.taxTokenV4Impl = address(new RealmTaxableTokenUniV4());
        (address v2Impl, address v4Impl) = _upgradeFactories(m);
        vm.stopBroadcast();

        console.log("=== Done. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  TAXABLE_TOKEN_V2_IMPL      =", m.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V4_IMPL      =", m.taxTokenV4Impl);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL =", v2Impl);
        console.log("  FACTORY_UNIV4_UNIFIED_IMPL =", v4Impl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
