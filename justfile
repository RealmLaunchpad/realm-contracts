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
launchpad := "0x8DBdc48B8d9066983ad84be79B0382edCe390a04"

tokenImpl := "0x8f50e17AE8dBa4f439076d7653b4Ebb01Db66A3e"
taxTokenImpl := "0xaB56c5f8E111f6420277063E2E406Fd25159db97"
bondingCurve := "0xb2F1c2f61a0b4436B18f724E9b57DCcb87EFdFff"
graduatorV2 := "0xcF816bA12a24cD9CC3297A6Ff7528cb66ea7e388"
graduatorV4 := "0xFfb90D2d55515314210Fb0cB4BE82A6645572103"

# ##################### Create tokens #######################

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{tokenImpl}} {{bondingCurve}} {{graduatorV2}} $LIVODEVADDRESS 0x1230000000000000000000000000000000000000000000000000000000000000 "0x"

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{tokenImpl}} {{bondingCurve}} {{graduatorV4}} $LIVODEVADDRESS 0x1230000000000000000000000000000000000000000000000000000000000001 "0x"

create-tax-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{taxTokenImpl}} {{bondingCurve}} {{graduatorV4}} $LIVODEVADDRESS 0x1230000000000000000000000000000000000000000000000000000040000001 0x00000000000000000000000000000000000000000000000000000000000001f40000000000000000000000000000000000000000000000000000000000127500

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

##########################################################

swapbuy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=true AMOUNT_IN={{value}} forge script UniswapV4SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

swapsell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} IS_BUY=false AMOUNT_IN={{amount}} forge script UniswapV4SwapSimulations --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)


