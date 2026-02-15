import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path


if __name__ == "__main__":
    outputdir = Path("/home/jl/defi/livo-launchpad/livo-contracts/simulations/img/")
    outputdir.mkdir(parents=True, exist_ok=True)

    # Formula:
    # y = b - k / (offset + x)
    # k / (offset + x) = b - y

    offset = 30
    k = 32190005730
    b = 1073000191

    total_supply = 1_000_000_000

    max_sol = 410
    x = np.linspace(0, max_sol, 1000)

    y = b - k / (offset + x)


    plt.plot(x, y)
    plt.xlabel("x (SOL collected)")
    plt.ylabel("y (tokens minted)")
    plt.hlines(y=total_supply, xmin=0, xmax=max_sol, colors='gray', linestyles='dashed')
    plt.vlines(x=max_sol, ymin=0, ymax=total_supply, colors='gray', linestyles='dashed')
    # plot a dot
    plt.plot(max_sol, total_supply, 'o', color='green')
    plt.plot(85, 800_000_000, 'o', color='red')
    plt.title("Bonding Curve")
    plt.savefig(outputdir / "pump.fun_bonding_curve.png")

