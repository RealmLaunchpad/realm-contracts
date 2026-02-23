##################### BUILD ################################
build:
    forge build

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
launchpad := "0x418d7C7C7C0FECA10bF0ff3020D1035cBF8Be61e"

tokenImpl := "0xBaF2bdF2b54cd40a0B581C76220eBd1f689AeBDC"
taxTokenImpl := "0xD0fFba48f3a791310Cf11553f3B69C15674723b7"
bondingCurve := "0xAE4e71529c80fDBc04a19407515CD46fa2e205fF"
graduatorV2 := "0xCb7EFCec309D40c74C4fCFABdf9fb2dB1F3c51c9"
graduatorV4 := "0x7f2a870981a6790f7c24978afec657C2c09Bdbf2"

# ##################### Create tokens #######################

create-token-v2 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{tokenImpl}} {{bondingCurve}} {{graduatorV2}} 0x1230000000000000000000000000000000000000000000000000000000000000 "0x"

create-token-v4 tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{tokenImpl}} {{bondingCurve}} {{graduatorV4}} 0x1230000000000000000000000000000000000000000000000000000000000001 "0x"

create-tax-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,address,address,address,bytes32,bytes)" {{tokenName}} {{uppercase(tokenName)}} {{taxTokenImpl}} {{bondingCurve}} {{graduatorV4}} 0x1230000000000000000000000000000000000000000000000000000040000001 0x00000000000000000000000000000000000000000000000000000000000001f40000000000000000000000000000000000000000000000000000000000127500

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
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "collectTreasuryFees()"
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{graduatorV4}} "treasuryClaim()"


##########################################################

# forge verify-contract {{address}} {{contractName}} --compiler-version 0.8.28+commit.7893614a --chain-id 11155111 --watch --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address)" 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 0x000000000022D473030F116dDEE9F6B43aC78BA3 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4)
