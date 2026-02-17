# Deployment guidelines

- foundry.toml: optimization runs : 200 or more
- update any addresses in Deployments script

# Deployments

### 1. Deploy the hook with create2 and the found salt (if not already deployed):

```bash
forge script DeployHook --rpc-url sepolia --verify --account livo.dev --broadcast
```

### 2. Update the hook address in deployments.md and in the `DeploymentAddresses`

### 3. Deploy the remaining contracts. The `--slow` flag is to wait for transactions to succeed before broadcasting more.

```bash
forge script Deployments --rpc-url sepolia --verify --account livo.dev --slow --broadcast
```

If it fails with "UNIV4_POOL_MANAGER address. Wrong chain id", update the import in `LivoTaxableTokenUniV4.sol`.

### 4. Put back `LivoTaxableTokenUniV4.sol` imports to mainnet if run with sepolia (only after verification)

### 5. Update addresses in justfile (only for sepolia)

### 6. Update addresses in envio

### 7. Verify any contract of which verification failed

Note that you can take the constructor args already encoded from the transaction logs of the deployment script.

```bash
forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
```

# Transfer ownerships ?

- livo launchpad owner -> multisig ?
- graduator v4 ownership can be kept as mine, since I can only claim on behalf of users for ease of use

---

# Operation

## 1. Graduation fees

Sent directly to the treasury in graduation transactions

## 2. Collect trading fees from launchpad

Any address can collect, but they go automatically to the treasury:

```bash
cast send {{LAUNCHPAD}} "collectTreasuryFees()" --rpc-url $SEPOLIA_RPC_URL --account livo.dev
```

## 3. Collect LP fees from uniswap v4

Any address can collect, but they go automatically to the treasury:

```bash
cast send {{GRADUATORV4}} "sweep()" --rpc-url $SEPOLIA_RPC_URL --account livo.dev
```

## Whitelisting new components etc

...
