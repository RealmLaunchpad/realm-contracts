// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmFactoryAbstract} from "src/factories/RealmFactoryAbstract.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Rewire the factories to whatever the manifest currently says
/// @notice Deploys a fresh implementation for `RealmFactoryUniV2Unified` and `RealmFactoryUniV4Direct`
///         from the CURRENT manifest and points the two live proxies at them. This is the one upgrade
///         path for the factory layer: every dependency a factory holds — launchpad, bonding curves,
///         graduators, master fee handler, token implementations, creator-vault factory, tier config,
///         assets whitelist — is a constructor immutable, so changing any of them means a new
///         implementation and this script.
///
///         Typical use: deploy new token implementations or new graduators with their own one-off
///         script, paste them into `src/config/manifest.<chain>.sol`, run `just export-deployments`,
///         then run this. The proxy addresses never move, so integrators need no changes. To redeploy
///         the direct graduator itself (e.g. after a hook redeploy), use `UpgradeDirectVenue`.
///
///         Deploys nothing but the two implementations, and touches no other contract. The broadcaster
///         must own both proxies.
///
/// @dev    Run: just chain-<sepolia|robinhood> && forge script UpgradeRealmFactories \
///                  --rpc-url <sepolia|rh-mainnet> --account realm.dev --slow --broadcast --verify
contract UpgradeRealmFactories is Script {
    function run() public virtual {
        ChainConfig.Manifest memory m = ChainConfig.manifest();
        _require(m);

        console.log("=== Upgrade the factories ===");
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("");

        vm.startBroadcast();
        (address v2Impl, address directImpl) = _upgradeFactories(m);
        vm.stopBroadcast();

        console.log("=== Upgraded. Paste into src/config/manifest.%s.sol ===", ChainConfig.name());
        console.log("  FACTORY_UNIV2_UNIFIED_IMPL =", v2Impl);
        console.log("  FACTORY_UNIV4_DIRECT_IMPL  =", directImpl);
        console.log("");
        console.log("Then: just export-deployments");
    }

    /// @dev Deploys both factory implementations from `m` and repoints the proxies. Inside a broadcast.
    ///      Takes the manifest as a parameter so a caller can substitute freshly deployed dependencies
    ///      (see `RedeployTokenImpls`) without a paste-and-rerun in between.
    function _upgradeFactories(ChainConfig.Manifest memory m) internal returns (address v2Impl, address directImpl) {
        v2Impl = address(
            new RealmFactoryUniV2Unified(
                m.launchpad,
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV2Impl}),
                m.bondingCurve,
                m.graduatorV2,
                m.masterFeeHandler,
                ChainConfig.creatorVaultFactory(),
                ChainConfig.defaultVaultCurves(),
                ChainConfig.tierCurves()
            )
        );
        directImpl = address(
            new RealmFactoryUniV4Direct(
                IRealmFactory.TokenImpls({base: m.tokenImpl, tax: m.taxTokenV4Impl}),
                m.graduatorV4Direct,
                m.masterFeeHandler,
                ChainConfig.creatorVaultFactory(),
                ChainConfig.wrappedNative(),
                ChainConfig.assetsWhitelist()
            )
        );

        UUPSUpgradeable(m.factoryV2Proxy)
            .upgradeToAndCall(v2Impl, abi.encodeCall(RealmFactoryAbstract.announceGraduator, ()));
        UUPSUpgradeable(m.factoryV4DirectProxy)
            .upgradeToAndCall(directImpl, abi.encodeCall(RealmFactoryAbstract.announceGraduator, ()));
    }

    /// @dev A zero in any of these means the manifest was not refreshed after the last deploy; the
    ///      resulting implementation would be permanently mis-wired, so refuse before broadcasting.
    function _require(ChainConfig.Manifest memory m) internal view {
        require(m.launchpad != address(0), "manifest: LAUNCHPAD missing");
        require(m.bondingCurve != address(0), "manifest: BONDING_CURVE missing");
        require(m.graduatorV2 != address(0), "manifest: GRADUATOR_UNIV2 missing");
        require(m.graduatorV4Direct != address(0), "manifest: GRADUATOR_UNIV4_DIRECT missing");
        require(m.masterFeeHandler != address(0), "manifest: MASTER_FEE_HANDLER missing");
        require(m.tokenImpl != address(0), "manifest: TOKEN_IMPL missing");
        require(m.taxTokenV2Impl != address(0), "manifest: TAXABLE_TOKEN_V2_IMPL missing");
        require(m.taxTokenV4Impl != address(0), "manifest: TAXABLE_TOKEN_V4_IMPL missing");
        require(m.factoryV2Proxy != address(0), "manifest: FACTORY_UNIV2_UNIFIED missing");
        require(m.factoryV4DirectProxy != address(0), "manifest: FACTORY_UNIV4_DIRECT missing");
        _requireCurrentGraduatorV4(m.graduatorV4Direct, "GRADUATOR_UNIV4_DIRECT");
    }

    /// @dev The V4 token impl calls `hookFor` on its graduator and tops liquidity up through the
    ///      graduator's `LIQUIDITY_ADDER` with the ERC20-aware `addOrTopUpSingleSided` (which shipped
    ///      with `PERMIT2`). Wiring either from before that change bricks every clone's burn, liquidity
    ///      and self-token dividend paths for good, so refuse it here.
    function _requireCurrentGraduatorV4(address graduator, string memory slot) internal view {
        require(
            _answers(graduator, abi.encodeWithSignature("hookFor(address)", address(0))),
            string.concat("manifest: ", slot, " predates hookFor, redeploy it")
        );
        (, bytes memory ret) = graduator.staticcall(abi.encodeWithSignature("LIQUIDITY_ADDER()"));
        require(ret.length == 32, string.concat("manifest: ", slot, " has no LIQUIDITY_ADDER"));
        require(
            _answers(abi.decode(ret, (address)), abi.encodeWithSignature("PERMIT2()")),
            string.concat("manifest: ", slot, "'s liquidity adder predates ERC20 settlement, redeploy it")
        );
    }

    /// @dev True when `target` returns a word for `data`. A code-less address "succeeds" with no data,
    ///      so success alone would pass it.
    function _answers(address target, bytes memory data) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        return ok && ret.length >= 32;
    }
}
