##################### BUILD ################################

build:
    forge build

##################### TESTING ################################
test:
    forge test

test-curves:
    forge test --match-contract Curve

##################### INSPECTION ####################
error-inspection errorhex:
    forge inspect LivoLaunchpad errors | grep {{errorhex}}

##################### OPERATIONS #######################

launchpad := "0x8a80112BCdd79f7b2635DDB4775ca50b56A940B2"

whitelist-curve curve:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "whitelistBondingCurve(address,bool)" {{curve}} true

whitelist-graduator graduator:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "whitelistGraduator(address,bool)" {{graduator}} true


bondingCurve := "0x87426937c4e28F69900C2f3453399CF5F06886D7"
graduator := "0xBa1a7Fe65E7aAb563630F5921080996030a80AA1"

create-token tokenName:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "createToken(string,string,string,address,address)" {{tokenName}} {{uppercase(tokenName)}} "/dummy/metadata/url" {{bondingCurve}} {{graduator}}

buy tokenAddress value:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "buyToken(address,uint256,uint256)" {{tokenAddress}} 1 175542935100 --value {{value}}

approve tokenAddress:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{tokenAddress}} "approve(address,uint256)" {{launchpad}} 11579208923731619542357098500868790785326998466564056403945758400791312963993

sell tokenAddress amount:
    cast send --rpc-url $SEPOLIA_RPC_URL --account livo.dev {{launchpad}} "sellToken(address,uint256,uint256,uint256)" {{tokenAddress}} {{amount}} 1 175542935100
