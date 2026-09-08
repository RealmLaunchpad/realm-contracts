// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ForkIntegrationCaseLib} from "test/integration/fork/base/ForkIntegrationCaseLib.t.sol";
import {DeploymentAddressesEthereumSepolia} from "src/config/DeploymentAddresses.sol";
import {DeploymentsEthereumSepolia} from "src/config/manifest.ethereum.sepolia.sol";

/// @notice Chain-specific address config for chain-neutral fork integration suites.
/// @dev Sepolia deployed unified factory / master handler addresses can be supplied by env while
///      the manifest catches up:
///      REALM_FACTORY_V2_UNIFIED, REALM_FACTORY_V4_UNIFIED, REALM_MASTER_FEE_HANDLER.
abstract contract ForkIntegrationConfig is Test {
    using ForkIntegrationCaseLib for *;

    function _sepoliaConfig() internal view returns (ForkIntegrationCaseLib.ForkChainConfig memory cfg) {
        cfg = ForkIntegrationCaseLib.ForkChainConfig({
            rpcUrlEnv: "SEPOLIA_RPC_URL",
            chainId: DeploymentsEthereumSepolia.BLOCKCHAIN_ID,
            forkBlock: vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0)),
            launchpad: vm.envOr("REALM_LAUNCHPAD", DeploymentsEthereumSepolia.LAUNCHPAD),
            quoter: vm.envOr("REALM_QUOTER", DeploymentsEthereumSepolia.QUOTER),
            bondingCurve: vm.envOr("REALM_BONDING_CURVE", DeploymentsEthereumSepolia.BONDING_CURVE),
            graduatorV2: vm.envOr("REALM_GRADUATOR_UNIV2", DeploymentsEthereumSepolia.GRADUATOR_UNIV2),
            graduatorV4: vm.envOr("REALM_GRADUATOR_UNIV4", DeploymentsEthereumSepolia.GRADUATOR_UNIV4),
            masterFeeHandler: vm.envOr("REALM_MASTER_FEE_HANDLER", DeploymentsEthereumSepolia.MASTER_FEE_HANDLER),
            factoryV2Unified: vm.envOr("REALM_FACTORY_V2_UNIFIED", DeploymentsEthereumSepolia.FACTORY_UNIV2_UNIFIED),
            factoryV4Unified: vm.envOr("REALM_FACTORY_V4_UNIFIED", DeploymentsEthereumSepolia.FACTORY_UNIV4_UNIFIED),
            tokenImpl: vm.envOr("REALM_TOKEN_IMPL", DeploymentsEthereumSepolia.TOKEN_IMPL),
            taxTokenImpl: vm.envOr("REALM_TAX_TOKEN_IMPL", DeploymentsEthereumSepolia.TAXABLE_TOKEN_V4_IMPL),
            weth: vm.envOr("REALM_WETH", DeploymentAddressesEthereumSepolia.WETH),
            uniV2Router: vm.envOr("REALM_UNIV2_ROUTER", DeploymentAddressesEthereumSepolia.UNIV2_ROUTER),
            uniV2Factory: vm.envOr("REALM_UNIV2_FACTORY", DeploymentAddressesEthereumSepolia.UNIV2_FACTORY),
            uniV2PairInitCodeHash: vm.envOr(
                "REALM_UNIV2_PAIR_INIT_CODE_HASH", DeploymentAddressesEthereumSepolia.UNIV2_PAIR_INIT_CODE_HASH
            ),
            uniV4PoolManager: vm.envOr(
                "REALM_UNIV4_POOL_MANAGER", DeploymentAddressesEthereumSepolia.UNIV4_POOL_MANAGER
            ),
            uniV4PositionManager: vm.envOr(
                "REALM_UNIV4_POSITION_MANAGER", DeploymentAddressesEthereumSepolia.UNIV4_POSITION_MANAGER
            ),
            uniV4UniversalRouter: vm.envOr(
                "REALM_UNIV4_UNIVERSAL_ROUTER", DeploymentAddressesEthereumSepolia.UNIV4_UNIVERSAL_ROUTER
            ),
            permit2: vm.envOr("REALM_PERMIT2", DeploymentAddressesEthereumSepolia.PERMIT2),
            uniV4Hook: vm.envOr("REALM_UNIV4_HOOK", DeploymentsEthereumSepolia.SWAP_HOOK)
        });
    }
}
