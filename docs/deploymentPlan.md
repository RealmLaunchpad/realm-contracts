# Deployment guidelines

- foundry.toml: optimization runs : 200 or more


```bash

# Deployments

forge create LivoToken

forge create ConstantProductBondingCurve

forge create LivoLaunchpad --constructor-args TREASURY

forge create LivoGraduatorUniswapV2 --constructor-args UNISWAPROUTER LAUNCHPAD

forge create LiquidityLockUniv4WithFees --constructor-args UNIV4POSITIONMANAGER

# mine hook with the 
forge script MineHookAddressForTests.s.sol

# Deploy the hook with create2 and the found salt
forge script script/DeployHook.s.sol --rpc-url sepolia --broadcast --verify  (NO --ACCOUNT)

# update hook address in HookAddresses 

forge create LivoGraduatorUniswapV4 --constructor-args LAUNCHPAD LIQUIDITYLOCK POOLMANAGER POSITIONMANAGER PERMIT2 HOOK

# graduation parameters for whitelisting sets:
GRADUATION_THRESHOLD = 7956000000000052224
MAX_EXCESS_OVER_THRESHOLD = 100000000000000000
GRADUATION_ETH_FEE = 500000000000000000
    
# Whiteslisting sets
cast send LAUNCHPAD "whitelistComponents(address,address,address,uint256,uint256,uint256)" TOKENIMPLEMENTATION BONDINGCURVE GRADUATORV2 GRADUATIONTHRESHOLD MAXEXCESSOVERTHRESHOLD GRADUATIONFEE

cast send LAUNCHPAD "whitelistComponents(address,address,address,uint256,uint256,uint256)" TOKENIMPLEMENTATION BONDINGCURVE GRADUATORV4 GRADUATIONTHRESHOLD MAXEXCESSOVERTHRESHOLD GRADUATIONFEE

# Transfer ownerhips ? 


```
- update addresses in justfile
- update launchpad address in envio
