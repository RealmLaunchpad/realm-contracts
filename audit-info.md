# Livo Launchpad - taxable tokens extension

## Purpose of the changes

We want users to be able to deploy taxable tokens via Livo Launchpad. This requires a new token implementation with the buy/sell taxes logic, a uniswap V4 hook to perform the tax collection on swaps, and some adjustments to the uniswap V4 graduator.

## Description of the changes / functional requirements

- These taxable tokens are a variation of LivoToken that include a configuration for buy/sell taxes to fund projects.
- The buy/sell taxes are only collected for a limited amount of time (14 days max) and the buy/sell taxes are both capped at 5%
- Admins can deploy tokens bypassing these limitations if a project contact us with a solid case for what they need longer periods or higher taxes. These will be reviewed case by case.
- The token creators will receive buy/sell fees in WETH

## Tax collection mechanics

- Buy/sell taxes are collected with Uniswap V4 hooks. Therefore this only applies to tokens graduated via Univ4 graduator.
- On sells, the taxes are deducted as ETH, and wrapped into WETH to be sent to the tokenCreator
- On buys, the taxes are collected as tokens and transferred to the token contract itself. These tokens are sold for ETH, and this is wrapped into WETH, which is sent to the token creator.
- Therefore, the token creators receive the fees always as WETH
- The swapping of tokens -> ETH is triggered by normal token transfers, not part of the swap.

## Other notes

- The token creator can be changed dynamically via the LivoLaunchpad contract, and this should have effect everywhere. The token owner set in the launchpad should receive fees and taxes
- Swaps before the token has graduated are forbidden (even for non-taxable tokens) if the graduation happens with univ4 liquidity
- The LivoSwapHook used to collect taxes is also used for non-taxable tokens graduated via univ4. In those cases, the hook is used to prevent swaps before graduation.
- communityTakeOver() function gives admins ability to change token ownership
- createCustomToken() allows admins to bypass safety limits (tax duration, tax rates)

## Main focus of the audit:

- `src/graduators/LivoGraduatorUniswapV4.sol`
- `src/hooks/LivoSwapHook.sol`
- `src/tokens/LivoTaxableTokenUniV4.sol`


## Deployment chains

- Only on ethereum mainnet