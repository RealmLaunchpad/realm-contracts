##################### BUILD ################################
build:
    forge build

##################### TESTING ################################
fast-test:
    forge test --no-match-contract Invariants

gas-report:
    forge test --no-match-contract Invariants --gas-report

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

##################### Deployed addresses (sepolia) #######################
launchpad := "0xCbcaB7c9d9Ce45CEFb17bBEbd419881b253d7371"

implementation := "0x92A71B6A578D2345946DeCeDbCA3874702a3fCa3"
bondingCurve := "0x2Bf62383a4A1349461bB744b4eC561338D8b4CF9"
graduatorV2 := "0xF74aD241bDe9e2DAe7849D06ee4935731c1B5258"
graduatorV4 := "0x08feCd4F6340EdEb8F34a8e117fa248eD4A722d6"

# ##################### Actions #######################

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} {{implementation}} {{bondingCurve}} {{graduatorV2}} 0x1230000000000000000000000000000000000000000000000000000000000000

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} {{implementation}} {{bondingCurve}} {{graduatorV4}} 0x1230000000000000000000000000000000000000000000000000000000000001

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

approve tokenAddress:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{tokenAddress}} "approve(address,uint256)" {{launchpad}} 11579208923731619542357098500868790785326998466564056403945758400791312963993

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 175542935100
