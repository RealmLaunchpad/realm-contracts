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
    a = 8/3
    b = 3_200_000_000/3
    k = 25_600_000_000/9

    total_supply = 1_000_000_000
    max_eth = 40
    x = np.linspace(0, max_eth, 1000)
    def y(x, a=a, b=b, k=k):
        return b - k / (a + x)

    print(f"a: {a}, b: {b}, k: {k}")
    print(f"y(0): {y(0)}, y(8): {y(8)}, y(40): {y(40)}")

    plt.plot(x, y(x))
    plt.xlabel("x (ETH collected)")
    plt.ylabel("y (tokens minted)")
    plt.hlines(y=total_supply, xmin=0, xmax=max_eth, colors='gray', linestyles='dashed')
    plt.vlines(x=max_eth, ymin=0, ymax=total_supply, colors='gray', linestyles='dashed')
    # plot a dot
    plt.plot(max_eth, total_supply, 'o', color='green')
    plt.plot(8, 800_000_000, 'o', color='red')
    plt.title("Bonding Curve")
    plt.savefig(outputdir / "pump.eth_bonding_curve.png")

