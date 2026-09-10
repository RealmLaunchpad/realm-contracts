// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet}.
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IRealmKeepersRegistry} from "src/interfaces/IRealmKeepersRegistry.sol";

/// @title KeeperGated
/// @notice The keeper check the out-of-band earnings conversions share. See `RealmKeepersRegistry` for
///         what the gate is for and, just as importantly, what it is not for.
///
/// @dev A SEPARATE MIXIN rather than a method on the token, because the two contracts that need it do
///      not share a hierarchy where one could live: `processBurn` and `processLiquidity` are compiled
///      into the token, `processDividends` into the `delegatecall` extension, and the extension's own
///      base (`DividendDistribution`) knows nothing about the token. Duplicating three lines in both
///      would let the registry address drift between them, and a drift here is a silent auth hole rather
///      than a compile error.
///
/// @dev NO STATE. That is load-bearing: the extension is `delegatecall`ed with the token's storage, so
///      anything declared here would have to appear at the same slot in both hierarchies. A constant and
///      a function are free of that constraint — and `just check-dividend-layout` is what would catch it
///      if this ever stopped being true.
abstract contract KeeperGated {
    /// @notice The `RealmKeepersRegistry` holding the set of addresses allowed to trigger this token's
    ///         earnings conversions.
    /// @dev ⚠️ PLACEHOLDER — NOT DEPLOYED YET on this chain. The `CeEbEe95` tail is the tell; it is
    ///      deliberately NOT `address(0)` so tests can `etch` a working registry AT this address, the
    ///      same convention `DIVIDEND_SWAP_REGISTRY` uses and for the same reason.
    /// @dev A compile-time constant because tokens are clones and cannot be repointed. Every script that
    ///      deploys a taxable token implementation asserts this has code before broadcasting.
    address public constant REALM_KEEPERS_REGISTRY = DeploymentAddresses.REALM_KEEPERS_REGISTRY;

    /// @notice The caller is not on the keeper allowlist.
    error NotAKeeper();

    /// @dev Reverts unless `msg.sender` is a keeper.
    /// @dev FAILS CLOSED against a registry that is not deployed: a high-level call expecting a return
    ///      value carries an `extcodesize` check, so a codeless address reverts. That is the wanted
    ///      behaviour — an ungated
    ///      conversion is the exact thing this gate exists to prevent, so "no registry" must mean "no
    ///      conversions", never "anyone".
    function _requireKeeper() internal view {
        require(IRealmKeepersRegistry(REALM_KEEPERS_REGISTRY).isKeeper(msg.sender), NotAKeeper());
    }
}
