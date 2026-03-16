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
    @jq '.abi' out/ILivoToken.sol/ILivoToken.json > abis/ILivoToken.json
    @jq '.abi' out/ILivoClaims.sol/ILivoClaims.json > abis/ILivoClaims.json
    @jq '.abi' out/LivoFactoryBase.sol/LivoFactoryBase.json > abis/LivoFactoryBase.json
    @jq '.abi' out/LivoFactoryTaxToken.sol/LivoFactoryTaxToken.json > abis/LivoFactoryTaxToken.json
    @jq '.abi' out/ILivoFeeSplitter.sol/ILivoFeeSplitter.json > abis/ILivoFeeSplitter.json
    @echo "✔ ABIs copied to abis/ directory"
    

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

taxtokenaddresses:
    sed -i 's#import {DeploymentAddressesMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#import {DeploymentAddressesSepolia as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";#' src/tokens/LivoTaxableTokenUniV4.sol

##################### Deployed addresses (sepolia) #######################
launchpad := "0xf29c6a8eCAD0a2ca908c9076dD2E4A025be75EF7"

bondingCurve := "0x36cfDfd23fDe89dc067ac17901BC5959c6bD2eeB"
graduatorV2 := "0x6aCB368dB13eF4d29F516DDB464f62A6D168C248"
graduatorV4 := "0x23DAE4f548af2F7e7a65C903c74F3168Ba1C734D"

factoryV2 := "0x494BDb64b52c54c3c9133308c34253a492f925Be"
factoryV4 := "0xA3bcfc113064A4b8bFC15d219146c6b0141C2C1B"
factoryTaxToken := "0x4c1F43317137485763eDFAE1eA4c727e42ee7306"
hookAddress := "0x0000000000000000000000000000000000000000"

# ##################### Create tokens #######################

# sharehonlder1 = 0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495
# sharehonlder2 = 0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f
# tiswallet1 = 0xd6fa895fABA3FE48410e9A00504BB556C89dd2E6
# tiswallet2 = 0xdbB91f98C5826C89CC2312AD0B5a377a77613884

deploy-sepolia: taxtokenaddresses
    # Hook address is logged in deployment output (LivoSwapHook row)
    forge script Deployments --rpc-url sepolia --verify --account livo.dev --slow --broadcast

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} "createToken(string,string,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000000

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} "createToken(string,string,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000001

create-tax-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} "createToken(string,string,address,bytes32,uint16,uint16,uint32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000001 0 500 1209600

create-token-v2-feesplit tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32)" {{tokenName}} {{uppercase(tokenName)}} "[0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f]" [3000,7000] 0x1230000000000000000000000000000000000000000000000000000000000000

create-token-v4-feesplit tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32)" {{tokenName}} {{uppercase(tokenName)}} "[0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f]" [3000,7000] 0x1230000000000000000000000000000000000000000000000000000000000001

create-tax-token-feesplit tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32,uint16,uint16,uint32)" {{tokenName}} {{uppercase(tokenName)}} "[0x26fFa73c8fFcB8F4BF55d5A11a57c6bfEA7F4495,0x643e37aCbbbc8e6e2b548C3eA150fDf9BAB8C27f]" [3000,7000] 0x1230000000000000000000000000000000000000000000000000000000000001 0 500 1209600

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
