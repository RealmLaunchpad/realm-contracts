// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// Default quote-side depth an asset's pair must hold to be eligible.
// Sized off the freeze cap rather than picked: at 10x, the largest swap a token will ever send
// through the pool is ~10% of its quote side. Lower would admit pools where a single freeze is most of
// the liquidity; higher would exclude perfectly usable long-tail assets for no safety gain, since the
// keeper's `minOut` is what protects each individual swap. The value a real deployment initializes the
// registry proxy with, so tests share it rather than pick one.
uint256 constant DEFAULT_DIVIDEND_POOL_LIQUIDITY = 10 * DeploymentAddresses.MAX_EARNINGS_PER_PROCESS;

/// @notice Puts a working `LivoDividendSwapRegistry` at the address the token implementations bake in.
/// @dev Token implementations reach the registry through a compile-time constant, so a test cannot
///      simply deploy one and pass the address — it has to appear AT that address. `etch` copies runtime
///      code only, leaving the storage at that address empty, which is why `initialize` runs here rather
///      than being inherited from the contract this code came from (whose constructor disabled it).
/// @dev The etched copy is the implementation itself, not a proxy. Tests exercise the registry's
///      behaviour, not its upgradeability, and a proxy would only add a hop to every call.
function installDividendSwapRegistry(address owner) returns (LivoDividendSwapRegistry registry) {
    LivoDividendSwapRegistry deployed = new LivoDividendSwapRegistry();
    VM.etch(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY, address(deployed).code);
    VM.label(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY, "DividendSwapRegistry");

    registry = LivoDividendSwapRegistry(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY);
    registry.initialize(owner, DEFAULT_DIVIDEND_POOL_LIQUIDITY);
}
