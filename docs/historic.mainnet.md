# Historic Mainnet Deployments

Tracks every mainnet address that was ever listed in `deployments.mainnet.md` since the initial mainnet deployment on **2026-04-06**. The current addresses live in `deployments.mainnet.md`; this file preserves the superseded ones so events emitted by retired contracts can still be traced.

Source: commits that modified `deployments.mainnet.md`. To rebuild: `git log -p -- deployments.mainnet.md`.

## Contracts with a single deployment (since 2026-04-06, `bfa0746`)

These have not been redeployed and their current addresses are in `deployments.mainnet.md`: `RealmToken`, `RealmTaxableTokenUniV4`, `ConstantProductBondingCurve`, `RealmLaunchpad`, `RealmFeeHandler`, `LivoSwapHook`, `RealmGraduatorUniswapV4`, `RealmFeeSplitter (impl)`, `RealmFactoryExtendedTax (V4)` (added 2026-04-23).

## Contracts with multiple deployments

### `RealmFactory (V2)`

| Address                                      | Status  | Deployed   | Commit    | Reason                                                    |
| -------------------------------------------- | ------- | ---------- | --------- | --------------------------------------------------------- |
| `0x76f404dDcbc6E3ff466F983121CC2b0D8a63F4cb` | current | 2026-04-24 | `45a196f` | Correct fees structure on V2 factory + graduator pair.    |
| `0x2f5ECd7095B7943b4B331BA037BfFCd70282C1a8` | retired | 2026-04-20 | `fffbaba` | Factory redeploy alongside V4 factories.                  |
| `0x7e221c95eFF6bFA9284E6B7EeE0d48c3c8f0A2B7` | retired | 2026-04-13 | `d96b749` | V2 factory now deploys tokens with ownership renounced.   |
| `0xe6872f6E326100b322bcBFb71C3627c3bEbB5C93` | retired | 2026-04-06 | `bfa0746` | Initial mainnet deploy.                                   |

### `RealmFactory (V4)`

| Address                                      | Status  | Deployed   | Commit    | Reason                  |
| -------------------------------------------- | ------- | ---------- | --------- | ----------------------- |
| `0xfd68Ca33f04f6604Dad8F99F8fB31A354434a2e5` | current | 2026-04-20 | `fffbaba` | New factory contracts.  |
| `0x571CD864b15275Ddd13AC100c3c07B7cb072cEFd` | retired | 2026-04-06 | `bfa0746` | Initial mainnet deploy. |

### `RealmFactoryTaxToken (V4)`

| Address                                      | Status  | Deployed   | Commit    | Reason                  |
| -------------------------------------------- | ------- | ---------- | --------- | ----------------------- |
| `0xa13cd72870f73c76f0E2a9f97600663fA3913Cb6` | current | 2026-04-20 | `fffbaba` | New factory contracts.  |
| `0x43464b991D7D54b38D68Ef20c0737c7b769843d0` | retired | 2026-04-06 | `bfa0746` | Initial mainnet deploy. |

### `RealmGraduatorUniswapV2`

| Address                                      | Status  | Deployed   | Commit    | Reason                                                 |
| -------------------------------------------- | ------- | ---------- | --------- | ------------------------------------------------------ |
| `0xd1B50918Aa2e34b89A89B23C84d2377F1622d0f6` | current | 2026-04-24 | `45a196f` | Correct fees structure on V2 factory + graduator pair. |
| `0x46aF9F05825459d149ed036Bb6461E1FE8fA25D8` | retired | 2026-04-06 | `bfa0746` | Initial mainnet deploy.                                |

## Chronological changelog (newest first)

### 2026-04-24 — `45a196f` — V2 factory + graduator with correct fees structure

- `RealmFactory (V2)`: `0x2f5ECd7095B7943b4B331BA037BfFCd70282C1a8` → `0x76f404dDcbc6E3ff466F983121CC2b0D8a63F4cb`
- `RealmGraduatorUniswapV2`: `0x46aF9F05825459d149ed036Bb6461E1FE8fA25D8` → `0xd1B50918Aa2e34b89A89B23C84d2377F1622d0f6`

### 2026-04-23 — `b05fde9` — custom factory addresses

- `+ RealmFactoryExtendedTax (V4)`: `0xe926Eb8F6ba997E5b45247eCE800c0A27E539e57` (new row)
- `+ Realm Token Deployer` account: `0x566CB296539672bB2419F403d292544E9Abf7815` (new row)

### 2026-04-20 — `fffbaba` — new factory contracts

- `RealmFactory (V2)`: `0x7e221c95eFF6bFA9284E6B7EeE0d48c3c8f0A2B7` → `0x2f5ECd7095B7943b4B331BA037BfFCd70282C1a8`
- `RealmFactory (V4)`: `0x571CD864b15275Ddd13AC100c3c07B7cb072cEFd` → `0xfd68Ca33f04f6604Dad8F99F8fB31A354434a2e5`
- `RealmFactoryTaxToken (V4)`: `0x43464b991D7D54b38D68Ef20c0737c7b769843d0` → `0xa13cd72870f73c76f0E2a9f97600663fA3913Cb6`

### 2026-04-13 — `d96b749` — V2 factory deploys tokens with renounced ownership

- `RealmFactory (V2)`: `0xe6872f6E326100b322bcBFb71C3627c3bEbB5C93` → `0x7e221c95eFF6bFA9284E6B7EeE0d48c3c8f0A2B7`

### 2026-04-06 — `bfa0746` — initial mainnet deployment

All contracts listed in `deployments.mainnet.md` deployed fresh. Supersedes earlier pre-mainnet placeholder addresses (those were never live on mainnet and are intentionally omitted here).
