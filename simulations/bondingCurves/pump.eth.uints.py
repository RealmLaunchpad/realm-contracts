import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path


if __name__ == "__main__":
    outputdir = Path("/home/jl/defi/livo-launchpad/livo-contracts/simulations/img/")
    outputdir.mkdir(parents=True, exist_ok=True)

    # y = circulating supply
    # x = ETH collected

    # Constraints:
    # y(x) = b - k / (a + x)
    # y(8) = 800_000_000   (graduation triggered with 8 eth collected)
    # y(0) = 0
    # y(40) = 1_000_000_000

    # Find a, b, k
    a = 2.67e18
    b = 1.067e27
    k = 2.844e45

    total_supply = 1_000_000_000e18
    max_eth = 40e18

    x = np.linspace(0, max_eth, 1000)
    def y(x, a=a, b=b, k=k):
        return b - k / (a + x)

    graduation_supply = 800_000_000e18
    graduation_eth = 8e18

    print(f"a: {a}, b: {b}, k: {k}")
    print(f"y(0) ETH: {y(0)/1e18} tokens")
    print(f"y({graduation_eth/1e18}) ETH: {y(graduation_eth)/1e18} tokens")
    print(f"y({max_eth/1e18}) ETH: {y(max_eth)/1e18} tokens")

    plt.plot(x, y(x))
    plt.xlabel("x (ETH collected)")
    plt.ylabel("y (tokens minted)")
    plt.hlines(y=total_supply, xmin=0, xmax=max_eth, colors='gray', linestyles='dashed')
    plt.vlines(x=max_eth, ymin=0, ymax=total_supply, colors='gray', linestyles='dashed')
    # plot a dot
    plt.plot(max_eth, total_supply, 'o', color='green')
    plt.plot(graduation_eth, graduation_supply, 'o', color='red')
    plt.title("Bonding Curve")
    plt.savefig(outputdir / "pump.eth_uints_bonding_curve.png")

    ####################################################
    # TOKEN RESERVES CALCULATIONS
    ####################################################

    # Good results, except for the fees
    K = int(2.925619836e45)
    T0 = 72727273200000000286060606
    E0 = 2727272727272727272

    def getTokenReserves(ethReserves:int) -> int:
        return K / (ethReserves + E0) - T0

    def estimateBuyPrice(ethReserves:int) -> int:
        """ This is an approximation on valid for small buy amounts """
        return (ethReserves + E0) / (getTokenReserves(ethReserves) + T0)

    def uniswapTokenPrice(ethReserves:int, tokenReserves:int) -> int:
        return ethReserves / tokenReserves

    plt.close('all')
    plt.plot(x/1e18, getTokenReserves(x)/1e18)
    plt.xlabel("ETH reserves")
    plt.ylabel("Token reserves")
    plt.ylim(0, total_supply/1e18)
    plt.xlim(0, 15)
    plt.hlines(y=200000000, xmin=0, xmax=max_eth/1e18, colors='gray', linestyles='dashed')
    plt.vlines(x=8, ymin=0, ymax=total_supply/1e18, colors='gray', linestyles='dashed')
    plt.savefig(outputdir / "pump.eth_uints_token_reserves.png")

    print(f"Token supply at 0 ETH:  {getTokenReserves(0) / 1e18}")
    print(f"Token supply at 8 ETH:  {getTokenReserves(8e18) / 1e18}")
    print(f"Price at graduation: {getTokenReserves(graduation_eth) / 1e18}")

    ##############################################
    # Price matching in graduation - singularity point

    creatorSupply = 10_000_000e18
    graduationEthFee = 0.5e18

    for e in np.arange(7.8, 8.1, 0.001):
        ethReserves = int(e * 1e18)
        tokenReserves = getTokenReserves(ethReserves)
        buyPrice = estimateBuyPrice(ethReserves)

        univ2price = (ethReserves - graduationEthFee) / (tokenReserves - creatorSupply) # ETH/token
        priceStep = (univ2price - buyPrice) / buyPrice

        print(f"{ethReserves} ETH, {tokenReserves:.0f} tokens, {buyPrice:.16f} ETH/token, {univ2price:.16f} ETH/token, {100*priceStep:.2f}%")

        # optimum graduation set point:
        #   7956000000000052224 ETH collected
        #   201123251222964042402365440 tokens in reserves
        #   0.5 eth fee 
        #   1M tokens for token creator
        #   price in bonding curve = 0.0000000390113284 ETH/token
        #   price in uniswap = 0.0000000390114753 ETH/token
        #   price difference = 0.000000000000146900 ETH/token (perfectly acceptable)


    #############################################
    ethReserves = np.arange(7.5e18, 20e18, 0.01e18)
    tokenReserves = getTokenReserves(ethReserves)
    bondingCurvePrices = estimateBuyPrice(ethReserves)
    uniswapPrices = uniswapTokenPrice(ethReserves - graduationEthFee, tokenReserves - creatorSupply)

    graduationEth = 7956000000000052224
    graduationTokens = getTokenReserves(graduationEth)

    plt.close('all')
    plt.plot(ethReserves/1e18, bondingCurvePrices, label="Bonding Curve")
    plt.plot(ethReserves/1e18, uniswapPrices, label="Uniswap")
    plt.scatter([graduationEth/1e18], [0.0000000390113284], color='red')
    plt.title('Livo Graduation transition')
    plt.xlabel("ETH Reserves")
    plt.ylabel("Price (ETH/Token)")
    plt.grid()
    plt.legend()
    plt.savefig(outputdir / "pump.eth_uints_price_comparison.png")
