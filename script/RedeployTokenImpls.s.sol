// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UpgradeRealmFactories} from "script/UpgradeRealmFactories.s.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {BuildTarget} from "script/BuildTarget.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {RealmDividendLogicUniV4} from "src/tokens/RealmDividendLogicUniV4.sol";
import {RealmEarningsLogicUniV4} from "src/tokens/RealmEarningsLogicUniV4.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";

/// @title Redeploy the token masters and rewire the live factories to them
/// @notice For a chain whose stack is already live and whose token implementations have to change:
///         deploys fresh `RealmToken` / `RealmTaxableTokenUniV2` / `RealmTaxableTokenUniV4` clone masters
///         from the current build, then does what `UpgradeRealmFactories` does with them — new factory
///         implementations, both proxies repointed. One run, nothing to paste in between. Tokens already
///         created keep their old master (clones are not upgradeable); only tokens created afterwards
///         get the new one. The plain `RealmToken` master is redeployed too: it carries the shared base
///         (e.g. `burnFrom`), so a base change needs all three.
///
///         Written for the keeper-gate bug: `KeeperGated` was missing from the `just chain-*` retarget,
///         so the masters on Sepolia and Robinhood testnet baked Ethereum's placeholder keepers registry
///         and every `process*` call reverted. `BuildTarget.assertBuiltFor` now refuses to broadcast a
///         build with any per-chain constant on the wrong chain.
///
/// @dev    Run: just redeploy-token-impls-<sepolia|robinhood-testnet>
contract RedeployTokenImpls is UpgradeRealmFactories {
    function run() public override {
        BuildTarget.assertBuiltFor(block.chainid);
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);

        console.log("=== Redeploy the token masters ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("Old TOKEN_IMPL:           ", m.tokenImpl);
        console.log("Old TAXABLE_TOKEN_V2_IMPL:", m.taxTokenV2Impl);
        console.log("Old TAXABLE_TOKEN_V4_IMPL:", m.taxTokenV4Impl);
        console.log("");

        vm.startBroadcast();
        m.tokenImpl = address(new RealmToken());
        m.taxTokenV2Impl = address(new RealmTaxableTokenUniV2());
        // The V4 token's two extensions are deployed HERE and passed in, rather than by the token's own
        // constructor: their creation code counts toward its initcode, and two of them break EIP-3860.
        // Both share the token's storage layout by construction; `just check-dividend-layout` pins it.
        address dividendLogic = address(new RealmDividendLogicUniV4());
        address earningsLogic = address(new RealmEarningsLogicUniV4());
        m.taxTokenV4Impl = address(new RealmTaxableTokenUniV4(dividendLogic, earningsLogic));
        (address v2Impl, address directImpl) = _upgradeFactories(m);
        vm.stopBroadcast();

        console.log("=== Done. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  TOKEN_IMPL                 =", m.tokenImpl);
        console.log("  TAXABLE_TOKEN_V2_IMPL      =", m.taxTokenV2Impl);
        console.log("  TAXABLE_TOKEN_V4_IMPL      =", m.taxTokenV4Impl);
        console.log("  DIVIDEND_LOGIC_V4          =", dividendLogic);
        console.log("  EARNINGS_LOGIC_V4          =", earningsLogic);
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL =", v2Impl);
        console.log("  FACTORY_UNIV4_DIRECT_IMPL  =", directImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }
}
