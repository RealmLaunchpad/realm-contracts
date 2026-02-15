import math

Q96 = 2**96


def tick_to_sqrt_x96(tick: int) -> int:
    return int((1.0001 ** (tick / 2)) * Q96)


def wei_per_token_to_sqrt_x96(wei_per_token: int) -> int:
    tokens_per_eth = 1e18 / wei_per_token
    return int(math.sqrt(tokens_per_eth) * Q96)


def sqrt_x96_to_tick(sqrt_x96: int, tick_spacing: int) -> int:
    price = (sqrt_x96 / Q96) ** 2
    raw_tick = math.log(price, 1.0001)
    return int(round(raw_tick / tick_spacing) * tick_spacing)


def main() -> None:
    tick_spacing = 200

    # Primary position range
    tick_lower = -7000
    tick_upper = 203600

    # Target graduation price
    graduation_wei_per_token = 42_500_000_000
    

    # Secondary ETH-only position config
    secondary_upper_offset_steps = 110  # tick steps of `tick_spacing`

    sqrt_pricex96_graduation = wei_per_token_to_sqrt_x96(graduation_wei_per_token)
    tick_graduation = sqrt_x96_to_tick(sqrt_pricex96_graduation, tick_spacing)
    tick_lower_2 = tick_graduation + tick_spacing
    tick_upper_2 = tick_upper - (secondary_upper_offset_steps * tick_spacing)

    print("// LivoGraduatorUniswapV4 price configuration")
    print(f"int24 constant TICK_LOWER = {tick_lower};")
    print(f"int24 constant TICK_UPPER = {tick_upper};")
    print(f"uint160 constant SQRT_PRICEX96_GRADUATION = {sqrt_pricex96_graduation};")
    print(f"int24 constant TICK_GRADUATION = {tick_graduation};")
    print(f"int24 constant TICK_LOWER_2 = TICK_GRADUATION + TICK_SPACING; // {tick_lower_2}")
    print(
        "int24 constant TICK_UPPER_2 = TICK_UPPER "
        f"- ({secondary_upper_offset_steps} * TICK_SPACING); // {tick_upper_2}"
    )

    # Optional sanity values for constructor-derived immutable prices
    print("\n// Constructor-derived values")
    print(f"SQRT_PRICEX96_LOWER_TICK = TickMath.getSqrtPriceAtTick({tick_lower}); // {tick_to_sqrt_x96(tick_lower)}")
    print(f"SQRT_PRICEX96_UPPER_TICK = TickMath.getSqrtPriceAtTick({tick_upper}); // {tick_to_sqrt_x96(tick_upper)}")
    print(f"SQRT_LOWER_2 = TickMath.getSqrtPriceAtTick({tick_lower_2}); // {tick_to_sqrt_x96(tick_lower_2)}")
    print(f"SQRT_UPPER_2 = TickMath.getSqrtPriceAtTick({tick_upper_2}); // {tick_to_sqrt_x96(tick_upper_2)}")


if __name__ == "__main__":
    main()
