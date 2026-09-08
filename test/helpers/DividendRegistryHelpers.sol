// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
// Swapped per target chain by `just chain-<name>`, together with the token implementations that bake
// the same constant in.
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// Default quote-side depth an asset's pair must hold to be eligible.
// Sized off the freeze cap rather than picked: at 10x, the largest swap a token will ever send
// through the pool is ~10% of its quote side. Lower would admit pools where a single freeze is most of
// the liquidity; higher would exclude perfectly usable long-tail assets for no safety gain, since the
// keeper's `minOut` is what protects each individual swap. The value a real deployment initializes the
// registry proxy with, so tests share it rather than pick one.
/// @dev OpenZeppelin v5 `Initializable`'s ERC-7201 slot (`openzeppelin.storage.Initializable`).
bytes32 constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

uint256 constant DEFAULT_DIVIDEND_POOL_LIQUIDITY = 10 * DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

/// @notice Puts a working `RealmDividendSwapRegistry` at the address the token implementations bake in.
/// @dev Token implementations reach the registry through a compile-time constant, so a test cannot
///      simply deploy one and pass the address — it has to appear AT that address. `etch` copies runtime
///      code only, leaving the storage at that address empty, which is why `initialize` runs here rather
///      than being inherited from the contract this code came from (whose constructor disabled it).
/// @dev The etched copy is the implementation itself, not a proxy. Tests exercise the registry's
///      behaviour, not its upgradeability, and a proxy would only add a hop to every call.
function installDividendSwapRegistry(address owner) returns (RealmDividendSwapRegistry registry) {
    address at = DeploymentAddresses.DIVIDEND_SWAP_REGISTRY;
    RealmDividendSwapRegistry deployed = new RealmDividendSwapRegistry();
    VM.etch(at, address(deployed).code);
    VM.label(at, "DividendSwapRegistry");

    registry = RealmDividendSwapRegistry(at);
    // On a chain where the registry proxy is already live (Robinhood), the address carries the proxy's
    // storage, initialized flag included; clear it so the fresh copy can be initialized like the rest.
    VM.store(at, INITIALIZABLE_STORAGE, bytes32(0));
    registry.initialize(owner, DEFAULT_DIVIDEND_POOL_LIQUIDITY);
}
