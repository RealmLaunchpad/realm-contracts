# Salt Guide: Predicting Token Addresses

## Overview

The Realm factories deploy tokens using `Clones.cloneDeterministic()` (CREATE2 under the hood). Any unused `salt` is accepted (there is no address-suffix requirement); the frontend/backend only needs to compute the address when it wants to know it before calling `createToken()`.

The launch venues are served by two factories, each exposing ONE `createToken` and one `previewTokenImplementation` taking the exact same arguments:

- `RealmFactoryUniV2Unified`: bonding curve, graduates to Uniswap V2. `salt` lives in `TokenSetupTiered`.
- `RealmFactoryUniV4Direct`: direct V4 launch (no curve, 1-3 pools). `salt` lives in `DirectTokenSetup`.

Each factory holds **two** token implementations, `TOKEN_IMPL_BASE` and `TOKEN_IMPL_TAX`. A token is cloned from `TOKEN_IMPL_TAX` if it configures a tax (static or decaying) **or** an earnings allocation (any non-zero burn / dividends / liquidity bps), and from `TOKEN_IMPL_BASE` otherwise. Anti-sniper is not a dispatch input; both implementations carry it.

**Critical**: resolve the implementation **before** predicting the address. Call `factory.previewTokenImplementation(...)` with the arguments you will pass to `createToken` and use the returned address as `TOKEN_IMPLEMENTATION` below. Preview runs the same anti-sniper and tax validation as creation, so it reverts on a config `createToken` would reject.

## How the Address Is Derived

The factory does not use your `salt` directly: it namespaces it by the caller.

```
effectiveSalt = keccak256(abi.encodePacked(msg.sender, salt))   // 20-byte address ++ 32-byte salt
address       = keccak256(0xff ++ factory ++ effectiveSalt ++ keccak256(initcode))[12:]
```

| Factor | Value | Variable? |
|--------|-------|-----------|
| `factory` | Factory **proxy** address (the factories are UUPS proxies; never use the implementation address) | Fixed per factory |
| `msg.sender` | Account that will send `createToken` | Fixed per deployer |
| `salt` | `bytes32` passed in the token setup struct | User-controlled |
| `initcode` | ERC-1167 minimal proxy bytecode for the dispatched implementation | Fixed per `(factory, implementation)` |

The namespacing is the front-run defense: a salt lifted from a pending `createToken` tx yields a different address for any other sender, so a reserved address is only reachable by the account that chose it. The corollary: **predict with the exact account that will send the tx**. If a relayer or contract forwards the call, that forwarder is `msg.sender`, not the end user.

## The Initcode

The ERC-1167 minimal proxy initcode is 55 bytes, deterministic given the implementation address:

```
0x3d602d80600a3d3981f3363d3d373d3d3d363d73
  <20-byte token implementation address (from previewTokenImplementation)>
0x5af43d82803e903d91602b57fd5bf3
```

This is the bytecode that CREATE2 hashes. It comes directly from [OpenZeppelin's Clones.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/proxy/Clones.sol).

## Recommended Flow

1. Build the `createToken` arguments you want to submit (see [`create-token.md`](create-token.md) for the per-factory argument lists).
2. Call `factory.previewTokenImplementation(...)` with those same arguments; it returns the implementation address.
3. Compute `initcodeHash = keccak256(0x3d…73 ++ <impl> ++ 0x5af4…5bf3)`.
4. Pick a `salt` (e.g. random) and predict the address from `(factory, deployer, initcodeHash, salt)`.
5. Put `salt` in the setup struct and submit `createToken(...)` from `deployer`.

If steps 2 and 5 use the same tax / earnings-allocation inputs and the same sender, the deployed address matches the prediction. Toggling tax or allocation on or off between preview and submit can switch the implementation, so the token deploys at a different address than predicted.

## Implementation (TypeScript with viem)

```typescript
import { concat, encodePacked, getCreate2Address, keccak256, pad, toHex, type Address, type Hex } from "viem";

const PROXY_PREFIX = "0x3d602d80600a3d3981f3363d3d373d3d3d363d73";
const PROXY_SUFFIX = "0x5af43d82803e903d91602b57fd5bf3";

/**
 * Predicts the token address for `salt`.
 * `impl` comes from `previewTokenImplementation`; `deployer` is the account that sends `createToken`.
 */
function predictToken(factory: Address, impl: Address, deployer: Address, salt: Hex): Address {
  const bytecodeHash = keccak256(concat([PROXY_PREFIX, impl, PROXY_SUFFIX]));
  const effectiveSalt = keccak256(encodePacked(["address", "bytes32"], [deployer, salt]));
  return getCreate2Address({ from: factory, salt: effectiveSalt, bytecodeHash });
}
```

## Implementation (TypeScript with ethers v6)

```typescript
import { ethers } from "ethers";

const PROXY_PREFIX = "0x3d602d80600a3d3981f3363d3d373d3d3d363d73";
const PROXY_SUFFIX = "0x5af43d82803e903d91602b57fd5bf3";

function predictToken(factory: string, impl: string, deployer: string, salt: string): string {
  const initcodeHash = ethers.keccak256(ethers.concat([PROXY_PREFIX, impl, PROXY_SUFFIX]));
  const effectiveSalt = ethers.solidityPackedKeccak256(["address", "bytes32"], [deployer, salt]);
  return ethers.getCreate2Address(factory, effectiveSalt, initcodeHash);
}
```

## Important Notes

- **Cache per `(factory, implementation, deployer)`**: the initcode hash depends only on the implementation, but every predicted address is specific to the sender. Re-predict when the wallet changes or when the user toggles tax / earnings allocation on or off.
- **Factory upgrades**: `TOKEN_IMPL_BASE` / `TOKEN_IMPL_TAX` are immutables of the factory implementation, so a factory upgrade can change them. Always resolve the implementation through `previewTokenImplementation` at prediction time, never from a hard-coded address.
- **Salt uniqueness**: a salt can be used once per `(factory, implementation, deployer)`; reusing it makes CREATE2 revert. Use a random salt.
- **Verification before submit**: `Clones.predictDeterministicAddress(impl, effectiveSalt, factory)` returns the same address (pass the namespaced salt, not the raw one). It is a library function, not a factory view, so run it from a script or test rather than as an RPC call.
