# Salt Mining Guide: Computing Valid Token Addresses

## Overview

The Realm factories deploy tokens using `Clones.cloneDeterministic()` (CREATE2 under the hood). The factory enforces that every token address must end in `0x1110` (last 2 bytes). The frontend/backend must pre-compute a valid `salt` before calling `createToken()`.

Since the consolidation, the launchpad whitelists **two unified factories** instead of six:

- `RealmFactoryUniV2Unified` — V2 family. Dispatches between four token implementations
  (`TOKEN_IMPL_BASE`, `TOKEN_IMPL_ANTISNIPER`, `TOKEN_IMPL_TAX`, `TOKEN_IMPL_TAX_ANTISNIPER`)
  based on whether `TaxConfigInit` and/or `AntiSniperConfigs` are configured. V2 creation is
  always ownerless and has no `renounceOwnership` argument.
- `RealmFactoryUniV4Unified` — V4 family. Dispatches between four token implementations
  (`TOKEN_IMPL_BASE`, `TOKEN_IMPL_ANTISNIPER`, `TOKEN_IMPL_TAX`, `TOKEN_IMPL_TAX_ANTISNIPER`)
  based on whether `TaxConfigInit` and/or `AntiSniperConfigs` are configured.

**Critical**: pick the right token implementation **before** mining the salt. Each factory exposes a `previewTokenImplementation(...)` view that mirrors the dispatch-relevant `createToken` inputs and returns the implementation address that will be cloned. Always call it first, then use that returned address as `TOKEN_IMPLEMENTATION` in the CREATE2 calculation below.

## How CREATE2 Addresses Work

The deployed address is deterministic, computed as:

```
address = keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:]
```

Three factors control the final address:

| Factor | Value | Variable? |
|--------|-------|-----------|
| `deployer` | Factory contract address | Fixed per factory |
| `salt` | `bytes32` passed to `createToken()` | User-controlled |
| `initcode` | ERC-1167 minimal proxy bytecode (depends on the dispatched token implementation) | Fixed per `(factory, dispatch path)` pair |

Since `deployer` and `initcode` are fixed for a given factory + dispatch path, **the only variable is `salt`**. The dispatch path is determined by the `TaxConfigInit` and `AntiSniperConfigs` you intend to pass to `createToken` — call `previewTokenImplementation(...)` with those exact values to get the implementation address. For tax durations above 365 days, preview runs the same tax validation as creation: it requires a single fee receiver distinct from the deployer (`msg.sender` of the preview call). Preview assumes the renounced-ownership path is taken at creation; if you do not renounce, `createToken` will still revert with `CharityModeOwnerNotRenounced()`.

## The Initcode

The ERC-1167 minimal proxy initcode is 55 bytes, deterministic given the implementation address:

```
0x3d602d80600a3d3981f3363d3d373d3d3d363d73
  <20-byte token implementation address (from previewTokenImplementation)>
0x5af43d82803e903d91602b57fd5bf3
```

This is the bytecode that CREATE2 hashes. It comes directly from [OpenZeppelin's Clones.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/proxy/Clones.sol).

### Recommended flow

1. Build the `createToken` arguments you want to submit:
   - V2: `feeReceivers`, `supplyShares`, `taxCfg`, `antiSniperCfg`.
   - V4: `feeReceivers`, `supplyShares`, `renounceOwnership`, `taxCfg`, `antiSniperCfg`.
2. Call `factory.previewTokenImplementation(feeReceivers, supplyShares, taxCfg, antiSniperCfg)` — returns the implementation address. The V4 `renounceOwnership` flag does not affect dispatch and is not part of preview.
3. Compute `initcode = 0x3d…73 ++ <impl> ++ 0x5af4…5bf3` and `initcodeHash = keccak256(initcode)`.
4. Mine `salt` against `(factory, initcodeHash)` until `last 2 bytes == 0x1110`.
5. Submit `factory.createToken(name, symbol, salt, ...)` with the same arguments.

If steps 2 and 5 use the same dispatch inputs, the deployed address is guaranteed to match the predicted one. If you change `taxCfg` or `antiSniperCfg` between preview and submit, the dispatched implementation may differ and the salt becomes invalid (the call reverts with `InvalidTokenAddress`).

## The Constraint

The unified factories enforce:

```solidity
require(uint16(uint160(token)) == 0x1110, InvalidTokenAddress());
```

This means the last 2 bytes of the token address must be `0x1110`. Statistically, **1 in 65,536 salts** will produce a valid address, so brute-forcing is near-instant.

## Implementation (TypeScript with viem)

```typescript
import { getCreate2Address, keccak256, concat, toHex, pad } from "viem";

// These are fixed per factory deployment — read from your config/env
const FACTORY_ADDRESS = "0x...";
const TOKEN_IMPLEMENTATION = "0x...";

// Compute initcode hash once (constant for a given factory)
const initcode = concat([
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73",
  TOKEN_IMPLEMENTATION as `0x${string}`,
  "0x5af43d82803e903d91602b57fd5bf3",
]);
const INITCODE_HASH = keccak256(initcode);

/**
 * Finds a salt that produces a token address ending in 0x1110.
 * Typically completes in < 100ms (brute-forces ~65k iterations on average).
 */
function findValidSalt(): { salt: `0x${string}`; tokenAddress: string } {
  for (let i = 0n; ; i++) {
    const salt = pad(toHex(i), { size: 32 });

    const addr = getCreate2Address({
      from: FACTORY_ADDRESS as `0x${string}`,
      salt,
      bytecodeHash: INITCODE_HASH,
    });

    if (addr.toLowerCase().endsWith("1110")) {
      return { salt, tokenAddress: addr };
    }
  }
}
```

## Implementation (TypeScript with ethers v6)

```typescript
import { ethers } from "ethers";

const FACTORY_ADDRESS = "0x...";
const TOKEN_IMPLEMENTATION = "0x...";

const initcode = ethers.concat([
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73",
  TOKEN_IMPLEMENTATION,
  "0x5af43d82803e903d91602b57fd5bf3",
]);
const INITCODE_HASH = ethers.keccak256(initcode);

function findValidSalt(): { salt: string; tokenAddress: string } {
  for (let i = 0n; ; i++) {
    const salt = ethers.zeroPadValue(ethers.toBeHex(i), 32);
    const addr = ethers.getCreate2Address(FACTORY_ADDRESS, salt, INITCODE_HASH);

    if (addr.toLowerCase().endsWith("1110")) {
      return { salt, tokenAddress: addr };
    }
  }
}
```

## Important Notes

- **`INITCODE_HASH` is constant** for a given `(factory, dispatch path)` pair — compute it once per dispatch path at startup, not per call. If your UI lets users toggle anti-sniper / tax options, recompute the hash whenever the toggles change.
- **Each unified factory has multiple token implementations**. `RealmFactoryUniV2Unified` and `RealmFactoryUniV4Unified` each have 4 (`TOKEN_IMPL_BASE`, `TOKEN_IMPL_ANTISNIPER`, `TOKEN_IMPL_TAX`, `TOKEN_IMPL_TAX_ANTISNIPER`). The dispatch is fully determined by the `taxCfg` / `antiSniperCfg` you pass — always call `previewTokenImplementation(...)` with the **same dispatch inputs** you intend to submit, and use its return value as `TOKEN_IMPLEMENTATION`.
- **Salt uniqueness**: each salt can only be used once per `(factory, implementation)` pair. If a salt has already been used (token deployed), `create2` will revert. If you need to handle retries, start iterating from a random offset.
- **On-chain verification**: you can call `Clones.predictDeterministicAddress(implementation, salt, factory)` via a static call to double-check your off-chain computation before submitting.
