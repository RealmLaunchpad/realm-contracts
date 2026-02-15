#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal, getcontext


getcontext().prec = 80

WAD = 10**18
TOTAL_SUPPLY = 1_000_000_000 * WAD
TARGET_ETH = Decimal("8.5")
TARGET_ETH_WEI = int(TARGET_ETH * WAD)
TARGET_TOKENS = 200_000_000 * WAD


@dataclass(frozen=True)
class Candidate:
    k: int
    t0: int
    e0: int
    t_at_zero: int
    t_at_target: int
    target_error: int


def to_wei(value_eth: Decimal) -> int:
    return int(value_eth * WAD)


def format_wei_as_eth(value_wei: int) -> str:
    return f"{Decimal(value_wei) / WAD:.18f}".rstrip("0").rstrip(".")


def reserves_from_eth(k: int, t0: int, e0: int, eth_reserves: int) -> int:
    return k // (eth_reserves + e0) - t0


def t0_real_numerator(e0: int) -> int:
    # From exact real-valued relation at target point:
    # ((TOTAL_SUPPLY + T0) * E0) / (TARGET_ETH_WEI + E0) - T0 = TARGET_TOKENS
    # Rearranged:
    # T0 = ((TOTAL_SUPPLY - TARGET_TOKENS) * E0 - TARGET_TOKENS * TARGET_ETH_WEI) / TARGET_ETH_WEI
    return (TOTAL_SUPPLY - TARGET_TOKENS) * e0 - TARGET_TOKENS * TARGET_ETH_WEI


def evaluate_candidate(e0: int, t0: int) -> Candidate | None:
    if e0 <= 0 or t0 < 0:
        return None

    k = (TOTAL_SUPPLY + t0) * e0
    t_at_zero = reserves_from_eth(k, t0, e0, 0)
    if t_at_zero != TOTAL_SUPPLY:
        return None

    t_at_target = reserves_from_eth(k, t0, e0, TARGET_ETH_WEI)
    err = abs(t_at_target - TARGET_TOKENS)

    return Candidate(
        k=k,
        t0=t0,
        e0=e0,
        t_at_zero=t_at_zero,
        t_at_target=t_at_target,
        target_error=err,
    )


def search(min_e0_eth: Decimal, max_e0_eth: Decimal, step_e0_eth: Decimal) -> Candidate:
    min_e0 = to_wei(min_e0_eth)
    max_e0 = to_wei(max_e0_eth)
    step_e0 = to_wei(step_e0_eth)

    if min_e0 <= 0:
        raise ValueError("min_e0_eth must be > 0")
    if max_e0 < min_e0:
        raise ValueError("max_e0_eth must be >= min_e0_eth")
    if step_e0 <= 0:
        raise ValueError("step_e0_eth must be > 0")

    best: Candidate | None = None

    e0 = min_e0
    while e0 <= max_e0:
        num = t0_real_numerator(e0)
        den = TARGET_ETH_WEI

        floor_t0 = num // den
        candidate_t0_values = {
            floor_t0 - 2,
            floor_t0 - 1,
            floor_t0,
            floor_t0 + 1,
            floor_t0 + 2,
        }

        for t0 in candidate_t0_values:
            cand = evaluate_candidate(e0, t0)
            if cand is None:
                continue

            if best is None:
                best = cand
                continue

            if cand.target_error < best.target_error:
                best = cand
                continue

            if cand.target_error == best.target_error and cand.e0 < best.e0:
                best = cand

        e0 += step_e0

    if best is None:
        raise RuntimeError("No valid candidate found in the provided range")

    return best


def print_result(best: Candidate) -> None:
    print("Best parameters found")
    print("---------------------")
    print(f"K  = {best.k}")
    print(f"T0 = {best.t0}")
    print(f"E0 = {best.e0}  (" + format_wei_as_eth(best.e0) + " ETH)")
    print()
    print("Constraint checks")
    print("-----------------")
    print(
        "at e = 0 ETH:"
        f" t = {best.t_at_zero}"
        f" (error = {best.t_at_zero - TOTAL_SUPPLY})"
    )
    print(
        f"at e = {TARGET_ETH} ETH:"
        f" t = {best.t_at_target}"
        f" (error = {best.t_at_target - TARGET_TOKENS})"
    )
    print(f"absolute target error: {best.target_error} token-wei")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Searches K, T0, E0 for ConstantProductBondingCurve with strict "
            "t(0) = TOTAL_SUPPLY and minimal error at t(8.5 ETH) = 200M"
        )
    )
    parser.add_argument(
        "--min-e0-eth",
        type=Decimal,
        default=Decimal("0.5"),
        help="Minimum E0 to scan, in ETH units (default: 0.5)",
    )
    parser.add_argument(
        "--max-e0-eth",
        type=Decimal,
        default=Decimal("6"),
        help="Maximum E0 to scan, in ETH units (default: 6)",
    )
    parser.add_argument(
        "--step-e0-eth",
        type=Decimal,
        default=Decimal("0.0001"),
        help="Step for E0 scan, in ETH units (default: 0.0001)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    best = search(args.min_e0_eth, args.max_e0_eth, args.step_e0_eth)
    print_result(best)


if __name__ == "__main__":
    main()
