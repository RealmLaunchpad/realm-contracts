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
    @jq '.abi' out/ILiquidityLockUniv4WithFees.sol/ILiquidityLockUniv4WithFees.json > abis/ILiquidityLockUniv4WithFees.json
    @jq '.abi' out/ILivoBondingCurve.sol/ILivoBondingCurve.json > abis/ILivoBondingCurve.json
    @jq '.abi' out/ILivoGraduator.sol/ILivoGraduator.json > abis/ILivoGraduator.json
    @jq '.abi' out/ILivoLaunchpad.sol/ILivoLaunchpad.json > abis/ILivoLaunchpad.json
    @jq '.abi' out/ILivoTaxableTokenUniV4.sol/ILivoTaxableTokenUniV4.json > abis/ILivoTaxableTokenUniV4.json
    @jq '.abi' out/ILivoToken.sol/ILivoToken.json > abis/ILivoToken.json
    @jq '.abi' out/LivoGraduatorUniswapV2.sol/LivoGraduatorUniswapV2.json > abis/LivoGraduatorUniswapV2.json
    @jq '.abi' out/LivoGraduatorUniswapV4.sol/LivoGraduatorUniswapV4.json > abis/LivoGraduatorUniswapV4.json
    @jq '.abi' out/LiquidityLockUniv4WithFees.sol/LiquidityLockUniv4WithFees.json > abis/LiquidityLockUniv4WithFees.json
    @jq '.abi' out/LivoLaunchpad.sol/LivoLaunchpad.json > abis/LivoLaunchpad.json
    @jq '.abi' out/LivoSwapHook.sol/LivoSwapHook.json > abis/LivoSwapHook.json
    @jq '.abi' out/LivoTaxableTokenUniV4.sol/LivoTaxableTokenUniV4.json > abis/LivoTaxableTokenUniV4.json
    @jq '.abi' out/LivoToken.sol/LivoToken.json > abis/LivoToken.json
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
launchpad := "0x791365efD20717Ba9331c5e446922100Acc15ed3"

bondingCurve := "0x02cE4BA7037C1e2aaBd16bce7a309600f829D84e"
graduatorV2 := "0x8124363F309927B8F2E9429f201A58909A4B1Cee"
graduatorV4 := "0xc76B1D067e2Df80D2E4a452a03da98B803c9bA09"

factoryV2 := "0x1829283A92A82878d1b858C613FC58F24f2C3f2d"
factoryV4 := "0x298B28A24D660Ac228A7EA627b2A111732155Fe8"
factoryTaxToken := "0xa3Fd89198f2D23d168e3BFB5aC305F86Dd5A2652"

# ##################### Create tokens #######################

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} "createToken(string,string,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000000

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} "createToken(string,string,address,bytes32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000001

create-tax-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} "createToken(string,string,address,bytes32,uint16,uint32)" {{tokenName}} {{uppercase(tokenName)}} 0xBa489180Ea6EEB25cA65f123a46F3115F388f181 0x1230000000000000000000000000000000000000000000000000000000000001 500 1209600

create-token-v2-feesplit tokenName recipients sharesBps:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV2}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32)" {{tokenName}} {{uppercase(tokenName)}} {{recipients}} {{sharesBps}} 0x1230000000000000000000000000000000000000000000000000000000000000

create-token-v4-feesplit tokenName recipients sharesBps:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryV4}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32)" {{tokenName}} {{uppercase(tokenName)}} {{recipients}} {{sharesBps}} 0x1230000000000000000000000000000000000000000000000000000000000001

create-tax-token-feesplit tokenName recipients sharesBps sellTaxBps taxDurationSeconds:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{factoryTaxToken}} "createTokenWithFeeSplit(string,string,address[],uint256[],bytes32,uint16,uint32)" {{tokenName}} {{uppercase(tokenName)}} {{recipients}} {{sharesBps}} 0x1230000000000000000000000000000000000000000000000000000000000001 {{sellTaxBps}} {{taxDurationSeconds}}

####################### Buys / sells #################################

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyTokensWithExactEth(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellExactTokens(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 340282366920938463463374607431768211455

##########################################################

uniapprove tokenAddress:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=0 forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

swapbuy tokenAddress value:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=1 AMOUNT_IN={{value}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

swapsell tokenAddress amount:
    TOKEN_ADDRESS={{tokenAddress}} ACTION=2 AMOUNT_IN={{amount}} forge script UniswapV4Swaps --rpc-url $SEPOLIA_RPC_URL --account livo.dev --slow --broadcast

##########################################################

collectFees: 
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "claimTreasuryFees()"
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{graduatorV4}} "treasuryClaim()"


##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
