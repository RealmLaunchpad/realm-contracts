#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal, getcontext


getcontext().prec = 90

WAD = 10**18
TOTAL_SUPPLY = 1_000_000_000 * WAD


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


def score_candidate(
    token_error_wei: int,
    fee_error_wei: int,
    price_deviation_ratio: Decimal,
    w_token: Decimal,
    w_fee: Decimal,
    w_price: Decimal,
    fee_for_price_match_wei: int,
    target_tokens: int,
    target_fee_wei: int,
) -> Decimal:
    token_error_ratio = Decimal(token_error_wei) / Decimal(target_tokens)
    fee_error_ratio = Decimal(fee_error_wei) / Decimal(target_fee_wei)

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
    target_tokens: int,
    target_eth_wei: int,
) -> Candidate | None:
    if e0 <= 0 or t0 < 0:
        return None

    k = (TOTAL_SUPPLY + t0) * e0
    t_at_zero = reserves_from_eth(k, t0, e0, 0)
    if t_at_zero != TOTAL_SUPPLY:
        return None

    t_at_grad = reserves_from_eth(k, t0, e0, target_eth_wei)
    if t_at_grad <= 0:
        return None

    token_error_wei = abs(t_at_grad - target_tokens)

    price_curve = Decimal((target_eth_wei + e0) ** 2) / Decimal(k)

    uni_eth_after_target_fee = target_eth_wei - target_fee_wei
    if uni_eth_after_target_fee <= 0:
        return None
    price_uni_with_target_fee = Decimal(uni_eth_after_target_fee) / Decimal(t_at_grad)

    if price_curve == 0:
        return None

    price_deviation_ratio = abs(price_uni_with_target_fee - price_curve) / price_curve

    fee_for_price_match_wei = int(
        Decimal(target_eth_wei) - (Decimal(t_at_grad) * price_curve)
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
        target_tokens=target_tokens,
        target_fee_wei=target_fee_wei,
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
    target_tokens: int,
    target_eth_wei: int,
    starting_mcap_wei: int,
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
    if target_fee_wei <= 0 or target_fee_wei >= target_eth_wei:
        raise ValueError("target_fee_eth must be in (0, target_eth)")
    if starting_mcap_wei <= 0:
        raise ValueError("starting_mcap_eth must be > 0")

    best: Candidate | None = None

    e0 = min_e0
    while e0 <= max_e0:
        floor_t0 = TOTAL_SUPPLY * e0 // starting_mcap_wei - TOTAL_SUPPLY
        for t0 in range(floor_t0 - t0_window, floor_t0 + t0_window + 1):
            cand = evaluate_candidate(
                e0=e0,
                t0=t0,
                target_fee_wei=target_fee_wei,
                w_token=w_token,
                w_fee=w_fee,
                w_price=w_price,
                target_tokens=target_tokens,
                target_eth_wei=target_eth_wei,
            )
            if cand is None:
                continue

            if best is None or cand.score < best.score:
                best = cand

        e0 += step_e0

    if best is None:
        raise RuntimeError("No valid candidate found in the provided range")

    return best


def print_result(
    best: Candidate,
    target_fee_eth: Decimal,
    target_tokens: int,
    target_eth: Decimal,
    graduation_mcap_eth: Decimal,
    eth_usd_price: Decimal = Decimal("2000"),
) -> None:
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
        f"at e = {target_eth} ETH:"
        f" t = {best.t_at_grad}"
        f" (target error = {best.t_at_grad - target_tokens})"
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
    print()
    initial_price = Decimal(best.e0) / Decimal(TOTAL_SUPPLY + best.t0)
    initial_mcap = initial_price * Decimal(TOTAL_SUPPLY)
    initial_mcap_eth = initial_mcap / WAD
    print("Initial State (e = 0)")
    print("---------------------")
    print(f"initial price:      {initial_price:.30f} wei/wei")
    print(f"initial market cap: {initial_mcap_eth:.18f} ETH")
    print(f"initial market cap: ${initial_mcap_eth * eth_usd_price:,.2f} (ETH = ${eth_usd_price})")
    print()
    print("Liquidity & Marketcap")
    print("---------------------")
    tokens_deposited = from_wei(best.t_at_grad)
    eth_as_liquidity = target_eth - target_fee_eth
    token_price = eth_as_liquidity / tokens_deposited
    marketcap = token_price * from_wei(TOTAL_SUPPLY)
    pct_supply = tokens_deposited / from_wei(TOTAL_SUPPLY) * 100
    print(f"graduation threshold:          {target_eth} ETH")
    print(f"tokens deposited as liquidity: {tokens_deposited / 1_000_000:.2f}M ({pct_supply:.1f}% of total supply)")
    print(f"ETH deposited as liquidity:    {eth_as_liquidity} ETH")
    print(f"graduation fee:                {target_fee_eth} ETH")
    print(f"  - treasury fee:              {target_fee_eth * Decimal('0.8')} ETH")
    print(f"  - creator fee:               {target_fee_eth * Decimal('0.2')} ETH")
    print(f"token price in ETH:            {token_price:.18f}")
    print(f"token marketcap in ETH:        {marketcap:.6f}")
    marketcap_usd = marketcap * eth_usd_price
    print(f"token marketcap in USD:        ${marketcap_usd:,.2f} (ETH = ${eth_usd_price})")
    print()
    actual_grad_mcap = token_price * from_wei(TOTAL_SUPPLY)
    print("Graduation Marketcap")
    print("--------------------")
    print(f"target graduation mcap:  {graduation_mcap_eth} ETH")
    print(f"actual graduation mcap:  {actual_grad_mcap:.6f} ETH")
    print(f"actual graduation mcap:  ${actual_grad_mcap * eth_usd_price:,.2f} (ETH = ${eth_usd_price})")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Searches K, T0, E0 for ConstantProductBondingCurve under graduation "
            "constraints: target tokens at graduation price with target fee, "
            "and low price gap between bonding curve and Uniswap"
        )
    )
    parser.add_argument(
        "target_eth",
        type=Decimal,
        help="Target ETH reserves in bonding curve at graduation",
    )
    parser.add_argument(
        "target_fee_eth",
        type=Decimal,
        help="Target graduation fee in ETH",
    )
    parser.add_argument(
        "starting_mcap_eth",
        type=Decimal,
        help="Starting market cap in ETH (e.g., 2.5)",
    )
    parser.add_argument(
        "graduation_mcap_eth",
        type=Decimal,
        help="Target graduation market cap in ETH (e.g., 12)",
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
    parser.add_argument(
        "--eth-usd-price",
        type=Decimal,
        default=Decimal("2000"),
        help="ETH price in USD for marketcap conversion (e.g., 2000)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    target_eth_wei = to_wei(args.target_eth)
    starting_mcap_wei = to_wei(args.starting_mcap_eth)
    graduation_mcap_wei = to_wei(args.graduation_mcap_eth)
    uni_eth_wei = target_eth_wei - to_wei(args.target_fee_eth)
    target_tokens = TOTAL_SUPPLY * uni_eth_wei // graduation_mcap_wei

    best = search(
        min_e0_eth=args.min_e0_eth,
        max_e0_eth=args.max_e0_eth,
        step_e0_eth=args.step_e0_eth,
        t0_window=args.t0_window,
        target_fee_eth=args.target_fee_eth,
        w_token=args.weight_token,
        w_fee=args.weight_fee,
        w_price=args.weight_price,
        target_tokens=target_tokens,
        target_eth_wei=target_eth_wei,
        starting_mcap_wei=starting_mcap_wei,
    )
    print_result(
        best=best,
        target_fee_eth=args.target_fee_eth,
        target_tokens=target_tokens,
        target_eth=args.target_eth,
        graduation_mcap_eth=args.graduation_mcap_eth,
        eth_usd_price=args.eth_usd_price,
    )


if __name__ == "__main__":
    main()
