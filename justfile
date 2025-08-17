##################### BUILD ################################

build:
    forge build

##################### TESTING ################################

test-curves:
    forge test --match-contract Curve

##################### INSPECTION ####################
inspect-error errorhex:
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

##################### OPERATIONS #######################

launchpad := "0xe8a447E523138853d9B73f390a9cA603fa914a26"

whitelist-curve curve:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "whitelistBondingCurve(address,bool)" {{curve}} true

whitelist-graduator graduator:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "whitelistGraduator(address,bool)" {{graduator}} true


bondingCurve := "0x87426937c4e28F69900C2f3453399CF5F06886D7"
graduator := "0xBa1a7Fe65E7aAb563630F5921080996030a80AA1"

create-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,string,address,address)" {{tokenName}} {{uppercase(tokenName)}} "/dummy/metadata/url" {{bondingCurve}} {{graduator}}

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyToken(address,uint256,uint256)" {{tokenAddress}} 0 175542935100 --value {{value}}