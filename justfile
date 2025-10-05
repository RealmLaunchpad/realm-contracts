##################### BUILD ################################
build:
    forge build

##################### TESTING ################################
fast-test:
    forge test --no-match-contract Invariants

test-curves:
    forge test --match-contract Curve

invariant-tests:
    forge test --match-contract Invariants

# Runs a super fast version of invariants for CI.(not so reliable at all) (runs=1, depth=5)
lean-invariants:
    sed -i 's/runs = [0-9]*/runs = 1/' foundry.toml
    sed -i 's/depth = [0-9]*/depth = 5/' foundry.toml
    forge test --match-contract Invariants

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

##################### Deployed addresses #######################
launchpad := "0x8024f24dF3fe8B45dAa0D9D94F59AA7e98DA1B7f"

bondingCurve := "0x43f8bc6d25be185711680987019d20543e6b53f6"
graduator := "0x3ddc687a57674F5AD6e3b25f8c41cf41E70c0402"

##################### Actions #######################
whitelist-curve-and-graduator curve graduator:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "whitelistCurveAndGraduator(address,address,bool)" {{curve}} {{graduator}} true

create-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,string,address,address)" {{tokenName}} {{uppercase(tokenName)}} "/dummy/metadata/url" {{bondingCurve}} {{graduator}}

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

approve tokenAddress:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{tokenAddress}} "approve(address,uint256)" {{launchpad}} 11579208923731619542357098500868790785326998466564056403945758400791312963993

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 175542935100
