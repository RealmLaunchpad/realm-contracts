import numpy as np

Q96 = 2 ** 96

def float_price_to_sqrtX96(price: float) -> int:
    # price expressed as token1/token0 == tokens per native ETH
    
    # Convert the price to a Q64.96 fixed point number
    return int(np.sqrt(price) * Q96)


def sqrtX96_to_float_price(sqrtX96: int) -> float:
    # Convert the Q64.96 fixed point number back to a regular float
    return (sqrtX96 / Q96) ** 2


def tick_to_sqrtX96(tick: int) -> int:
    price = 1.0001 ** tick
    sqrtPrice = np.sqrt(price)
    return int(sqrtPrice * Q96)


def sqrt_price_x96_to_tick(sqrt_price_x96: int) -> int:
    # Convert from fixed-point to real sqrt(price)
    sqrt_price = sqrt_price_x96 / Q96
    # Get the price
    price = sqrt_price ** 2
    # Compute tick using base-1.0001 logarithm
    tick = np.emath.logn(1.0001, price)
    # Round to nearest integer tick

    # Make the tick multiple of 200
    tick = tick - (tick % 200)
    return round(tick)


if __name__ == "__main__":

    # The lower price should be around 333333334 tokens per ETH , (0.000000003 ETH per token)
    starting_price = 333333334.0
    # print values as integers
    print(f"upper bound: {int(float_price_to_sqrtX96(starting_price))}")

    # The upper final price should be around 0.001 tokens per ETH (1000 ETH/tokens absolutely crazy)
    starting_price = 0.001
    print(f"lower bound: {int(float_price_to_sqrtX96(starting_price))}")

    print("")
    # starting price
    print("starting price: ", sqrtX96_to_float_price(1456928274337359229878378703093759), "tokens per ETH")
    # price after graduation
    print("after graduation: ", sqrtX96_to_float_price(1446501728071428127725498493042687), "tokens per ETH")

    # starting price
    print("starting price: ", int(1e18 / sqrtX96_to_float_price(1456928274337359229878378703093759)), "wei per token")
    # price after graduation
    print("after graduation: ", int(1e18 / sqrtX96_to_float_price(1446501728071428127725498493042687)), "wei per token")

    #################################### 
    # Graduation price , 39011306430 wei per token, which in token/eth is 25633594.24121184 tokens per eth
    print("\nAt graduation")
    token_price = 39011306440  # tokens per eth
    print(f"graduation price: {token_price} tokens per ETH")
    eth_per_token = 1e18 / token_price
    print(f"graduation price: {eth_per_token} wei per token")
    print(f"graduation price bound: {int(float_price_to_sqrtX96(eth_per_token))} sqrtX96")
    print(f"graduation tick: {sqrt_price_x96_to_tick(float_price_to_sqrtX96(eth_per_token))}")

    ####################################
    print("\nTick to sqrtX96 conversions")
    high_tick = 203600 # low token price
    print(f"high tick: {high_tick} -> {tick_to_sqrtX96(high_tick)} -> {sqrtX96_to_float_price(tick_to_sqrtX96(high_tick))} tokens per ETH")
    low_tick = -7000 # high token price
    print(f"low tick: {low_tick} -> {tick_to_sqrtX96(low_tick)} -> {sqrtX96_to_float_price(tick_to_sqrtX96(low_tick))} tokens per ETH")

    ####################################
    print("\neth per token to tick")
    token_price = 3305666893 
    eth_per_token = 1e18 / token_price
    print(f"eth per token: {eth_per_token} -> sqrtX96: {float_price_to_sqrtX96(eth_per_token)} -> tick: {sqrt_price_x96_to_tick(float_price_to_sqrtX96(eth_per_token))}")

    # sqrtX96 to tick
    print("\nSome more tests")
    sqrtprice = 401129254579132618442796085280768
    tick = sqrt_price_x96_to_tick(sqrtprice)
    print(f"sqrtX96: {sqrtprice} -> {tick} -> {sqrtX96_to_float_price(tick)} tokens per ETH")

    # tick to sqrtX96
    tick = 160600
    print(f"tick to sqrtX96: tick: {tick} -> sqrtX96: {tick_to_sqrtX96(tick)} -> price: {sqrtX96_to_float_price(tick_to_sqrtX96(tick))} tokens/ETH")


    #########################################
    # At gradutaion 
    print("\nAt graduation")
    sqrt_graduation_price = 401129254579132618442796085280768  # tokens/eth
    token_price = sqrtX96_to_float_price(sqrt_graduation_price) # tokens per eth
    print(f"graduation price: {token_price} tokens per ETH")
    print(f"graduation price: {int(token_price)} tokens per ETH (decimals)")
    eth_per_token = 1e18 / token_price # wei per token
    print(f"graduation price: {eth_per_token} wei per token")
    tick_at_graduation = sqrt_price_x96_to_tick(sqrt_graduation_price)


    #######################################
    # Secondary sigle sided eth liquidity
    SQRT_PRICEX96_GRADUATION = int(401129254579132618442796085280768)  # ~25633594.24121184 tokens per ETH
    TICK_GRADUATION = sqrt_price_x96_to_tick(SQRT_PRICEX96_GRADUATION)
    print("\nSecondary single sided liquidity")
    print(f"graduation tick: {TICK_GRADUATION}")
    lower_tick = TICK_GRADUATION + 200
    print(f"lower tick: {lower_tick} -> sqrtX96: {tick_to_sqrtX96(lower_tick)} -> price: {sqrtX96_to_float_price(tick_to_sqrtX96(lower_tick))} tokens/ETH")


