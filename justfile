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
    @jq '.abi' out/IRealmQuoter2.sol/IRealmQuoter2.json > abis/IRealmQuoter2.json
    @jq '.abi' out/IRealmLaunchpad2.sol/IRealmLaunchpad2.json > abis/IRealmLaunchpad2.json
    @jq '.abi' out/IRealmToken.sol/IRealmToken.json > abis/IRealmToken.json
    @jq '.abi' out/IRealmClaims.sol/IRealmClaims.json > abis/IRealmClaims.json
    @jq '.abi' out/RealmFactoryUniV2Unified.sol/RealmFactoryUniV2Unified.json > abis/RealmFactoryUniV2Unified.json
    @jq '.abi' out/RealmFactoryUniV4Unified.sol/RealmFactoryUniV4Unified.json > abis/RealmFactoryUniV4Unified.json
    @jq '.abi' out/IRealmTaxableToken.sol/IRealmTaxableToken.json > abis/IRealmTaxableToken.json
    @jq '.abi' out/RealmCreatorVault.sol/RealmCreatorVault.json > abis/RealmCreatorVault.json
    @echo "✔ ABIs copied to abis/ directory"
    

##################### TESTING ################################
fast-test: check-dividend-layout
    forge test --no-match-contract Invariants --no-match-path "test/integration/**"

# Fails if a taxable token and its dividend extension disagree on storage layout. The extension is
# `delegatecall`ed with the token's storage, so this is the one property no Solidity test can assert
# for itself. It builds under the `layout` profile (its own `out` dir, so enabling `extra_output` does
# not thrash the default cache) and costs ~2s incrementally, hence running it before every `fast-test`.
check-dividend-layout:
    @python3 script/checks/dividend_layout.py

gas-report:
    forge test --no-match-contract Invariants --no-match-path "test/integration/**" --gas-report

test-curves:
    forge test --match-contract Curve

invariant-tests:
    forge test --match-contract Invariants

integration-tests:
    forge test --match-path "test/integration/**"

# Runs a super fast version of invariants for CI.(not so reliable at all) (runs=1, depth=5)
lean-invariants:
    sed -i 's/runs = [0-9]*/runs = 1/' foundry.toml
    sed -i 's/depth = [0-9]*/depth = 5/' foundry.toml
    forge test --match-contract Invariants

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect RealmLaunchpad errors | grep {{errorhex}}

# --- Per-chain build retarget ------------------------------------------------
# ONE rule per target chain repoints EVERY per-chain compile-time import across ALL contracts at once
# (the taxable tokens' `DeploymentAddresses` + venue lib, and the V4 graduator's pool-geometry/fee
# libs). Retarget is for constant-only / trivial divergence; the V2 graduator, whose venue difference
# is behavioral, is instead two separate contracts (RealmGraduatorUniswapV2 / ...Arc) picked at deploy
# time. The rule is per-CHAIN, never per-chain-AND-per-contract: add every future per-chain contract
# swap to `_retarget` so callers keep using a single command. Run the `chain-*` recipe matching your
# target BEFORE `forge build`/deploy. Idempotent. Committed default is Ethereum mainnet, used by all tests.
# NOT a deploy target — Ethereum mainnet is the committed build default the whole test suite forks
# against. Run this to get back to it after retargeting to a real deploy chain.
chain-mainnet:
    @just _retarget DeploymentAddressesEthereumMainnet

chain-sepolia:
    @just _retarget DeploymentAddressesEthereumSepolia

chain-robinhood:
    @just _retarget DeploymentAddressesRobinhoodMainnet

# Fans a target chain out to every per-contract import-swap. `gradsuffix` is the lib variant
# ("" = the committed ETH-priced libs, "Arc" = the ARC variants). Add future per-chain swaps HERE.
# NOTE: the V2 graduator is NOT retargeted — RealmGraduatorUniswapV2 / ...Arc are separate contracts
# selected at deploy time (their venue difference is behavioral, not just constants).
_retarget taxlib gradsuffix="":
    @just _taxtoken {{taxlib}} "{{gradsuffix}}"
    @just _graduators "{{gradsuffix}}"

# (internal) Repoints the taxable-token impls' (and their venue bases, the V4 buy-backs, the dividend
# mixin and the dividend swap registry) `DeploymentAddresses` import, the venue lib used by the V2
# swap-back AND the registry's third-asset conversion, and the V4 token-side pool-constants lib, to the
# target chain. Use a `chain-*` recipe.
_taxtoken lib suffix="":
    sed -i -E 's#DeploymentAddresses[A-Za-z]+ as DeploymentAddresses#{{lib}} as DeploymentAddresses#' \
        src/tokens/RealmTaxableTokenUniV2.sol src/tokens/RealmTaxableTokenUniV4.sol src/tokens/RealmUniv4BuyBacks.sol \
        src/tokens/RealmTaxableTokenUniV2Base.sol \
        src/tokens/DividendDistribution.sol src/dividends/RealmDividendSwapRegistry.sol
    sed -i -E 's#\{UniswapV2Venue[A-Za-z]* as UniswapV2Venue\} from "src/libraries/UniswapV2Venue[A-Za-z]*\.sol"#{UniswapV2Venue{{suffix}} as UniswapV2Venue} from "src/libraries/UniswapV2Venue{{suffix}}.sol"#' \
        src/tokens/RealmTaxableTokenUniV2.sol src/dividends/RealmDividendSwapRegistry.sol
    sed -i -E 's#\{UniswapV4PoolConstants[A-Za-z]* as UniswapV4PoolConstants\} from "src/libraries/UniswapV4PoolConstants[A-Za-z]*\.sol"#{UniswapV4PoolConstants{{suffix}} as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants{{suffix}}.sol"#' \
        src/tokens/RealmTaxableTokenUniV4.sol src/tokens/RealmUniv4BuyBacks.sol

# (internal) Repoints the V4 graduator's pool-geometry + fee libs to the `{{suffix}}` variant
# ("" = ETH, "Arc" = ARC). The V2 graduators are separate contracts and are NOT touched here.
# Use a `chain-*` recipe.
_graduators suffix:
    sed -i -E 's#\{UniswapV4PoolConstants[A-Za-z]* as UniswapV4PoolConstants\} from "src/libraries/UniswapV4PoolConstants[A-Za-z]*\.sol"#{UniswapV4PoolConstants{{suffix}} as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants{{suffix}}.sol"#' \
        src/graduators/RealmGraduatorUniswapV4.sol
    sed -i -E 's#\{GraduationFeeConstants[A-Za-z]* as GraduationFeeConstants\} from "src/libraries/GraduationFeeConstants[A-Za-z]*\.sol"#{GraduationFeeConstants{{suffix}} as GraduationFeeConstants} from "src/libraries/GraduationFeeConstants{{suffix}}.sol"#' \
        src/graduators/RealmGraduatorUniswapV4.sol

# Prints a valid salt (produces a token address ending in 0x1110) for the given factory.
# Usage: just next-salt <factoryAddress>
next-salt factory:
    #!/usr/bin/env bash
    set -euo pipefail
    IMPL=$(cast call --rpc-url $SEPOLIA_RPC_URL {{factory}} "TOKEN_IMPLEMENTATION()(address)")
    INIT_CODE="0x3d602d80600a3d3981f3363d3d373d3d3d363d73${IMPL:2}5af43d82803e903d91602b57fd5bf3"
    cast create2 --ends-with 1110 --deployer {{factory}} --init-code "$INIT_CODE" \
        | awk '/^Salt:/ {print $2}'

##################### Deployed addresses (sepolia) #######################
# Realm is a clean start: every slot below is zero until the Realm stack is deployed. Fill each one in
# from src/config/manifest.ethereum.sepolia.sol after deploying.
launchpad := "0x0000000000000000000000000000000000000000"

bondingCurve := "0x0000000000000000000000000000000000000000"
graduatorV2 := "0x0000000000000000000000000000000000000000"
graduatorV4 := "0x0000000000000000000000000000000000000000"

factoryV2 := "0x0000000000000000000000000000000000000000"
factoryV4 := "0x0000000000000000000000000000000000000000"
factoryTaxToken := "0x0000000000000000000000000000000000000000"
# Sniper-protected factories — fill in after deploy.
factorySniperProtected := "0x0000000000000000000000000000000000000000"
factoryV2SniperProtected := "0x0000000000000000000000000000000000000000"
factoryTaxTokenSniperProtected := "0x0000000000000000000000000000000000000000"
hookAddress := "0x0000000000000000000000000000000000000000"

realmdev := "0x1a209bB4d0bC40f169c06dC2808d7d512Aea62bb"

# ##################### Create tokens #######################
#
# All factory `createToken` signatures take:
#   (string name, string symbol, bytes32 salt, FeeShare[] feeReceivers, SupplyShare[] supplyShares, ...)
# with optional trailing `TaxConfigInit` and/or `AntiSniperConfigs` tuples.
#
# Canonical ABI tuples:
#   FeeShare           = (address,uint256)       — shares in bps, must sum to 10_000
#   SupplyShare        = (address,uint256)       — shares in bps, must sum to 10_000 (empty when no deployer buy)
#   TaxConfigInit      = (uint16,uint16,uint32)  — buyTaxBps, sellTaxBps, taxDurationSeconds
#   AntiSniperConfigs  = (uint16,uint16,uint40,address[])  — maxBuyPerTxBps, maxWalletBps, windowSeconds, whitelist
#
# Fee-split shareholders used by the `*-feesplit` recipes:
#   sharehonlder1 = 0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495
#   sharehonlder2 = 0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f
# Test wallets:
#   tiswallet1 = 0xd6fa895fABA3FE48410e9A00504BB556C89dd2E6
#   tiswallet2 = 0xdbB91f98C5826C89CC2312AD0B5a377a77613884

# ============================ FRESH DEPLOY (two phases) ============================
# Phase 0. Keepers registry + dividend swap registry + LP fee router. Their addresses are COMPILE-TIME
# constants elsewhere, so they must exist before anything else is built. Paste the two printed
# constants into src/config/DeploymentAddresses.sol, then rebuild.
deploy-prereqs-sepolia: chain-sepolia
    forge script DeployRealmPrereqs --rpc-url sepolia --verify --account realm.dev --slow --broadcast

deploy-prereqs-robinhood: chain-robinhood
    forge script DeployRealmPrereqs --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Only the two registries (keepers + dividend swap), owned by realm.dev. Use to redeploy them without
# touching the LP fee router or the hooks (whose Uniswap whitelisting must survive). Paste the two
# printed constants into src/config/DeploymentAddresses.sol, then rebuild.
deploy-registries-sepolia: chain-sepolia
    forge script DeployRealmRegistries --rpc-url sepolia --verify --account realm.dev --slow --broadcast

deploy-registries-robinhood: chain-robinhood
    forge script DeployRealmRegistries --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Phase 1. Everything else in one broadcast: fee handler, launchpad, quoter, liquidity adder, the V2 +
# three V4 graduators, 22 bonding curves, the creator-vault system, the three token impls and both
# unified factories (impl + proxy), then whitelists the factories on the launchpad. Refuses to run
# until phase 0 is pasted and the build is retargeted. Paste the printed manifest block afterwards and
# run `just export-deployments`.
deploy-stack-sepolia: chain-sepolia
    forge script DeployRealmStack --rpc-url sepolia --verify --account realm.dev --slow --broadcast

deploy-stack-robinhood: chain-robinhood
    forge script DeployRealmStack --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Redeploys both unified factory implementations from the CURRENT manifest and repoints the live
# proxies at them. The upgrade path for anything a factory holds as an immutable — token impls,
# graduators, curves, vault factory. Update the manifest FIRST.
upgrade-factories-sepolia: chain-sepolia
    forge script UpgradeRealmFactories --rpc-url sepolia --verify --account realm.dev --slow --broadcast

upgrade-factories-robinhood: chain-robinhood
    forge script UpgradeRealmFactories --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Mines a valid hook salt (the permission bits live in the hook's own address) and deploys the hook
# against the manifest's LP_FEE_ROUTER — override with ROUTER_ADDRESS=<addr> before the manifest is
# pasted. Run DeployRealmPrereqs first: it deploys the router proxy the hook takes as an immutable.
#
# Two variants, both deployed and both submitted to Uniswap for whitelisting; whichever is approved goes
# into the manifest's SWAP_HOOK:
#   *-swap-hook-*  -> RealmSwapHook: logic-for-logic the already-whitelisted hook.
#   *-realm-hook-* -> RealmHook: same, plus a RealmPoolState log per swap so the indexer can drop its
#                     PoolManager.Swap subscription.
deploy-swap-hook-sepolia:
    forge script DeployRealmSwapHook --rpc-url sepolia --verify --account realm.dev --slow --broadcast

deploy-swap-hook-robinhood:
    forge script DeployRealmSwapHook --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

deploy-realm-hook-sepolia:
    forge script DeployRealmHook --rpc-url sepolia --verify --account realm.dev --slow --broadcast

deploy-realm-hook-robinhood:
    forge script DeployRealmHook --rpc-url robinhood-mainnet --account realm.dev --slow --broadcast \
        --gas-estimate-multiplier 300

# Deploys 5 dummy xStocks on Sepolia — an ERC20 each, plus a Uniswap V4 pool against native ETH seeded
# with liquidity — replicating the symbols, fee tiers, tick spacings and prices of the real xStock pools
# on Robinhood mainnet. Exists so third-asset dividends can be exercised on a chain the indexer runs on;
# Robinhood testnet has the assets but no indexer. Writes the registry routes too when
# DIVIDEND_SWAP_REGISTRY is deployed on Sepolia and the broadcaster is one of its admins.
# Costs ETH_PER_POOL (default 1) of testnet ETH per pool, so 5 ETH for the five. Dry-run it first —
# the same command without --broadcast simulates it against live Sepolia state, and IS the check:
#   forge script DeployDummyXStocks --rpc-url sepolia --account realm.dev
deploy-dummy-xstocks-sepolia:
    forge script DeployDummyXStocks --rpc-url sepolia --verify --account realm.dev --slow --broadcast

# Regenerates deployments.{ethereum.sepolia,robinhood.mainnet}.md from the matching .sol manifests.
# CI runs the same command and fails if the result is not committed.
export-deployments:
    forge script ExportDeployments

##################### OPERATIONS ####################
# Alert if any reward creator has pending ETH claims but a 0 ETH wallet (ethereum + robinhood).
# Needs MAINNET_RPC_URL exported (or a sibling .env); robinhood uses its public RPC by default.
unfunded-creators:
    uv run script/operations/unfunded-accounts/check_unfunded_creators.py

# Rebuild the Uniswap V4 route CANDIDATES for Robinhood Chain's xStocks by scanning the pool manager
# on-chain. Writes script/operations/dividend-routes/routes.robinhood.mainnet.json.
discover-dividend-routes:
    uv run script/operations/dividend-routes/discover_xstock_routes.py

# Probe those candidates against forked state and keep whichever actually buys the most of each asset,
# writing the winners to catalogue.robinhood.mainnet.json in the wire format a token creation takes.
# BROADCASTS NOTHING and needs no signer: routes belong to the token that converts through them and are
# registered by that token at its own creation. The output feeds the frontend's suggested-asset list, so
# a creator picking a listed asset ships its route and never has to search for pools. Re-running is also
# the catalogue's health check — an asset whose pools have moved reports a different winner, or none.
pick-dividend-routes:
    just chain-robinhood
    forge script PickDividendRoutes --rpc-url robinhood-mainnet

##################### ROLLBACK (unified factory proxies) #######################
# Break-glass: roll BOTH unified factory proxies (V2 + V4) back to their PREVIOUS
# implementation — the 2nd-to-last on-chain `Upgraded` event, i.e. Etherscan's
# "previous implementations". Broadcaster must be the proxy owner (realm.dev).
# Guards refuse a bogus/incompatible target before any tx is sent; mainnet asks to confirm.
# NOTE: rolling the V4 factory back also reverts which graduators new tokens use (the old
# graduators are baked into the previous V4 impl as immutables; they still live on-chain).
# The manifest is NOT auto-edited — if you keep the rollback, update FACTORY_UNIV{2,4}_UNIFIED_IMPL
# in src/config/manifest.<chain>.sol and run `just export-deployments`.
# Fill the two proxy addresses in from src/config/manifest.ethereum.sepolia.sol once deployed.
rollback-sepolia:
    just _rollback-unified "$SEPOLIA_RPC_URL" 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000

_rollback-unified rpc v2proxy v4proxy:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}"
    RPC='{{rpc}}'
    CHAINID=$(cast chain-id --rpc-url "$RPC")
    TOPIC=0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b
    declare -a TARGETS=()
    echo "Chain $CHAINID — discovering previous implementations (proxy : current -> previous):"
    for PROXY in {{v2proxy}} {{v4proxy}}; do
        LP=$(cast call --rpc-url "$RPC" "$PROXY" 'LAUNCHPAD()(address)')
        RESP=$(curl -sf "https://api.etherscan.io/v2/api?chainid=$CHAINID&module=logs&action=getLogs&address=$PROXY&topic0=$TOPIC&fromBlock=0&toBlock=latest&apikey=$ETHERSCAN_API_KEY")
        [ "$(echo "$RESP" | jq -r '.status')" = "1" ] || { echo "❌ $PROXY: etherscan getLogs: $(echo "$RESP" | jq -r '.message // .result')"; exit 1; }
        N=$(echo "$RESP" | jq '.result | length')
        [ "$N" -ge 2 ] || { echo "❌ $PROXY: only $N Upgraded events; no previous impl"; exit 1; }
        PREV=$(echo "$RESP" | jq -r '.result[-2].topics[1]'); PREV="0x${PREV: -40}"
        CURR=$(echo "$RESP" | jq -r '.result[-1].topics[1]'); CURR="0x${CURR: -40}"
        [ "$(cast code --rpc-url "$RPC" "$PREV")" != "0x" ] || { echo "❌ prev impl $PREV has no bytecode"; exit 1; }
        PLP=$(cast call --rpc-url "$RPC" "$PREV" 'LAUNCHPAD()(address)')
        [ "${PLP,,}" = "${LP,,}" ] || { echo "❌ prev impl $PREV wired to $PLP, not proxy launchpad $LP — refusing"; exit 1; }
        echo "  $PROXY : $CURR -> $PREV"
        TARGETS+=("$PROXY=$PREV")
    done
    if [ "$CHAINID" = "1" ]; then
        read -r -p "Broadcast these MAINNET rollbacks? type 'yes': " ok
        [ "$ok" = "yes" ] || { echo "aborted"; exit 1; }
    fi
    for t in "${TARGETS[@]}"; do
        PROXY="${t%%=*}"; PREV="${t##*=}"
        cast send --rpc-url "$RPC" --account realm.dev "$PROXY" 'upgradeToAndCall(address,bytes)' "$PREV" 0x
        echo "✔ $PROXY rolled back to $PREV"
    done
    echo "Done. Reminder: if keeping this, update FACTORY_UNIV{2,4}_UNIFIED_IMPL in src/config/manifest.<chain>.sol and run 'just export-deployments'."

##################### ROLLBACK — Robinhood (unified factory proxies) #######################
# Same break-glass rollback as `rollback-sepolia`, but Robinhood is on Blockscout, not Etherscan,
# so the previous impl is read from the node via `cast logs` (fresh L2 → full-range getLogs is cheap)
# instead of the Etherscan API. Broadcaster must be the proxy owner (realm.dev). Same guards; mainnet
# (chain 4663) asks to confirm. Manifest is NOT auto-edited — see the note under `rollback-sepolia`.
# Fill the two proxy addresses in from src/config/manifest.robinhood.mainnet.sol once deployed.
rollback-robinhood:
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
        cast send --rpc-url "$RPC" --account realm.dev "$PROXY" 'upgradeToAndCall(address,bytes)' "$PREV" 0x
        echo "✔ $PROXY rolled back to $PREV"
    done
    echo "Done. Reminder: if keeping this, update FACTORY_UNIV{2,4}_UNIFIED_IMPL in src/config/manifest.robinhood.<net>.sol and run 'just export-deployments'."

create-token-v2 tokenName value="0":
    SALT=$(just next-salt {{factoryV2}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryV2}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[])" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" --value {{value}}

create-token-v4 tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool)" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" {{renounceOwnership}} --value {{value}}

create-tax-token tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryTaxToken}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,500,1209600)" --value {{value}}

create-token-v4-feesplit tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool)" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[(0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,3000),(0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f,7000)]" \
            "[]" {{renounceOwnership}} --value {{value}}

create-tax-token-feesplit tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryTaxToken}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[(0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,3000),(0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f,7000)]" \
            "[]" {{renounceOwnership}} \
            "(300,500,1209600)" --value {{value}}

# ##################### Create tokens — sniper-protected variants #######################
# Default AntiSniperConfigs: 3% max buy, 3% max wallet, 3h window, empty whitelist.

create-token-v2-sniper tokenName value="0":
    SALT=$(just next-salt {{factoryV2SniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryV2SniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" \
            "(300,300,10800,[])" --value {{value}}

create-token-v4-sniper tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factorySniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factorySniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,300,10800,[])" --value {{value}}

create-tax-token-sniper tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxTokenSniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{factoryTaxTokenSniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{realmdev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,500,1209600)" \
            "(300,300,10800,[])" --value {{value}}

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

v2buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=true AMOUNT_IN={{value}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account realm.dev --slow --broadcast

v2sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=false AMOUNT_IN={{amount}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account realm.dev --slow --broadcast

##########################################################

v4approve tokenAddress:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=0 HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account realm.dev --slow --broadcast

v4buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=1 AMOUNT_IN={{value}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account realm.dev --slow --broadcast

v4sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=2 AMOUNT_IN={{amount}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account realm.dev --slow --broadcast

##########################################################

collectFees:
    cast send --rpc-url $SEPOLIA_RPC_URL --account realm.dev {{graduatorV4}} "treasuryClaim()"


##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
