// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploymentAddresses as TaxV2Build} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {DeploymentAddresses as TaxV2BaseBuild} from "src/tokens/RealmTaxableTokenUniV2Base.sol";
import {DeploymentAddresses as TaxV4Build} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {DeploymentAddresses as BuyBacksBuild} from "src/tokens/RealmUniv4BuyBacks.sol";
import {DeploymentAddresses as DividendBuild} from "src/tokens/DividendDistribution.sol";
import {DeploymentAddresses as KeeperGateBuild} from "src/tokens/KeeperGated.sol";
import {DeploymentAddresses as RegistryBuild} from "src/dividends/RealmDividendSwapRegistry.sol";

/// @title Is this build targeted at the chain we are about to deploy to?
/// @notice The taxable token masters are non-upgradeable and bake per-chain constants into their
///         bytecode, one `DeploymentAddresses` import alias per file, all rewritten by `just chain-<name>`.
///         Getting one wrong is unrecoverable for every clone a factory ever mints, so every file on that
///         list is checked here — one alias each, deliberately not just the token file's: `KeeperGated`
///         was missing from the retarget list once, its placeholder keepers registry shipped to Sepolia
///         and Robinhood testnet, every `process*` call reverted, and a check that only read the token
///         file's alias let it through. Add a line here whenever a file is added to `just _taxtoken`.
library BuildTarget {
    function assertBuiltFor(uint256 chainId) internal view {
        require(TaxV2Build.BLOCKCHAIN_ID == chainId, "RealmTaxableTokenUniV2 built for another chain");
        require(TaxV2BaseBuild.BLOCKCHAIN_ID == chainId, "RealmTaxableTokenUniV2Base built for another chain");
        require(TaxV4Build.BLOCKCHAIN_ID == chainId, "RealmTaxableTokenUniV4 built for another chain");
        require(BuyBacksBuild.BLOCKCHAIN_ID == chainId, "RealmUniv4BuyBacks built for another chain");
        require(DividendBuild.BLOCKCHAIN_ID == chainId, "DividendDistribution built for another chain");
        require(KeeperGateBuild.BLOCKCHAIN_ID == chainId, "KeeperGated built for another chain");
        require(RegistryBuild.BLOCKCHAIN_ID == chainId, "RealmDividendSwapRegistry built for another chain");
        require(
            KeeperGateBuild.REALM_KEEPERS_REGISTRY.code.length != 0,
            "REALM_KEEPERS_REGISTRY has no code: run DeployRealmPrereqs, paste it, rebuild"
        );
        require(
            DividendBuild.DIVIDEND_SWAP_REGISTRY.code.length != 0,
            "DIVIDEND_SWAP_REGISTRY has no code: run DeployRealmPrereqs, paste the PROXY, rebuild"
        );
    }
}
