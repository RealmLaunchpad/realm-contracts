# IMPLEMENTATION PLAN

## Interfaces

### Livo Factory

- whitelistGraduator() onlyOwner
- whitelistBoundingCurve() onlyOwner
- deployToken(graduator, boundingCurve) payable external

### Livo Launchpad

- graduateToken(address token)


### Graduator

- canGraduate(address token)
- graduateToken(address token)
- claimUniswapTradingFees