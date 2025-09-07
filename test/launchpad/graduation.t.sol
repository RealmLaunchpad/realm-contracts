// todo test that pair is created in uniswap at token launch
// todo test that you cannot transfer tokens to pair before graduation
// todo test that you can transfer tokens to pair after graduation
// todo test that it is not possible to create the univ2 pair right after token is deployed
// todo test that if ETH is transferred to the pair pre-graduation, liquidity addition doesn't revert
// todo test that if ETH is transferred to the pair pre-graduation, liquidity addition yields a strictly higher price than in the bonding curve
// todo test that tokens cannot be bought from the launchpad after graduation
// todo test that tokens cannot be sold to the launchpad after graduation
// todo test that graduated boolean turns true in launchpad
// todo test that graduated boolean turns true in LivoToken
// todo test that token balance of the contract after graduation is zero
// todo test that at graduation the team collects the graduation fee in eth
// todo test that a buy exceeding the graduation + excess limit reverts
// todo test that price in uniswap matches price in launchpad when las purchase meets the threshold exactly
// todo test that difference between launchpad price and uniswap price is not more than 5% if last purchase reaches the excess cap
// todo test that graduation transfers creator tokens to creator address
// todo test that circulating token supply updated after graduation to be all except the tokens sent to liquidity
// todo test that token eth reserves are reset to 0 after graduation
// todo test that eth balance change at graduation is the exact reserves pre graduation
// todo test that if uniswapv2 pair was already created, the univ2 price is the same as in the bonding curve  // REVIEW FUUUUCK . Perhaps we're forced to univ3.
// todo test that LP tokens are burned or transferred to 0xDEAD address review
// todo test that if graduator was wrongly configured ... what happens to the tokens? Emergency graduator change. It has to be approved by the token creator.
// todo test that
// todo test that
// todo test that
// todo test that
// todo test that
