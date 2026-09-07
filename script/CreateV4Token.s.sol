// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @title Create a plain (non-tax) V4 token through an arbitrary whitelisted factory
/// @notice Throwaway/reusable script for creating a token through a freshly-deployed,
///         not-yet-manifested V4 factory (e.g. a parallel factory from `DeploymentsUnifiedFactories`
///         wired to a new graduator/hook) — the factory is NOT read from the manifest, since a
///         scratch factory deliberately isn't tracked there. The token itself is an ordinary V4
///         token; only the factory it's created through differs. Mines the required
///         `0x1110`-suffixed salt off-chain, then calls the tiered `createToken` overload with the
///         selected liquidity tier (THIN by default), empty tax/anti-sniper config, no creator vaults
///         and no deployer buy.
///
///         The factory namespaces the CREATE2 salt by `msg.sender`, so the mined salt is only valid for
///         the account that actually broadcasts. That account is read back from `vm.readCallers()` inside
///         the broadcast rather than from the script frame's `msg.sender` — outside a broadcast the latter
///         is forge's `DEFAULT_SENDER` (`0x1804c8AB...`), NOT the `--account` being used, so mining
///         against it silently produces a salt for the wrong namespace and the on-chain `0x1110` check
///         reverts with `InvalidTokenAddress()`.
///
///         Env vars:
///         - `FACTORY_ADDRESS` (required)        the V4 factory proxy to create the token through
///         - `TOKEN_NAME`      (default: "FooHook TestV4Token")
///         - `TOKEN_SYMBOL`    (default: "FooHook")
///         - `FEE_RECEIVER`    (default: the broadcaster) gets 100% of the token's fee shares
///         - `SALT_START`      (default: 0) salt search offset, in case a lower salt was already used
///         - `DEPLOYER`        (default: the broadcaster) escape hatch to override the salt namespace
///         - `LIQUIDITY_TIER`  (default: 0 = THIN) 0 THIN, 1 DEFAULT, 2 THICK
///         - `LP_FEE_BPS`      (default: 100) post-graduation swap fee stored on the token; 100 or 50
///
/// @dev    Run with (same command for sepolia and mainnet — just swap --rpc-url and the env vars):
///         FACTORY_ADDRESS=<factory> forge script CreateV4Token --rpc-url <sepolia|mainnet> \
///             --account livo.dev --slow --broadcast
contract CreateV4Token is Script {
    function run() public {
        address factory = vm.envAddress("FACTORY_ADDRESS");
        require(factory.code.length > 0, "FACTORY_ADDRESS has no code");

        string memory name = vm.envOr("TOKEN_NAME", string("FooHook TestV4Token"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("FooHook"));
        uint256 saltStart = vm.envOr("SALT_START", uint256(0));
        LiquidityTier tier = LiquidityTier(uint8(vm.envOr("LIQUIDITY_TIER", uint256(uint8(LiquidityTier.THIN)))));
        uint16 lpFeeBps = uint16(vm.envOr("LP_FEE_BPS", uint256(100)));

        address tokenImplBase = RealmFactoryUniV4Unified(factory).TOKEN_IMPL_BASE();

        // Open the broadcast BEFORE mining: the salt namespace is the account that sends the tx, which
        // `readCallers` only reports once the broadcast is active. Reading `msg.sender` out here would
        // give forge's DEFAULT_SENDER instead — see the note above.
        vm.startBroadcast();
        (address deployer, address feeReceiver) = _accounts();

        bytes32 salt = _mineSalt(factory, tokenImplBase, deployer, saltStart);
        address predicted = _predictToken(factory, tokenImplBase, deployer, salt);

        console.log("=== Create V4 Token ===");
        console.log("Chain ID:        ", block.chainid);
        console.log("Factory:         ", factory);
        console.log("Token impl base: ", tokenImplBase);
        console.log("Deployer (salt): ", deployer);
        console.log("Fee receiver:    ", feeReceiver);
        console.log("Liquidity tier:  ", uint8(tier)); // 0 THIN, 1 DEFAULT, 2 THICK
        console.log("LP fee (bps):    ", lpFeeBps);
        console.log("Mined salt:      ", vm.toString(salt));
        console.log("Predicted token: ", predicted);
        console.log("");

        IRealmFactory.FeeShare[] memory feeShares = new IRealmFactory.FeeShare[](1);
        feeShares[0] = IRealmFactory.FeeShare({account: feeReceiver, shares: 10_000, directFeesEnabled: false});

        address token = RealmFactoryUniV4Unified(factory)
            .createToken(
                IRealmFactory.TokenSetupTiered({
                    name: name, symbol: symbol, salt: salt, feeShares: feeShares, liquidityTier: tier
                }),
                TaxConfigs({
                    buyTaxBps: 0,
                    sellTaxBps: 0,
                    taxDurationSeconds: 0,
                    startTaxFromLaunch: false,
                    buyTaxDecayStartBps: 0,
                    sellTaxDecayStartBps: 0,
                    taxDecayDuration: 0
                }),
                RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: lpFeeBps}),
                new IRealmFactory.SupplyShare[](0),
                AntiSniperConfigs({
                    maxBuyPerTxBps: 0, maxWalletBps: 0, protectionWindowSeconds: 0, whitelist: new address[](0)
                }),
                new IRealmFactory.CreatorVault[](0)
            );
        vm.stopBroadcast();

        require(token == predicted, "created token != predicted address");

        console.log("=== Token Created ===");
        console.log("Token:", token);
        console.log("");
        console.log("Next: buy through the launchpad until it crosses the graduation threshold.");
    }

    /// @dev The account the CREATE2 salt is namespaced to, and the token's fee receiver. MUST be called
    ///      inside an active broadcast: `readCallers` is what reports the account forge will actually
    ///      send from (`--account`/`--sender`/`--private-key`). Kept in its own frame so `broadcaster`
    ///      doesn't occupy a stack slot in `run()`, which is at the `via_ir`-free limit.
    function _accounts() internal returns (address deployer, address feeReceiver) {
        (VmSafe.CallerMode mode, address broadcaster,) = vm.readCallers();
        require(
            mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast,
            "_accounts must be called inside a broadcast"
        );
        deployer = vm.envOr("DEPLOYER", broadcaster);
        feeReceiver = vm.envOr("FEE_RECEIVER", broadcaster);

        // `--account <keystore>` alone does NOT set the script's sender: forge still reports its
        // DEFAULT_SENDER here, so the salt would be mined for an account that never signs the tx and the
        // factory's `0x1110` check would revert with a bare `InvalidTokenAddress()`. Fail with something
        // actionable instead. Pass `--sender <addr>` alongside `--account` (as the repo's other deploy
        // recipes do), or set `DEPLOYER` explicitly.
        require(
            deployer != DEFAULT_SENDER,
            "salt would be mined for forge's DEFAULT_SENDER: pass --sender <your address> (alongside --account), or set DEPLOYER"
        );
    }

    /// @dev Mirrors `test/launchpad/base.t.sol::_nextValidSalt` — searches for a salt whose
    ///      NAMESPACED clone address ends in `0x1110`, starting from `start` (bump `SALT_START` if a
    ///      lower salt was already consumed against this factory+impl+deployer triple).
    function _mineSalt(address factory, address impl, address deployer, uint256 start)
        internal
        pure
        returns (bytes32 salt)
    {
        for (uint256 i = start;; i++) {
            salt = bytes32(i);
            if (uint16(uint160(_predictToken(factory, impl, deployer, salt))) == 0x1110) return salt;
        }
    }

    /// @dev Mirrors `RealmFactoryAbstract._cloneAndCreateToken`: the factory namespaces the CREATE2 salt
    ///      by `msg.sender`, so the address is a function of `(factory, impl, deployer, salt)`.
    function _predictToken(address factory, address impl, address deployer, bytes32 salt)
        internal
        pure
        returns (address)
    {
        return Clones.predictDeterministicAddress(impl, keccak256(abi.encodePacked(deployer, salt)), factory);
    }
}
