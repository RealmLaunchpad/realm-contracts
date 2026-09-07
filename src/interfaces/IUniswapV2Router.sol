// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IUniswapV2Router {
    function factory() external pure returns (address);

    // forge-lint: disable-next-line(mixed-case-function)
    function WETH() external pure returns (address);

    // forge-lint: disable-next-line(mixed-case-function)
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountEth, uint256 liquidity);

    /// @notice Two-ERC20 liquidity add. Used by the ARC V2 graduator to pair `<token, USDC>` (native
    ///         = USDC has no wrappable WETH, so `addLiquidityETH` is dead there — see UniswapV2VenueArc).
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Sells `amountIn` of `path[0]` for at least `amountOutMin` of `path[last]`, supporting
    ///         fee-on-transfer input tokens. ARC tax-token swap-back path (token → USDC ERC-20), the
    ///         token-output analogue of `swapExactTokensForETHSupportingFeeOnTransferTokens`.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    /// @notice Buys at least `amountOutMin` of `path[last]` with `msg.value` ETH, supporting
    ///         fee-on-transfer output tokens. Used on ETH-family chains by the dividend module to
    ///         convert an accrued native pot into a third payout asset.
    // forge-lint: disable-next-line(mixed-case-function)
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    /// @notice Sells `amountIn` of `path[0]` tokens for at least `amountOutMin` ETH, supporting
    ///         fee-on-transfer tokens (the FoT-aware variant skips the input-side amount check
    ///         and validates against the actual WETH received).
    /// @dev Required by `LivoTaxableTokenUniV2._processCollectedTokens`: the token diverts a tax during the
    ///      router's `transferFrom`, so the plain `swapExactTokensForETH` would revert.
    // forge-lint: disable-next-line(mixed-case-function)
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
