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
launchpad := "0x356DF589B73f7a097F9029be3d387f3548478927"

implementation := "0xfb536Abb27f52DBb62DD91f789C6B9a12C48441b"
bondingCurve := "0x854459b98Ef631A5D154761da705862c11AA10fc"
graduatorV2 := "0x544CC1E598e267975a7B50C87e6A20c2E62eF190"
graduatorV4 := "0xb22b28faf008C07b070311E8B9018a77c62475e1"

# ##################### Create tokens #######################

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{implementation}} {{bondingCurve}} {{graduatorV2}} $LIVODEVADDRESS 0x1230000000000000000000000000000000000000000000000000000000000000 "0x"

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{implementation}} {{bondingCurve}} {{graduatorV4}} $LIVODEVADDRESS 0x1230000000000000000000000000000000000000000000000000000000000001

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

approve tokenAddress:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{tokenAddress}} "approve(address,uint256)" {{launchpad}} 11579208923731619542357098500868790785326998466564056403945758400791312963993

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)