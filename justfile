##################### BUILD ################################
build:
    forge build

lint:
    forge lint src/

compile:
    forge fmt
    forge lint src/
    forge build
    just abis

# copies abis from out/ to abis/ for easier access in frontend
abis:
    @mkdir -p abis
    @jq '.abi' out/RealmLaunchpad.sol/RealmLaunchpad.json > abis/RealmLaunchpad.json
    @jq '.abi' out/IRealmQuoter.sol/IRealmQuoter.json > abis/IRealmQuoter.json
    @jq '.abi' out/IRealmLaunchpad.sol/IRealmLaunchpad.json > abis/IRealmLaunchpad.json
    @jq '.abi' out/IRealmToken.sol/IRealmToken.json > abis/IRealmToken.json
    @jq '.abi' out/IRealmClaims.sol/IRealmClaims.json > abis/IRealmClaims.json
    @jq '.abi' out/RealmFactoryUniV2Unified.sol/RealmFactoryUniV2Unified.json > abis/RealmFactoryUniV2Unified.json
    @jq '.abi' out/RealmFactoryUniV4Direct.sol/RealmFactoryUniV4Direct.json > abis/RealmFactoryUniV4Direct.json
    @jq '.abi' out/IRealmTaxableToken.sol/IRealmTaxableToken.json > abis/IRealmTaxableToken.json
    @jq '.abi' out/RealmCreatorVault.sol/RealmCreatorVault.json > abis/RealmCreatorVault.json
    @echo "✔ ABIs copied to abis/ directory"
    

##################### TESTING ################################
# Every suite forks Robinhood mainnet (`_forkInfra()` in test/launchpad/base.t.sol), so the token impls
# must be retargeted there first: they bake the chain's addresses and refuse a mismatched chain id.
# Both runs share the `[profile.robinhood]` build, so the second one does not recompile. Leaves the tree
# on ROBINHOOD MAINNET — run `just chain-rh-testnet` before committing, or the retarget diff rides along.
fast-test: chain-rh
    FOUNDRY_PROFILE=robinhood forge test --no-match-path "test/integration/**"
    just test-rh-fork

# Robinhood-mainnet fork suites (test/integration/fork/robinhood/): a Realm stack deployed on a Robinhood
# fork, trading on Robinhood's Uniswap V4 and paying dividends in real rStocks. Needs ROBINHOOD_RPC_URL
# (archive: the suites pin a block). Retargets the token impls to Robinhood and leaves them there, like
# the deploy recipes do. `fast-test` ends on this recipe.
test-rh-fork: chain-rh
    FOUNDRY_PROFILE=robinhood forge test --match-path "test/integration/fork/robinhood/**"

gas-report:
    forge test --no-match-path "test/integration/**" --gas-report

test-curves:
    forge test --match-contract Curve

integration-tests:
    forge test --match-path "test/integration/**"

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect RealmLaunchpad errors | grep {{errorhex}}

# Deploy recipes do NOT verify: deploy first, then `just verify-rh` / `just verify-rh-testnet` from the SAME
# commit. Verification is on Sourcify (supports 4663 + 46630); the mainnet Blockscout API sits behind a
# Cloudflare bot challenge that rejects forge's verification requests.
robinhood_verify := ""
robinhood_testnet_verify := ""

# Verifies every contract created by the latest broadcast of the given scripts (default: all), read from
# broadcast/<Script>.s.sol/<chainId>/run-latest.json. Read-only on chain; re-runnable (already-verified
# contracts are skipped by Sourcify). Must run on the deploy commit + build target, or bytecode won't match.
# e.g. `just verify-rh DeployRealmPrereqs DeployRealmStack`
verify-rh *scripts: chain-rh
    @just _verify 4663 {{scripts}}

verify-rh-testnet *scripts: chain-rh-testnet
    @just _verify 46630 {{scripts}}

_verify chainid *scripts:
    #!/usr/bin/env bash
    set -uo pipefail
    files=()
    if [ -z "{{scripts}}" ]; then files=(broadcast/*/{{chainid}}/run-latest.json)
    else for s in {{scripts}}; do files+=("broadcast/$s.s.sol/{{chainid}}/run-latest.json"); done; fi
    failed=()
    for f in "${files[@]}"; do
        echo "== $f"
        # top-level CREATE/CREATE2 txs + contracts created inside any tx (e.g. by a factory)
        while read -r name addr; do
            forge verify-contract "$addr" "$name" --chain {{chainid}} --verifier sourcify --watch || failed+=("$name $addr")
        done < <(jq -r '.transactions[] | (select(.transactionType != "CALL") | "\(.contractName) \(.contractAddress)"),
            (.additionalContracts[]? | "\(.contractName) \(.address)")' "$f" | grep -v '^null ')
    done
    if [ ${#failed[@]} -gt 0 ]; then printf 'FAILED: %s\n' "${failed[@]}"; exit 1; fi

# --- Per-chain build retarget ------------------------------------------------
# ONE rule per target chain repoints EVERY per-chain compile-time import across ALL contracts at once
# (the taxable tokens' `DeploymentAddresses`). The rule is per-CHAIN, never per-chain-AND-per-contract:
# add every future per-chain contract swap to `_retarget` so callers keep using a single command. Run the `chain-*` recipe matching your
# target BEFORE `forge build`/deploy. Idempotent. Committed default is Robinhood testnet; the test
# suites fork Robinhood mainnet (`fast-test` retargets with `chain-rh`).
chain-rh:
    @just _retarget DeploymentAddressesRobinhoodMainnet

chain-rh-testnet:
    @just _retarget DeploymentAddressesRobinhoodTestnet

# Fans a target chain out to every per-contract import-swap. Add future per-chain swaps HERE.
_retarget taxlib:
    @just _taxtoken {{taxlib}}

# (internal) Repoints the taxable-token impls' (and their venue bases, the V4 buy-backs, the dividend
# mixin, the keeper gate, the sniper mixin, the `RealmSwapper` and the two test helpers that etch the registries
# at the address those bake in) `DeploymentAddresses` import to the target chain. Use a `chain-*` recipe.
_taxtoken lib:
    sed -i -E 's#DeploymentAddresses[A-Za-z]+ as DeploymentAddresses#{{lib}} as DeploymentAddresses#' \
        src/tokens/RealmTaxableTokenUniV2.sol src/tokens/RealmTaxableTokenUniV4.sol src/tokens/RealmUniv4BuyBacks.sol \
        src/tokens/RealmTaxableTokenUniV2Base.sol src/tokens/RealmTaxableTokenUniV4Base.sol \
        src/tokens/DividendDistribution.sol src/swapper/RealmSwapper.sol src/tokens/KeeperGated.sol \
        src/tokens/SniperProtection.sol \
        test/helpers/RealmSwapperHelpers.sol test/helpers/KeepersRegistryHelpers.sol

# ============================ FRESH DEPLOY (two phases) ============================
# Phase 0. Keepers registry + `RealmSwapper` + LP fee router. Their addresses are COMPILE-TIME
# constants elsewhere, so they must exist before anything else is built. Paste the three printed
# constants (keepers registry, swapper proxy, LP fee router proxy) into src/config/DeploymentAddresses.sol,
# then rebuild. VERIFY FIRST (`just verify-rh DeployRealmPrereqs`): the paste changes the source those
# contracts compiled from, so they no longer verify afterwards. Commit after the paste.

deploy-prereqs-rh: chain-rh
    forge script DeployRealmPrereqs --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-prereqs-rh-testnet: chain-rh-testnet
    forge script DeployRealmPrereqs --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Only the two registries (keepers + dividend swap), owned by realm.dev. Use to redeploy them without
# touching the LP fee router or the hooks (whose Uniswap whitelisting must survive). Paste the two
# printed constants into src/config/DeploymentAddresses.sol, then rebuild.

deploy-registries-rh: chain-rh
    forge script DeployRealmRegistries --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-registries-rh-testnet: chain-rh-testnet
    forge script DeployRealmRegistries --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Phase 1. Everything else in one broadcast: fee handler, launchpad, quoter, liquidity adder, the V2 +
# three V4 graduators, 22 bonding curves, the creator-vault system, the three token impls and both
# unified factories (impl + proxy), then whitelists the factories on the launchpad. Refuses to run
# until phase 0 is pasted and the build is retargeted. Paste the printed manifest block afterwards and
# run `just export-deployments`. Verify (`just verify-rh DeployRealmStack`) before editing any source.

# `--disable-code-size-limit` on every recipe that deploys the taxable tokens: they exceed EIP-170's 24 KB
# (Robinhood allows 96 KB), and forge's pre-broadcast size check is hardcoded to 24 KB, ignoring
# `code_size_limit` in foundry.toml — without the flag it stops at an interactive y/n prompt.
deploy-stack-rh: chain-rh
    forge script DeployRealmStack --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 --disable-code-size-limit {{robinhood_verify}}

deploy-stack-rh-testnet: chain-rh-testnet
    forge script DeployRealmStack --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 --disable-code-size-limit {{robinhood_testnet_verify}}

# Redeploys both unified factory implementations from the CURRENT manifest and repoints the live
# proxies at them. The upgrade path for anything a factory holds as an immutable — token impls,
# graduators, curves, vault factory. Update the manifest FIRST.

upgrade-factories-rh: chain-rh
    forge script UpgradeRealmFactories --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-factories-rh-testnet: chain-rh-testnet
    forge script UpgradeRealmFactories --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new SwapLpFeeRouter implementation (treasury from DeploymentAddresses, split baked in) and
# repoints the manifest's LP_FEE_ROUTER proxy at it. The proxy — and so the hook's whitelisting — never
# moves. Paste the printed LP_FEE_ROUTER_IMPL into the manifest and `just export-deployments`. Dry-run
# first: the same command without --broadcast, plus --sender <realm.dev address>.

upgrade-lp-fee-router-rh: chain-rh
    forge script UpgradeSwapLpFeeRouter --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-lp-fee-router-rh-testnet: chain-rh-testnet
    forge script UpgradeSwapLpFeeRouter --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new RealmCreatorVaultFactory implementation from the current build (same vault impl the
# proxy already clones) and repoints the manifest's CREATOR_VAULT_FACTORY proxy at it. Paste the printed
# CREATOR_VAULT_FACTORY_IMPL into the manifest and `just export-deployments`. Dry-run first: the same
# command without --broadcast, plus --sender <realm.dev address>.

upgrade-vault-factory-rh: chain-rh
    forge script UpgradeCreatorVaultFactory --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-vault-factory-rh-testnet: chain-rh-testnet
    forge script UpgradeCreatorVaultFactory --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys RealmVoting (impl + UUPS proxy) for the manifest's REALM_TOKEN: round 1 opens at deploy, 48-hour
# rounds (override with VOTING_ROUND_DURATION seconds), VOTE_BUYBACK_WALLET appointed admin where the
# chain names one. The token's master must have burnFrom (redeploy-token-impls first if it predates it).
# Prefix REALM_TOKEN=<address> to deploy against a token that is not pasted into the manifest yet.
# ONLY needed to deploy voting apart from the treasury stack — deploy-treasury-stack below deploys it
# in its own broadcast when VOTING is still zero. Paste the printed VOTING / VOTING_IMPL into the
# manifest. Dry-run first: same command without --broadcast, plus --sender <realm.dev address>.

deploy-voting-rh: chain-rh
    forge script DeployRealmVoting --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-voting-rh-testnet: chain-rh-testnet
    forge script DeployRealmVoting --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys the treasury stack (voting + treasury router + LP fee router upgrade) in ONE broadcast: RealmVoting first when the
# manifest has no VOTING yet (the router bakes it in as an immutable), then the router impl + proxy
# (2/3 to the team treasury, 1/3 to voting), then a SwapLpFeeRouter impl pointing at the new proxy,
# upgrades LP_FEE_ROUTER onto it and repoints LAUNCHPAD.treasury(). Needs the manifest's REALM_TOKEN
# (or REALM_TOKEN=<address>) whenever it deploys voting. Broadcaster must own the launchpad and the LP
# router proxy. Paste the printed slots into the manifest, set REALM_TREASURY to the proxy in
# DeploymentAddresses, `just export-deployments`. Dry-run first: same command without --broadcast,
# plus --sender <realm.dev address>.

deploy-treasury-stack-rh: chain-rh
    forge script DeployRealmTreasuryStack --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-treasury-stack-rh-testnet: chain-rh-testnet
    forge script DeployRealmTreasuryStack --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new RealmTreasuryRouter implementation (team treasury, VOTING, keepers registry — all
# implementation immutables) and repoints the live TREASURY_ROUTER proxy at it. The proxy never moves, so
# the launchpad, the LP fee router and the token impls that bake it keep working. Use this after
# redeploying RealmVoting or the keepers registry; DeployRealmTreasuryStack is first-time wiring only.
# Paste the printed TREASURY_ROUTER_IMPL into the manifest and `just export-deployments`. Dry-run first:
# the same command without --broadcast, plus --sender <realm.dev address>.

upgrade-treasury-router-rh: chain-rh
    forge script UpgradeRealmTreasuryRouter --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-treasury-router-rh-testnet: chain-rh-testnet
    forge script UpgradeRealmTreasuryRouter --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new RealmAssetsWhitelist implementation and repoints the live ASSETS_WHITELIST proxy at it.
# Listings, approvers and owner are kept. Paste the printed ASSETS_WHITELIST_IMPL into the manifest and
# `just export-deployments`. Dry-run first: the same command without --broadcast, plus --sender <realm.dev address>.

upgrade-assets-whitelist-rh: chain-rh
    forge script UpgradeAssetsWhitelist --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-assets-whitelist-rh-testnet: chain-rh-testnet
    forge script UpgradeAssetsWhitelist --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new RealmSwapper implementation and repoints this chain's REALM_SWAPPER
# proxy at it. Routes, thresholds and keeper wallet are kept; the proxy address never moves, so nothing to
# paste. Dry-run first: the same command without --broadcast, plus --sender <realm.dev address>.

upgrade-realm-swapper-rh: chain-rh
    forge script UpgradeRealmSwapper --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-realm-swapper-rh-testnet: chain-rh-testnet
    forge script UpgradeRealmSwapper --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys a new RealmVoting implementation for the manifest's CURRENT REALM_TOKEN (the token it burns is
# an implementation immutable) and repoints the live VOTING proxy at it. The proxy never moves, so the
# treasury router that bakes it and the indexer that subscribes to it are untouched. Round state lives in
# proxy storage and survives, so check currentRound() first on a chain where voting has seen real use.
# Paste the printed VOTING_IMPL into the manifest and `just export-deployments`. Dry-run first.

upgrade-voting-rh: chain-rh
    forge script UpgradeRealmVoting --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-voting-rh-testnet: chain-rh-testnet
    forge script UpgradeRealmVoting --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Redeploys the three token masters (base + two taxable) from the current build and rewires the live
# factories to them (new factory impls, proxies repointed) in ONE run — for a master that has to change
# on a chain whose stack is already live. Tokens already created keep the old master. Paste the five printed
# slots into the manifest and `just export-deployments` afterwards. Dry-run first: the same command
# without --broadcast, plus --sender <realm.dev address> so the proxy-owner checks pass in simulation.

redeploy-token-impls-rh-testnet: chain-rh-testnet
    forge script RedeployTokenImpls --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 --disable-code-size-limit {{robinhood_testnet_verify}}

redeploy-token-impls-rh: chain-rh
    forge script RedeployTokenImpls --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 --disable-code-size-limit {{robinhood_verify}}

# Appoints the admin and the keeper on BOTH registries (keepers + dividend swap), which ship empty from
# DeployRealmPrereqs. Admin defaults to the broadcasting account (the registries' owner) — override with
# REALMDEVADDRESS=<addr>; the keeper is REALM_KEEPER in the chain's manifest. Idempotent, so it is also
# how you re-point the registries after rotating REALM_KEEPER. Dry-run first: the same command without
# --broadcast, plus --sender <realm.dev address> so the owner checks pass in simulation.

configure-registries-rh: chain-rh
    forge script ConfigureRegistries --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300

configure-registries-rh-testnet: chain-rh-testnet
    forge script ConfigureRegistries --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Mines a valid hook salt (the permission bits live in the hook's own address) and deploys RealmHook
# against the manifest's LP_FEE_ROUTER — override with ROUTER_ADDRESS=<addr> before the manifest is
# pasted. Run DeployRealmPrereqs first: it deploys the router proxy the hook takes as an immutable.
# Paste the mined address into the manifest's SWAP_HOOK.
#
# RealmHook is the variant Uniswap whitelisted; its base RealmSwapHook was the other candidate and is
# never deployed on its own (see the deprecation note on that contract).

deploy-realm-hook-rh:
    forge script DeployRealmHook --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-realm-hook-rh-testnet:
    forge script DeployRealmHook --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys `RealmKeeperLens`: the stateless, view-only batch reader the dividend keeper drives its
# per-token reads through. No constructor args, nothing on chain points at it, and redeploying it is
# its upgrade path — so unlike the deploy-once scripts this one never refuses to run. Paste the address
# into the chain's manifest as KEEPER_LENS, `just export-deployments`, then repoint the keeper secret.
# No `chain-*` prerequisite, unlike the impl deploys: the lens bakes no DeploymentAddresses constant,
# so its bytecode is identical on every chain and the recipe leaves the tree's build target alone.

deploy-keeper-lens-rh:
    forge script DeployRealmKeeperLens --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

deploy-keeper-lens-rh-testnet:
    forge script DeployRealmKeeperLens --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys the dummy assets `DeployDummyRStocks._stocks()` lists (today: GLD at ~6.85 per ETH), each with a
# native V4 pool seeded with ETH_PER_POOL wei (default 2 ETH). Earlier runs deployed USDG and the six-stock set
# (AAPL, TSLA, AMZN, GOOGL, META, NVDA). E.g. `ETH_PER_POOL=20000000000000000000 just deploy-dummy-rstocks-rh-testnet`.
# That chain DOES carry Robinhood's own official stock
# tokens (TSLA, AMZN, PLTR, NFLX, AMD), but none of them can be bought with native ETH — no V2 pair,
# nothing in the V4 pool manager, and the only depth is a third-party V3 DEX quoted in USDC — so they are
# unusable as dividend payout assets or as quote assets. These dummies stand in, and their tickers match
# the pair artwork the frontend ships, which is why TSLA and AMZN now overlap the official ones.
# AFTER RUNNING THIS: `just discover-whitelist-assets-rh-testnet` then `just whitelist-assets-rh-testnet`.
# No addresses to paste — discovery reads them from this recipe's broadcast log. Dry run:
#   forge script DeployDummyRStocks --rpc-url rh-testnet --account realm.dev
deploy-dummy-rstocks-rh-testnet: chain-rh-testnet
    forge script DeployDummyRStocks --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys ONE dummy token whose only pool is a V4 one against the dummy USDG (no native pair), and prints
# its two-hop dividend route native -> USDG -> token. Env: TOKEN_NAME, TOKEN_SYMBOL, TOKENS_PER_USDG,
# USDG_PER_POOL (default 5000e18). The account must hold the dummy USDG. Dry run:
#   forge script DeployDummyUsdgPair --rpc-url rh-testnet --account realm.dev
deploy-dummy-usdg-pair-rh-testnet: chain-rh-testnet
    forge script DeployDummyUsdgPair --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Arbitrage-bot fixture: DYN + a hook-priced dynamic-fee (ETH, DYN) V4 pool (per-direction fee, owner
# `setFees`), DYN listed as a V4 quote, and a Realm token launched into an ETH pool and a DYN pool.
# Env: ETH_DEPTH (default 3 ether), DYN_PER_ETH (default 10_000e18). The account must be a whitelist approver.
deploy-dynamic-fee-pool-rh-testnet: chain-rh-testnet
    forge script DeployDynamicFeePool --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 --disable-code-size-limit {{robinhood_testnet_verify}}

# Re-pegs the six rh-testnet dummy rStock pools to their whitelisted price and adds ETH_PER_POOL (default
# 20 ETH, 120 total) of full-range liquidity to each. The account must hold the dummy tokens. Dry run:
#   forge script RepegDummyRStocks --rpc-url rh-testnet --account livo.dev
repeg-dummy-rstocks-rh-testnet:
    forge script RepegDummyRStocks --rpc-url rh-testnet --account livo.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# --- DIRECT-LAUNCH VENUE -----------------------------------------------------
# The second venue: a token that goes straight to a Uniswap V4 pool at a price its creator picks, with
# no bonding curve and no launchpad. Two steps, in this order, because the graduator takes the hook as
# an immutable.
#
# Step 1. `RealmHookAnyPair`, the hook every ERC20-quoted pool is bound to. Its address carries its
# permission bits, so the script mines a CREATE2 salt for it (30-60s). `SWAP_HOOK` — the whitelisted
# `RealmHook` — is NOT redeployed and keeps every native-quoted pool. Paste the mined address into the
# manifest's SWAP_HOOK_ANY_PAIR, then rebuild. Dry-run first: the same command without --broadcast,
# plus --sender <realm.dev address>.
deploy-anypair-hook-rh-testnet: chain-rh-testnet
    forge script DeployRealmHookAnyPair --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}


deploy-anypair-hook-rh: chain-rh
    forge script DeployRealmHookAnyPair --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

# Step 2. `RealmDirectGraduatorUniV4` + `RealmFactoryUniV4Direct` (impl + UUPS proxy), wired to the
# hooks, the liquidity adder, the token impls, the fee handler and the creator-vault factory already in
# the manifest. Nothing to whitelist afterwards — this venue has no launchpad. Paste the three printed
# slots into the manifest and `just export-deployments`. Dry-run first.
deploy-direct-venue-rh-testnet: chain-rh-testnet
    forge script DeployDirectVenue --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}


deploy-direct-venue-rh: chain-rh
    forge script DeployDirectVenue --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

# Step 2b. Repoints the LIVE direct venue after redeploying RealmHookAnyPair: a fresh graduator (it bakes
# both hooks) plus a fresh factory implementation, with FACTORY_UNIV4_DIRECT upgraded in place. Reuses the
# existing ASSETS_WHITELIST, so no quote has to be re-listed, and the factory proxy never moves, so the
# frontend and the indexer are untouched. Tokens launched before this keep trading on the OLD hook. Paste
# the two printed slots into the manifest and `just export-deployments`. Dry-run first.

upgrade-direct-venue-rh: chain-rh
    forge script UpgradeDirectVenue --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-direct-venue-rh-testnet: chain-rh-testnet
    forge script UpgradeDirectVenue --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Deploys ONLY a new RealmFactoryUniV4Direct implementation (same graduator, whitelist, token impls from
# the manifest) and upgrades FACTORY_UNIV4_DIRECT in place. For factory code/constant changes. Paste the
# printed FACTORY_UNIV4_DIRECT_IMPL into the manifest and `just export-deployments`. Dry-run first.

upgrade-direct-factory-rh: chain-rh
    forge script UpgradeDirectFactory --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_verify}}

upgrade-direct-factory-rh-testnet: chain-rh-testnet
    forge script UpgradeDirectFactory --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300 {{robinhood_testnet_verify}}

# Regenerates deployments.robinhood.{mainnet,testnet}.md from the matching .sol manifests.
# CI runs the same command and fails if the result is not committed.
export-deployments:
    forge script ExportDeployments

##################### OPERATIONS ####################
# Alert if any reward creator on Robinhood mainnet has pending ETH claims but a 0 ETH wallet.
# Uses the public Robinhood RPC by default.
unfunded-creators:
    uv run script/operations/unfunded-accounts/check_unfunded_creators.py

# Rebuild the Uniswap V4 route CANDIDATES for Robinhood Chain's rStocks by scanning the pool manager
# on-chain, plus the fixed USDG-hop candidate of each Arcus pToken. Writes
# script/operations/dividend-routes/routes.robinhood.mainnet.json.
discover-dividend-routes:
    uv run script/operations/dividend-routes/discover_rstock_routes.py

# Probe those candidates against forked state and keep whichever actually buys the most of each asset,
# writing the winners to catalogue.robinhood.mainnet.json in the wire format a token creation takes.
# BROADCASTS NOTHING and needs no signer: routes belong to the token that converts through them and are
# registered by that token at its own creation. The output feeds the frontend's suggested-asset list, so
# a creator picking a listed asset ships its route and never has to search for pools. Re-running is also
# the catalogue's health check — an asset whose pools have moved reports a different winner, or none.
pick-dividend-routes:
    just chain-rh
    forge script PickDividendRoutes --rpc-url rh-mainnet

# Re-pick, from live state, the Uniswap pool that prices USDG and each of Robinhood's own rStocks, plus
# the fixed USDG pool of each Arcus pToken (the only assets mainnet lists), into
# script/operations/assets-whitelist/listings.robinhood.mainnet.json, and print every one IN or OUT.
# This is the maintenance loop, not a one-off: re-running refreshes every rate, re-picks every pool, and
# switches off what stopped qualifying. The file is a registry: entries are never dropped, only flagged
# `enabled` or not (flip one by hand with the script's --enable / --disable). Review the git diff of that
# file: it is what the script below broadcasts.
discover-whitelist-assets-rh:
    uv run script/operations/assets-whitelist/discover_whitelist_assets.py

# Lists the file's ENABLED entries in RealmAssetsWhitelist as direct-venue quotes, and retires the
# disabled ones the chain still prices (a disabled entry it does not price costs no transaction). The
# proxy comes from the chain's manifest (ASSETS_WHITELIST) and the signer must already be an approver on
# it. Re-run `discover-whitelist-assets-rh` first: the rates are snapshots. The script simulates every entry
# before broadcasting anything and skips the ones a pool no longer supports. The second invocation reads
# the result back off the live chain: a broadcast that never reached it (wrong RPC, stale proxy) fails
# here instead of looking like a success.
whitelist-assets-rh:
    just chain-rh
    forge script WhitelistRobinhoodAssets --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300
    forge script WhitelistRobinhoodAssets --rpc-url rh-mainnet --sig 'verify()'

# The testnet's quote assets: the dummy rStocks `DeployDummyRStocks` seeds native-quoted V4 pools for,
# which is everything on that chain worth quoting a launch in. Nothing there has a market price, so the
# price sanity check does not apply. The pools are probed by key rather than scanned: that RPC caps
# eth_getLogs at 10k blocks.
#
# The addresses are the LAST `deploy-dummy-rstocks-rh-testnet` and `deploy-dummy-usdg-pair-rh-testnet`
# broadcasts PLUS every asset the current listings file still lists, so a run that deploys one new asset
# keeps the older ones. A USDG-only dummy is listed against the dummy USDG, the testnet's reference asset.
# To retire an asset, switch it off: discover_whitelist_assets.py --chain testnet --disable <ticker>.
discover-whitelist-assets-rh-testnet:
    #!/usr/bin/env bash
    set -euo pipefail
    RUNS=$(ls broadcast/DeployDummyRStocks.s.sol/46630/run-latest.json broadcast/DeployDummyUsdgPair.s.sol/46630/run-latest.json 2>/dev/null || true)
    LISTINGS=script/operations/assets-whitelist/listings.robinhood.testnet.json
    ASSETS=$(jq -rn --slurpfile l "$LISTINGS" \
        '[(inputs | .transactions[] | select(.contractName=="DummyRStock" and .transactionType=="CREATE") | .contractAddress),
          ($l[0] | [.assets, .venues] | transpose[] | select(.[1] != 0) | .[0])]
         | map(ascii_downcase) | unique | join(",")' $RUNS)
    [ -n "$ASSETS" ] || { echo "no DummyRStock deploys in the broadcast logs"; exit 1; }
    echo "assets: $ASSETS"
    uv run script/operations/assets-whitelist/discover_whitelist_assets.py --chain testnet --min-depth 0.05 \
        --assets "$ASSETS"

whitelist-assets-rh-testnet:
    just chain-rh-testnet
    forge script WhitelistRobinhoodAssets --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300
    forge script WhitelistRobinhoodAssets --rpc-url rh-testnet --sig 'verify()'

# Lists the manifest's REALM_TOKEN as a direct-venue quote, priced from its native V4 pool (else its USDG one). ONCE per chain,
# right after REALM graduates; separate from the rStock/USDG loop above, which never touches it. Keepers
# keep its rate fresh afterwards (`RealmAssetsWhitelist.refreshRates`). Signer must be an approver.
whitelist-realm-rh:
    just chain-rh
    forge script WhitelistRealmToken --rpc-url rh-mainnet --account realm.deployer --slow --broadcast \
        --gas-estimate-multiplier 300
    forge script WhitelistRealmToken --rpc-url rh-mainnet --sig 'verify()'

whitelist-realm-rh-testnet:
    just chain-rh-testnet
    forge script WhitelistRealmToken --rpc-url rh-testnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300
    forge script WhitelistRealmToken --rpc-url rh-testnet --sig 'verify()'

# Buys a GRADUATED Realm token with native ETH through the universal router, on Uniswap V4.
# `amount` is anything cast parses (0.01ether, 1000000gwei, raw wei); `net` is mainnet|testnet.
# Route: the (ETH, token) pool when it is initialized, else ETH -> quote -> token through the token's
# first ERC20 quote, whose ETH pool comes from the manifest's ASSETS_WHITELIST price source.
# Token pool keys follow UniswapV4PoolConstants.realmPoolKey (fee token.poolFee(), spacing 200, graduator.hookFor).
# ponytail: no slippage floor (minOut 0); Robinhood has no public mempool to sandwich it.
# e.g. just buy 0xToken 0.01ether livo.dev testnet
buy token amount account net:
    #!/usr/bin/env bash
    set -euo pipefail
    case '{{net}}' in
        mainnet) RPC=rh-mainnet; ROUTER=0x8876789976dEcBfCbBbe364623C63652db8C0904; PM=0x8366a39CC670B4001A1121B8F6A443A643e40951 ;;
        testnet) RPC=rh-testnet; ROUTER=0x79E3a3473ad2d9285A7C87ACfb4A5C871396240d; PM=0x552815eF68E6eb418A3d65D0AA1043d93204F612 ;;
        *) echo "net must be mainnet or testnet"; exit 1 ;;
    esac
    ETH=0x0000000000000000000000000000000000000000
    KEY_T='(address,address,uint24,int24,address)'
    TOKEN=$(cast to-check-sum-address '{{token}}')
    WEI=$(cast to-unit '{{amount}}' wei)
    GRAD=$(cast call --rpc-url $RPC $TOKEN 'graduator()(address)')
    TFEE=$(cast call --rpc-url $RPC $TOKEN 'poolFee()(uint24)' | awk '{print $1}')
    # exact-in single swap; amountIn 0 = OPEN_DELTA, i.e. spend whatever the previous hop credited
    swap() { cast abi-encode "f(($KEY_T,bool,uint128,uint128,uint256,bytes))" "($1,$2,$3,0,0,0x)"; }
    HOOK=$(cast call --rpc-url $RPC $GRAD 'hookFor(address)(address)' $ETH)
    NATIVE_KEY="($ETH,$TOKEN,$TFEE,200,$HOOK)"
    # pool initialized <=> slot0 (PoolManager `pools` mapping, slot 6) is nonzero
    PID=$(cast keccak $(cast abi-encode 'f(address,address,uint24,int24,address)' $ETH $TOKEN $TFEE 200 $HOOK))
    SLOT0=$(cast call --rpc-url $RPC $PM 'extsload(bytes32)(bytes32)' $(cast keccak $(cast concat-hex $PID $(cast to-uint256 6))))
    if [ $((16#${SLOT0:2:16} | 16#${SLOT0:18:16} | 16#${SLOT0:34:16} | 16#${SLOT0:50:16})) -ne 0 ]; then
        echo "route: ETH -> token (hook $HOOK)"
        SWAPS=$(swap "$NATIVE_KEY" true $WEI); ACTIONS=0x06
    else
        [ "$(cast call --rpc-url $RPC $TOKEN 'quoteCount()(uint8)')" -ge 2 ] || { echo "no initialized pool for $TOKEN"; exit 1; }
        QUOTE=$(cast call --rpc-url $RPC $TOKEN 'quotes(uint256)(address)' 1)
        WL=$(grep -oP 'ASSETS_WHITELIST = \K0x[0-9a-fA-F]{40}' src/config/manifest.robinhood.{{net}}.sol)
        [ "$WL" != "$ETH" ] || { echo "ASSETS_WHITELIST unset in manifest.robinhood.{{net}}.sol"; exit 1; }
        SRC=$(cast call --rpc-url $RPC $WL "priceSource(address)((uint8,address,$KEY_T))" $QUOTE)
        read -r VENUE C0 C1 FEE TS QHOOK < <(echo "$SRC" | sed 's/ \[[^]]*\]//g' | tr -d '(),' | awk '{print $1, $3, $4, $5, $6, $7}')
        [ "$VENUE" = 3 ] && [ "$C0" = "$ETH" ] || { echo "quote $QUOTE has no V4 ETH pool in the whitelist: $SRC"; exit 1; }
        QTHOOK=$(cast call --rpc-url $RPC $GRAD 'hookFor(address)(address)' $QUOTE)
        # realmPoolKey sorts the pair; quote -> token is zeroForOne when the quote sorts first
        if [[ "${QUOTE,,}" < "${TOKEN,,}" ]]; then TKEY="($QUOTE,$TOKEN,$TFEE,200,$QTHOOK)"; Z=true; else TKEY="($TOKEN,$QUOTE,$TFEE,200,$QTHOOK)"; Z=false; fi
        echo "route: ETH -> $QUOTE -> token"
        SWAPS="$(swap "($C0,$C1,$FEE,$TS,$QHOOK)" true $WEI),$(swap "$TKEY" $Z 0)"; ACTIONS=0x0606
    fi
    SETTLE=$(cast abi-encode 'f(address,uint256)' $ETH $WEI)
    TAKE=$(cast abi-encode 'f(address,uint256)' $TOKEN 0)
    # actions: SWAP_EXACT_IN_SINGLE (x1-2), SETTLE_ALL, TAKE_ALL
    INPUT=$(cast abi-encode 'f(bytes,bytes[])' ${ACTIONS}0c0f "[$SWAPS,$SETTLE,$TAKE]")
    echo "buying $TOKEN with $WEI wei on {{net}}"
    # command 0x10 = V4_SWAP
    cast send --rpc-url $RPC --account '{{account}}' --value $WEI $ROUTER 'execute(bytes,bytes[],uint256)' \
        0x10 "[$INPUT]" $(( $(date +%s) + 600 ))

##################### ROLLBACK (unified factory proxies) #######################
# Break-glass: roll BOTH unified factory proxies (V2 + V4) back to their PREVIOUS
# implementation — the 2nd-to-last on-chain `Upgraded` event, read from the node via `cast logs`
# (fresh L2 → full-range getLogs is cheap). Broadcaster must be the proxy owner (realm.deployer).
# Guards refuse a bogus/incompatible target before any tx is sent; mainnet (chain 4663) asks to confirm.
# NOTE: rolling the V4 factory back also reverts which graduators new tokens use (the old
# graduators are baked into the previous V4 impl as immutables; they still live on-chain).
# The manifest is NOT auto-edited — if you keep the rollback, update FACTORY_UNIV{2,4}_UNIFIED_IMPL
# in src/config/manifest.<chain>.sol and run `just export-deployments`.
# Fill the two proxy addresses in from src/config/manifest.robinhood.mainnet.sol once deployed.
rollback-rh:
    just _rollback-unified-rpclogs "$ROBINHOOD_RPC_URL" 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000

_rollback-unified-rpclogs rpc v2proxy v4proxy:
    #!/usr/bin/env bash
    set -euo pipefail
    RPC='{{rpc}}'
    CHAINID=$(cast chain-id --rpc-url "$RPC")
    declare -a TARGETS=()
    echo "Chain $CHAINID — discovering previous implementations (proxy : current -> previous):"
    for PROXY in {{v2proxy}} {{v4proxy}}; do
        LP=$(cast call --rpc-url "$RPC" "$PROXY" 'LAUNCHPAD()(address)')
        LOGS=$(cast logs --rpc-url "$RPC" --from-block 0 --to-block latest 'Upgraded(address)' --address "$PROXY" --json)
        N=$(echo "$LOGS" | jq 'length')
        [ "$N" -ge 2 ] || { echo "❌ $PROXY: only $N Upgraded events; no previous impl"; exit 1; }
        PREV=$(echo "$LOGS" | jq -r '.[-2].topics[1]'); PREV="0x${PREV: -40}"
        CURR=$(echo "$LOGS" | jq -r '.[-1].topics[1]'); CURR="0x${CURR: -40}"
        [ "$(cast code --rpc-url "$RPC" "$PREV")" != "0x" ] || { echo "❌ prev impl $PREV has no bytecode"; exit 1; }
        PLP=$(cast call --rpc-url "$RPC" "$PREV" 'LAUNCHPAD()(address)')
        [ "${PLP,,}" = "${LP,,}" ] || { echo "❌ prev impl $PREV wired to $PLP, not proxy launchpad $LP — refusing"; exit 1; }
        echo "  $PROXY : $CURR -> $PREV"
        TARGETS+=("$PROXY=$PREV")
    done
    if [ "$CHAINID" = "4663" ]; then
        read -r -p "Broadcast these ROBINHOOD MAINNET rollbacks? type 'yes': " ok
        [ "$ok" = "yes" ] || { echo "aborted"; exit 1; }
    fi
    for t in "${TARGETS[@]}"; do
        PROXY="${t%%=*}"; PREV="${t##*=}"
        cast send --rpc-url "$RPC" --account realm.deployer "$PROXY" 'upgradeToAndCall(address,bytes)' "$PREV" 0x
        echo "✔ $PROXY rolled back to $PREV"
    done
    echo "Done. Reminder: if keeping this, update FACTORY_UNIV{2,4}_UNIFIED_IMPL in src/config/manifest.robinhood.<net>.sol and run 'just export-deployments'."
