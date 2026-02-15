import numpy as np

amount0 = 18206023662.
pricelower = 0.000000003
pricehigher = 1000000000000000000000.
denom = 1 / np.sqrt(pricelower) - 1/np.sqrt(pricehigher)
print("liquidity amount0:", amount0 / denom)

tickLower = -196200
tighUpper = 69000
pricelower = np.sqrt(1.0001**tickLower)
pricehigher = np.sqrt(1.0001**tighUpper)

# Only token0 needed:  liquidity = amount0Desired / (1/√priceLower - 1/√priceUpper)
denom = 1 / np.sqrt(pricelower) - 1/np.sqrt(pricehigher)
print("liquidity amount0:", amount0 / denom)

# Only token1 needed: liquidity = amount1Desired / (√priceUpper - √priceLower)
denom = np.sqrt(pricehigher) - np.sqrt(pricelower)
amount1 = 1000000000000000000000000000.
print("liquidity amount1:", amount1 / denom)


# price conversions
def sqrtPriceX96ToPrice(sqrtPriceX96):
    return (sqrtPriceX96 / 2**96) ** 2

def priceToSqrtPriceX96(price):
    return int(np.sqrt(price) * 2**96)

# 333333334 tokens for 1 wei
print(f"333333334 as sqrtPriceX96: {priceToSqrtPriceX96(333333334)}")


def priceToTick(price):
    return int(np.log(price) / np.log(1.0001))

def tickToPrice(tick):
    return 1.0001 ** tick

print(f"tick for 333333334: {priceToTick(333333334)}")
print(f"tick for 0.001: {priceToTick(1/1000)}")

print(f"price for tick -69000: {priceToSqrtPriceX96(tickToPrice(-69000))}")
print(f"price for tick 196400: {priceToSqrtPriceX96(tickToPrice(196400))}")