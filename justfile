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
    @jq '.abi' out/LivoLaunchpad.sol/LivoLaunchpad.json > abis/LivoLaunchpad.json
    @jq '.abi' out/ILivoQuoter.sol/ILivoQuoter.json > abis/ILivoQuoter.json
    @jq '.abi' out/ILivoQuoter2.sol/ILivoQuoter2.json > abis/ILivoQuoter2.json
    @jq '.abi' out/ILivoLaunchpad2.sol/ILivoLaunchpad2.json > abis/ILivoLaunchpad2.json
    @jq '.abi' out/ILivoToken.sol/ILivoToken.json > abis/ILivoToken.json
    @jq '.abi' out/ILivoClaims.sol/ILivoClaims.json > abis/ILivoClaims.json
    @jq '.abi' out/LivoFactoryUniV2Unified.sol/LivoFactoryUniV2Unified.json > abis/LivoFactoryUniV2Unified.json
    @jq '.abi' out/LivoFactoryUniV4Unified.sol/LivoFactoryUniV4Unified.json > abis/LivoFactoryUniV4Unified.json
    @jq '.abi' out/ILivoTaxableToken.sol/ILivoTaxableToken.json > abis/ILivoTaxableToken.json
    @jq '.abi' out/LivoCreatorVault.sol/LivoCreatorVault.json > abis/LivoCreatorVault.json
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
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

# --- Per-chain build retarget ------------------------------------------------
# ONE rule per target chain repoints EVERY per-chain compile-time import across ALL contracts at once
# (the taxable tokens' `DeploymentAddresses` + venue lib, and the V4 graduator's pool-geometry/fee
# libs). Retarget is for constant-only / trivial divergence; the V2 graduator, whose venue difference
# is behavioral, is instead two separate contracts (LivoGraduatorUniswapV2 / ...Arc) picked at deploy
# time. The rule is per-CHAIN, never per-chain-AND-per-contract: add every future per-chain contract
# swap to `_retarget` so callers keep using a single command. Run the `chain-*` recipe matching your
# target BEFORE `forge build`/deploy. Idempotent. Committed default is Ethereum mainnet, used by all tests.
chain-mainnet:
    @just _retarget DeploymentAddressesEthereumMainnet

chain-sepolia:
    @just _retarget DeploymentAddressesEthereumSepolia

chain-robinhood:
    @just _retarget DeploymentAddressesRobinhoodMainnet

chain-robintest:
    @just _retarget DeploymentAddressesRobinhoodTestnet

chain-arc-testnet:
    @just _retarget DeploymentAddressesArcTestnet Arc

chain-arc-mainnet:
    @just _retarget DeploymentAddressesArcMainnet Arc

# Fans a target chain out to every per-contract import-swap. `gradsuffix` is the lib variant
# ("" = the committed ETH-priced libs, "Arc" = the ARC variants). Add future per-chain swaps HERE.
# NOTE: the V2 graduator is NOT retargeted — LivoGraduatorUniswapV2 / ...Arc are separate contracts
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
        src/tokens/LivoTaxableTokenUniV2.sol src/tokens/LivoTaxableTokenUniV4.sol src/tokens/LivoUniv4BuyBacks.sol \
        src/tokens/LivoTaxableTokenUniV2Base.sol \
        src/tokens/DividendDistribution.sol src/dividends/LivoDividendSwapRegistry.sol
    sed -i -E 's#\{UniswapV2Venue[A-Za-z]* as UniswapV2Venue\} from "src/libraries/UniswapV2Venue[A-Za-z]*\.sol"#{UniswapV2Venue{{suffix}} as UniswapV2Venue} from "src/libraries/UniswapV2Venue{{suffix}}.sol"#' \
        src/tokens/LivoTaxableTokenUniV2.sol src/dividends/LivoDividendSwapRegistry.sol
    sed -i -E 's#\{UniswapV4PoolConstants[A-Za-z]* as UniswapV4PoolConstants\} from "src/libraries/UniswapV4PoolConstants[A-Za-z]*\.sol"#{UniswapV4PoolConstants{{suffix}} as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants{{suffix}}.sol"#' \
        src/tokens/LivoTaxableTokenUniV4.sol src/tokens/LivoUniv4BuyBacks.sol

# (internal) Repoints the V4 graduator's pool-geometry + fee libs to the `{{suffix}}` variant
# ("" = ETH, "Arc" = ARC). The V2 graduators are separate contracts and are NOT touched here.
# Use a `chain-*` recipe.
_graduators suffix:
    sed -i -E 's#\{UniswapV4PoolConstants[A-Za-z]* as UniswapV4PoolConstants\} from "src/libraries/UniswapV4PoolConstants[A-Za-z]*\.sol"#{UniswapV4PoolConstants{{suffix}} as UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants{{suffix}}.sol"#' \
        src/graduators/LivoGraduatorUniswapV4.sol
    sed -i -E 's#\{GraduationFeeConstants[A-Za-z]* as GraduationFeeConstants\} from "src/libraries/GraduationFeeConstants[A-Za-z]*\.sol"#{GraduationFeeConstants{{suffix}} as GraduationFeeConstants} from "src/libraries/GraduationFeeConstants{{suffix}}.sol"#' \
        src/graduators/LivoGraduatorUniswapV4.sol

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
launchpad := "0xd9f8bbe437a3423b725c6616C1B543775ecf1110"

bondingCurve := "0x1A7f2E2e4bdB14Dd75b6ce60ce7a6Ff7E0a3F3A5"
graduatorV2 := "0x1c10331F153cD344Feb030Aad7A11E2119F6f59A"
graduatorV4 := "0xc304593F9297f4f67E07cc7cAf3128F9027A2A3d"

factoryV2 := "0x2E8325243b87fB78711092D13538cB4CDbf3d098"
factoryV4 := "0xE6A46F0c681F7F67b349C77Ff2329dB4F016691E"
factoryTaxToken := "0x124972595Af23c2FbEE4b77a24ceF8d6af800016"
# Sniper-protected factories — fill in after deploy.
factorySniperProtected := "0x0000000000000000000000000000000000000000"
factoryV2SniperProtected := "0x0000000000000000000000000000000000000000"
factoryTaxTokenSniperProtected := "0x0000000000000000000000000000000000000000"
hookAddress := "0x0591a87D3a56797812C4DA164C1B005c545400Cc"

livodev := "0xBa489180Ea6EEB25cA65f123a46F3115F388f181"

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

deploy-sepolia: chain-sepolia
    # Hook address is logged in deployment output (LivoSwapHook row)
    forge script Deployments --rpc-url sepolia --verify --account livo.dev --slow --broadcast

# Re-deploys the four token implementations and all six factories (V2/V4/TaxToken + sniper-protected
# variants) against the existing Livo core, then whitelists them on the launchpad.
deploy-sepolia-factories: chain-sepolia
    forge script DeploymentsFactories --rpc-url sepolia --verify --account livo.dev --slow --broadcast

deploy-mainnet-factories:
    forge script DeploymentsFactories --rpc-url mainnet --verify --account livo.dev --slow --broadcast

# Mines a valid hook salt and deploys LivoSwapHook with whatever fee the current build bakes
# (`LP_FEE_BPS` constant in src/hooks/LivoSwapHook.sol: 100 = 1%, edit to 50 for the 0.5% variant and
# rebuild). After broadcast, paste the deployed address into src/config/manifest.<chain>.sol and
# run `just export-deployments`.
deploy-swap-hook-sepolia:
    forge script DeployLivoSwapHook --rpc-url sepolia --verify --account livo.dev --slow --broadcast

deploy-swap-hook-mainnet:
    forge script DeployLivoSwapHook --rpc-url mainnet --verify --account livo.dev --slow --broadcast

# Deploys the SMALL + LARGE liquidity-tier system (14 bonding curves + 4 V4 graduators).
# After broadcast, paste the logged addresses into the {SMALL,LARGE}_* and GRADUATOR_UNIV4_{SMALL,LARGE}*
# slots in src/config/manifest.{sepolia,mainnet}.sol, run `just export-deployments`, and only THEN
# upgrade the unified factories (`RedeployUnifiedFactoriesOnly`) so they pick the tier config up.
deploy-tiers-sepolia:
    forge script DeployTierLiquiditySystem --rpc-url sepolia --verify --account livo.dev --slow --broadcast

deploy-tiers-mainnet:
    forge script DeployTierLiquiditySystem --rpc-url mainnet --verify --account livo.dev --slow --broadcast

# Deploys 5 dummy xStocks on Sepolia — an ERC20 each, plus a Uniswap V4 pool against native ETH seeded
# with liquidity — replicating the symbols, fee tiers, tick spacings and prices of the real xStock pools
# on Robinhood mainnet. Exists so third-asset dividends can be exercised on a chain the indexer runs on;
# Robinhood testnet has the assets but no indexer. Writes the registry routes too when
# DIVIDEND_SWAP_REGISTRY is deployed on Sepolia and the broadcaster is one of its admins.
# Costs ETH_PER_POOL (default 0.05) of testnet ETH per pool. Dry-run it first — the same command
# without --broadcast simulates the whole thing against live Sepolia state, and IS the check:
#   forge script DeployDummyXStocks --rpc-url sepolia --account livo.dev
deploy-dummy-xstocks-sepolia:
    forge script DeployDummyXStocks --rpc-url sepolia --verify --account livo.dev --slow --broadcast

# The from-scratch two-part full-stack deploy (`DeployFullStack` + `DeployFullStackPart2`, and the
# `deploy-robinhood-part1/part2` recipes) was removed: both Robinhood chains are already deployed, and the
# two-pass flow only existed because the old swap hooks baked their LP fee in as a `constant`, needing one
# build per fee variant. The current `LivoSwapHook` is fee-agnostic (it reads `swapLpFeeBps` off the token),
# so a single build serves both fees. Recover the scripts from git history if a new chain ever needs one.

# Robinhood TESTNET has no Uniswap V2, so the V2 graduation path is skipped there
# (hasV2 = UNIV2_ROUTER != address(0)). Deploy a stock V2 instance ONCE, then paste the
# printed addresses into DeploymentAddressesRobinhoodTestnet (src/config/DeploymentAddresses.sol)
# and rebuild — after that `deploy-robinhood-testnet-part1` wires the V2 graduator/factory/tax-impls.
# Uses Uniswap's CANONICAL creation bytecode (pinned unpkg artifacts); the resulting pair init-code
# hash equals the canonical 0x96e8ac42…845f already set as UNIV2_PAIR_INIT_CODE_HASH, so that constant
# does NOT change. WETH is the chain's existing WETH; feeToSetter defaults to the testnet treasury.
deploy-univ2-robintest feeToSetter="0xBa489180Ea6EEB25cA65f123a46F3115F388f181":
    #!/usr/bin/env bash
    set -euo pipefail
    WETH=0x7943e237c7F95DA44E0301572D358911207852Fa
    RPC=$ROBINHOOD_TESTNET_RPC_URL
    FAC_CODE=$(curl -fsSL "https://unpkg.com/@uniswap/v2-core@1.0.1/build/UniswapV2Factory.json" | jq -r .bytecode)
    FAC_ARGS=$(cast abi-encode "c(address)" {{feeToSetter}})
    FAC=$(cast send --rpc-url $RPC --account livo.dev --json --create "0x${FAC_CODE}${FAC_ARGS:2}" | jq -r .contractAddress)
    echo "UNIV2_FACTORY = $FAC"
    RTR_CODE=$(curl -fsSL "https://unpkg.com/@uniswap/v2-periphery@1.1.0-beta.0/build/UniswapV2Router02.json" | jq -r .bytecode)
    RTR_ARGS=$(cast abi-encode "c(address,address)" "$FAC" "$WETH")
    RTR=$(cast send --rpc-url $RPC --account livo.dev --json --create "0x${RTR_CODE}${RTR_ARGS:2}" | jq -r .contractAddress)
    echo "UNIV2_ROUTER  = $RTR"
    echo
    echo ">>> Paste into DeploymentAddressesRobinhoodTestnet, then rebuild:"
    echo "    UNIV2_FACTORY = $FAC"
    echo "    UNIV2_ROUTER  = $RTR"
    echo "    UNIV2_PAIR_INIT_CODE_HASH stays 0x96e8ac42…845f (canonical, unchanged)"

# NB: ARC testnet had no official Uniswap, so Livo self-deployed the V2+V4 stack there (addresses in
# `DeploymentAddressesArcTestnet`). The deploy scripts, the vendored V2 router and the Uniswap V2
# submodules have since been removed — ARC mainnet ships official Uniswap, so nothing needs them
# again. Recover from git history (branch `feat/arc-chain-support`) if a future chain does.

# Regenerates deployments.{mainnet,sepolia}.md from the matching .sol manifests.
# CI runs the same command and fails if the result is not committed.
export-deployments:
    forge script ExportDeployments

##################### OPERATIONS ####################
# Alert if any reward creator has pending ETH claims but a 0 ETH wallet (ethereum + robinhood).
# Needs MAINNET_RPC_URL exported (or a sibling .env); robinhood uses its public RPC by default.
unfunded-creators:
    uv run script/operations/unfunded-accounts/check_unfunded_creators.py

# Rebuild the curated Uniswap V4 dividend routes for Robinhood Chain's xStocks by scanning the
# pool manager on-chain. Writes script/operations/dividend-routes/routes.robinhood.mainnet.json.
# Review the diff before writing it on-chain — a wrong pool routes a token's dividends elsewhere.
discover-dividend-routes:
    uv run script/operations/dividend-routes/discover_xstock_routes.py

# Write those routes into the registry, and — without --broadcast — the health check for the ones
# already live: it probes each asset's CURRENT route next to the fresh candidates and flags any that
# has stopped working. Only routes that differ from what is live get written, so re-running is a no-op.
# Needs DIVIDEND_SWAP_REGISTRY exported and an admin/owner signer. Set ROUTES_JSON to a narrowed file
# (discover_xstock_routes.py --only SYMBOL -o …) to add a single asset without touching the rest.
set-dividend-routes:
    just chain-robinhood
    forge script SetDividendRoutes --rpc-url robinhood-mainnet --account livo.dev

##################### ROLLBACK (unified factory proxies) #######################
# Break-glass: roll BOTH unified factory proxies (V2 + V4) back to their PREVIOUS
# implementation — the 2nd-to-last on-chain `Upgraded` event, i.e. Etherscan's
# "previous implementations". Broadcaster must be the proxy owner (livo.dev).
# Guards refuse a bogus/incompatible target before any tx is sent; mainnet asks to confirm.
# NOTE: rolling the V4 factory back also reverts which graduators new tokens use (the old
# graduators are baked into the previous V4 impl as immutables; they still live on-chain).
# The manifest is NOT auto-edited — if you keep the rollback, update FACTORY_UNIV{2,4}_UNIFIED_IMPL
# in src/config/manifest.<chain>.sol and run `just export-deployments`.
rollback-mainnet:
    just _rollback-unified "$ETH_RPC_URL" 0x78Af7E41ab894fc2aCd1b1c918e3CC6d710054b9 0x9A996216c0Cd3B1cDeDC4D2A38E0ca94eBeC3565

rollback-sepolia:
    just _rollback-unified "$SEPOLIA_RPC_URL" 0x87Dd69F8d294fA9cd704fccd38d36d6197F80868 0x2a992f6f5F7c049A165a13069BE3DbDEaa5C391b

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
        cast send --rpc-url "$RPC" --account livo.dev "$PROXY" 'upgradeToAndCall(address,bytes)' "$PREV" 0x
        echo "✔ $PROXY rolled back to $PREV"
    done
    echo "Done. Reminder: if keeping this, update FACTORY_UNIV{2,4}_UNIFIED_IMPL in src/config/manifest.<chain>.sol and run 'just export-deployments'."

##################### ROLLBACK — Robinhood (unified factory proxies) #######################
# Same break-glass rollback as `rollback-mainnet`, but Robinhood is on Blockscout, not Etherscan,
# so the previous impl is read from the node via `cast logs` (fresh L2 → full-range getLogs is cheap)
# instead of the Etherscan API. Broadcaster must be the proxy owner (livo.dev). Same guards; mainnet
# (chain 4663) asks to confirm. Manifest is NOT auto-edited — see the note under `rollback-mainnet`.
rollback-robinhood:
    just _rollback-unified-rpclogs "$ROBINHOOD_RPC_URL" 0x7843203be233b3Be7E5017A68a64FdBf32b45fFE 0xb637800Dcd5c83913D828E961dBB964A9896f19d

rollback-robinhood-testnet:
    just _rollback-unified-rpclogs "$ROBINHOOD_TESTNET_RPC_URL" 0xc0dE7109626A458dE1E0Ff06106830beD96DE971 0xfBa7137768E53f3B6a0d2333F41C44BaC7161FA0

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
        cast send --rpc-url "$RPC" --account livo.dev "$PROXY" 'upgradeToAndCall(address,bytes)' "$PREV" 0x
        echo "✔ $PROXY rolled back to $PREV"
    done
    echo "Done. Reminder: if keeping this, update FACTORY_UNIV{2,4}_UNIFIED_IMPL in src/config/manifest.robinhood.<net>.sol and run 'just export-deployments'."

create-token-v2 tokenName value="0":
    SALT=$(just next-salt {{factoryV2}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[])" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" --value {{value}}

create-token-v4 tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool)" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" {{renounceOwnership}} --value {{value}}

create-tax-token tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,500,1209600)" --value {{value}}

create-token-v4-feesplit tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryV4}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool)" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[(0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,3000),(0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f,7000)]" \
            "[]" {{renounceOwnership}} --value {{value}}

create-tax-token-feesplit tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxToken}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[(0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,3000),(0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f,7000)]" \
            "[]" {{renounceOwnership}} \
            "(300,500,1209600)" --value {{value}}

# ##################### Create tokens — sniper-protected variants #######################
# Default AntiSniperConfigs: 3% max buy, 3% max wallet, 3h window, empty whitelist.

create-token-v2-sniper tokenName value="0":
    SALT=$(just next-salt {{factoryV2SniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2SniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" \
            "(300,300,10800,[])" --value {{value}}

create-token-v4-sniper tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factorySniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factorySniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,300,10800,[])" --value {{value}}

create-tax-token-sniper tokenName value="0" renounceOwnership="false":
    SALT=$(just next-salt {{factoryTaxTokenSniperProtected}}) && echo "Using salt: $SALT" && \
        cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxTokenSniperProtected}} \
            "createToken(string,string,bytes32,(address,uint256)[],(address,uint256)[],bool,(uint16,uint16,uint32),(uint16,uint16,uint40,address[]))" \
            {{tokenName}} {{uppercase(tokenName)}} "$SALT" \
            "[({{livodev}},10000)]" "[]" {{renounceOwnership}} \
            "(300,500,1209600)" \
            "(300,300,10800,[])" --value {{value}}

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

v2buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=true AMOUNT_IN={{value}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v2sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=false AMOUNT_IN={{amount}} forge script UniswapV2Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

v4approve tokenAddress:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=0 HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v4buy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=1 AMOUNT_IN={{value}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

v4sell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=2 AMOUNT_IN={{amount}} HOOK_ADDRESS={{hookAddress}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

collectFees:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{graduatorV4}} "treasuryClaim()"


##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
