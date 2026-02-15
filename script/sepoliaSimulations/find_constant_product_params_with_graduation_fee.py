#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal, getcontext


getcontext().prec = 90

WAD = 10**18
TOTAL_SUPPLY = 1_000_000_000 * WAD
TARGET_ETH = Decimal("8.5")
TARGET_ETH_WEI = int(TARGET_ETH * WAD)
TARGET_TOKENS = 200_000_000 * WAD
TARGET_FEE_ETH = Decimal("0.5")
TARGET_FEE_WEI = int(TARGET_FEE_ETH * WAD)


@dataclass(frozen=True)
class Candidate:
    k: int
    t0: int
    e0: int
    t_at_zero: int
    t_at_grad: int
    token_error_wei: int
    fee_for_price_match_wei: int
    fee_error_wei: int
    price_curve: Decimal
    price_uni_with_target_fee: Decimal
    price_deviation_ratio: Decimal
    score: Decimal


def to_wei(value_eth: Decimal) -> int:
    return int(value_eth * WAD)


def from_wei(value_wei: int) -> Decimal:
    return Decimal(value_wei) / WAD


def format_eth(value_wei: int) -> str:
    return f"{from_wei(value_wei):.18f}".rstrip("0").rstrip(".")


def reserves_from_eth(k: int, t0: int, e0: int, eth_reserves: int) -> int:
    return k // (eth_reserves + e0) - t0


def t0_real_numerator(e0: int) -> int:
    return (TOTAL_SUPPLY - TARGET_TOKENS) * e0 - TARGET_TOKENS * TARGET_ETH_WEI


def score_candidate(
    token_error_wei: int,
    fee_error_wei: int,
    price_deviation_ratio: Decimal,
    w_token: Decimal,
    w_fee: Decimal,
    w_price: Decimal,
    fee_for_price_match_wei: int,
) -> Decimal:
    token_error_ratio = Decimal(token_error_wei) / Decimal(TARGET_TOKENS)
    fee_error_ratio = Decimal(fee_error_wei) / Decimal(TARGET_FEE_WEI)

    score = (
        w_token * token_error_ratio
        + w_fee * fee_error_ratio
        + w_price * price_deviation_ratio
    )

    if fee_for_price_match_wei < 0:
        score += Decimal("1")

    return score


def evaluate_candidate(
    e0: int,
    t0: int,
    target_fee_wei: int,
    w_token: Decimal,
    w_fee: Decimal,
    w_price: Decimal,
) -> Candidate | None:
    if e0 <= 0 or t0 < 0:
        return None

    k = (TOTAL_SUPPLY + t0) * e0
    t_at_zero = reserves_from_eth(k, t0, e0, 0)
    if t_at_zero != TOTAL_SUPPLY:
        return None

    t_at_grad = reserves_from_eth(k, t0, e0, TARGET_ETH_WEI)
    if t_at_grad <= 0:
        return None

    token_error_wei = abs(t_at_grad - TARGET_TOKENS)

    price_curve = Decimal((TARGET_ETH_WEI + e0) ** 2) / Decimal(k)

    uni_eth_after_target_fee = TARGET_ETH_WEI - target_fee_wei
    if uni_eth_after_target_fee <= 0:
        return None
    price_uni_with_target_fee = Decimal(uni_eth_after_target_fee) / Decimal(t_at_grad)

    if price_curve == 0:
        return None

    price_deviation_ratio = abs(price_uni_with_target_fee - price_curve) / price_curve

    fee_for_price_match_wei = int(
        Decimal(TARGET_ETH_WEI) - (Decimal(t_at_grad) * price_curve)
    )
    fee_error_wei = abs(fee_for_price_match_wei - target_fee_wei)

    score = score_candidate(
        token_error_wei=token_error_wei,
        fee_error_wei=fee_error_wei,
        price_deviation_ratio=price_deviation_ratio,
        w_token=w_token,
        w_fee=w_fee,
        w_price=w_price,
        fee_for_price_match_wei=fee_for_price_match_wei,
    )

    return Candidate(
        k=k,
        t0=t0,
        e0=e0,
        t_at_zero=t_at_zero,
        t_at_grad=t_at_grad,
        token_error_wei=token_error_wei,
        fee_for_price_match_wei=fee_for_price_match_wei,
        fee_error_wei=fee_error_wei,
        price_curve=price_curve,
        price_uni_with_target_fee=price_uni_with_target_fee,
        price_deviation_ratio=price_deviation_ratio,
        score=score,
    )


def search(
    min_e0_eth: Decimal,
    max_e0_eth: Decimal,
    step_e0_eth: Decimal,
    t0_window: int,
    target_fee_eth: Decimal,
    w_token: Decimal,
    w_fee: Decimal,
    w_price: Decimal,
) -> Candidate:
    min_e0 = to_wei(min_e0_eth)
    max_e0 = to_wei(max_e0_eth)
    step_e0 = to_wei(step_e0_eth)
    target_fee_wei = to_wei(target_fee_eth)

    if min_e0 <= 0:
        raise ValueError("min_e0_eth must be > 0")
    if max_e0 < min_e0:
        raise ValueError("max_e0_eth must be >= min_e0_eth")
    if step_e0 <= 0:
        raise ValueError("step_e0_eth must be > 0")
    if t0_window < 0:
        raise ValueError("t0_window must be >= 0")
    if target_fee_wei <= 0 or target_fee_wei >= TARGET_ETH_WEI:
        raise ValueError("target_fee_eth must be in (0, TARGET_ETH)")

    best: Candidate | None = None

    e0 = min_e0
    while e0 <= max_e0:
        floor_t0 = t0_real_numerator(e0) // TARGET_ETH_WEI
        for t0 in range(floor_t0 - t0_window, floor_t0 + t0_window + 1):
            cand = evaluate_candidate(
                e0=e0,
                t0=t0,
                target_fee_wei=target_fee_wei,
                w_token=w_token,
                w_fee=w_fee,
                w_price=w_price,
            )
            if cand is None:
                continue

            if best is None or cand.score < best.score:
                best = cand

        e0 += step_e0

    if best is None:
        raise RuntimeError("No valid candidate found in the provided range")

    return best


def print_result(best: Candidate, target_fee_eth: Decimal) -> None:
    print("Best parameters found")
    print("---------------------")
    print(f"K  = {best.k}")
    print(f"T0 = {best.t0}")
    print(f"E0 = {best.e0} ({format_eth(best.e0)} ETH)")
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
        f" t = {best.t_at_grad}"
        f" (target error = {best.t_at_grad - TARGET_TOKENS})"
    )
    print(
        "fee needed for exact price match:"
        f" {best.fee_for_price_match_wei}"
        f" ({format_eth(best.fee_for_price_match_wei)} ETH)"
        f" (error vs target {target_fee_eth} ETH = {best.fee_error_wei} wei)"
    )
    print(
        "price deviation using target fee:"
        f" {best.price_deviation_ratio * Decimal(100):.8f}%"
    )
    print(f"composite score: {best.score}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Searches K, T0, E0 for ConstantProductBondingCurve under graduation "
            "constraints: ~200M tokens at 8.5 ETH, ~0.5 ETH fee, and low price gap "
            "between bonding curve and Uniswap"
        )
    )
    parser.add_argument(
        "--min-e0-eth",
        type=Decimal,
        default=Decimal("1.5"),
        help="Minimum E0 scan bound in ETH (default: 1.5)",
    )
    parser.add_argument(
        "--max-e0-eth",
        type=Decimal,
        default=Decimal("5.0"),
        help="Maximum E0 scan bound in ETH (default: 5.0)",
    )
    parser.add_argument(
        "--step-e0-eth",
        type=Decimal,
        default=Decimal("0.0001"),
        help="E0 scan step in ETH (default: 0.0001)",
    )
    parser.add_argument(
        "--t0-window",
        type=int,
        default=5,
        help="Number of integer wei points to test around derived T0 (default: 5)",
    )
    parser.add_argument(
        "--target-fee-eth",
        type=Decimal,
        default=TARGET_FEE_ETH,
        help="Target graduation fee in ETH (default: 0.5)",
    )
    parser.add_argument(
        "--weight-token",
        type=Decimal,
        default=Decimal("1.0"),
        help="Weight for token-at-graduation error (default: 1.0)",
    )
    parser.add_argument(
        "--weight-fee",
        type=Decimal,
        default=Decimal("1.0"),
        help="Weight for fee error (default: 1.0)",
    )
    parser.add_argument(
        "--weight-price",
        type=Decimal,
        default=Decimal("1.0"),
        help="Weight for price deviation at target fee (default: 1.0)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    best = search(
        min_e0_eth=args.min_e0_eth,
        max_e0_eth=args.max_e0_eth,
        step_e0_eth=args.step_e0_eth,
        t0_window=args.t0_window,
        target_fee_eth=args.target_fee_eth,
        w_token=args.weight_token,
        w_fee=args.weight_fee,
        w_price=args.weight_price,
    )
    print_result(best=best, target_fee_eth=args.target_fee_eth)


if __name__ == "__main__":
    main()
