// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealmSwapper} from "src/swapper/RealmSwapper.sol";
// Swapped per target chain by `just chain-<name>`, together with the token implementations that bake
// the same constant in.
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev OpenZeppelin v5 `Initializable`'s ERC-7201 slot (`openzeppelin.storage.Initializable`).
bytes32 constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

/// @dev Native depth test payout pools are seeded with: 10x the largest conversion.
uint256 constant DEFAULT_DIVIDEND_POOL_LIQUIDITY = 10 * DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

/// @notice Puts a working `RealmSwapper` at the address the token implementations bake in.
/// @dev Token implementations reach the registry through a compile-time constant, so a test cannot
///      simply deploy one and pass the address — it has to appear AT that address. `etch` copies runtime
///      code only, leaving the storage at that address empty, which is why `initialize` runs here rather
///      than being inherited from the contract this code came from (whose constructor disabled it).
/// @dev The etched copy is the implementation itself, not a proxy. Tests exercise the registry's
///      behaviour, not its upgradeability, and a proxy would only add a hop to every call.
function installRealmSwapper(address owner) returns (RealmSwapper registry) {
    address at = DeploymentAddresses.REALM_SWAPPER;
    RealmSwapper deployed = new RealmSwapper();
    VM.etch(at, address(deployed).code);
    VM.label(at, "RealmSwapper");

    registry = RealmSwapper(payable(at));
    // On a chain where the registry proxy is already live (Robinhood), the address carries the proxy's
    // storage, initialized flag included; clear it so the fresh copy can be initialized like the rest.
    VM.store(at, INITIALIZABLE_STORAGE, bytes32(0));
    registry.initialize(owner);
}

/// @notice Sets `asset`'s route as the registry's owner. `route` empty clears it.
function setDividendRoute(RealmSwapper registry, address asset, bytes memory route) {
    VM.prank(registry.owner());
    registry.setRoute(address(0), asset, route);
}
