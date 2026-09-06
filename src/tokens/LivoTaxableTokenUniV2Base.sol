// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableToken} from "src/tokens/LivoTaxableToken.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";

/// this line below is swapped per target chain at deploy time (the addresses are compile-time
/// constants baked into bytecode): DeploymentAddressesEthereumSepolia, DeploymentAddressesRobinhood*,
/// or DeploymentAddressesArc{Mainnet,Testnet} (ARC: `WETH` is the 6-decimal USDC ERC-20 V2 quote).
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";

/// @title LivoTaxableTokenUniV2Base
/// @notice Everything the Uniswap-V2 taxable token and its dividend extension must AGREE on: the V2
///         constants, the token's own storage, and the small reads either side may perform.
/// @dev This exists so `LivoTaxableTokenUniV2` and `LivoDividendLogicUniV2` derive an IDENTICAL storage
///      layout from the same declarations. The extension is `delegatecall`ed with the token's storage,
///      so a layout that drifts would have it writing the wrong slots; splitting the declarations out
///      here makes that structurally impossible rather than merely tested (it is tested too — see
///      `just check-dividend-layout`). Nothing behavioural belongs here: put a function in
///      this base only when BOTH sides need it, and everything else in the contract that uses it.
abstract contract LivoTaxableTokenUniV2Base is LivoTaxableToken {
    ///////////////////////////////// uniswap v2 related /////////////////////////////////////////
    // NB : THESE ARE HARDCODED FOR MAINNET TO SAVE GAS

    /// @notice Uniswap V2 router used to swap accumulated tax tokens for ETH
    IUniswapV2Router public constant UNISWAP_V2_ROUTER = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

    /// @notice WETH address (the second hop in the swap path)
    address public constant WETH = DeploymentAddresses.WETH;

    /// @notice Minimum tax-token balance that triggers an auto swap-back on the next sell.
    ///         0.05% of TOTAL_SUPPLY (= 500_000e18). Hardcoded to amortise gas across many small
    ///         sells while keeping per-swap price-impact bounded for the common case.
    uint256 public constant SWAP_THRESHOLD = TOTAL_SUPPLY / 2000;

    /// @notice Max swap-backs per block. Further same-block calls silently no-op. Picked so two
    ///         whales selling in the same block both get their tax routed.
    uint8 public constant MAX_SWAPBACKS_PER_BLOCK = 2;

    /////////////////////////// pure storage ///////////////////////

    /// @dev Re-entrancy guard for the swap-back path. When true, `_update` short-circuits the
    ///      tax + auto-trigger logic so the router's `transferFrom(this, pair, ...)` is a plain
    ///      ERC20 transfer. Lives in transient storage — auto-clears at end of tx, no SSTORE cost.
    bool internal transient _inSwap;

    /// @notice `block.number` of the most recent successful `_processCollectedTokens`; zero until the first.
    ///         Paired with `swapbacksThisBlock` for the per-block cap. `uint48`, packed with
    ///         `swapbacksThisBlock` in the slot that FOLLOWS the parent tax + `EarningsAllocation` slot
    ///         (that slot is full at 240 bits, so these no longer share it).
    uint48 public lastSwapbackBlock;

    /// @notice Swap-backs already settled in `lastSwapbackBlock`. Resets on the first swap-back
    ///         of a new block; at `MAX_SWAPBACKS_PER_BLOCK` further same-block calls silent-no-op.
    uint8 public swapbacksThisBlock;

    /// @notice `block.number` of the last `processLiquidity` — enforces its once-per-block cooldown
    ///         (with the `2 * SWAP_THRESHOLD` per-call cap, bounds what a sandwich of the half-sell can
    ///         extract per block). Packed with the swap-back counters above.
    uint48 public lastLiquidityProcessBlock;

    /// @notice Tax TOKENS set aside for the liquidity allocation, awaiting a `processLiquidity` add. Held
    ///         in the token's own balance alongside not-yet-swapped tax, but tracked apart: the swap-back
    ///         paths subtract it so this committed slice is never re-processed as tax. V2 buffers liquidity
    ///         as TOKENS (not ETH) because a V2 pair cannot deliver a token to its own address (INVALID_TO),
    ///         so the token side is kept, not bought back; `processLiquidity` sells only half for the ETH side.
    uint256 public liquidityPendingTokens;

    /// @notice Tax TOKENS set aside for a SELF-TOKEN dividend payout, awaiting a distribution.
    ///         V2 buffers this payout in token space, not as native, because a V2 pair reverts `INVALID_TO`
    ///         when asked to deliver a token to its own address — the ETH round trip every other venue
    ///         uses is simply not available here. Tracked apart from the tax pool for the same reason
    ///         `liquidityPendingTokens` is: it shares this contract's balance but is already committed.
    uint256 public dividendPendingTokens;

    //////////////////////// Events //////////////////////

    /// @notice Emitted whenever the contract auto- or manually-swaps accumulated tax tokens to ETH and
    ///         routes the proceeds through the earnings-allocation split.
    /// @dev `tokenAmountIn` / `ethAmount` describe THIS SWAP exactly — the same token and native amounts
    ///      the `UniswapV2Pair.Swap` in this tx carries — so an indexer can pair the two by amount and
    ///      mark the swap as a protocol swap-back rather than a trader sell. `tokenAmountIn` is therefore
    ///      net of any burn-share already removed in token-space (`CreatorTaxBurn`) and of the liquidity
    ///      share set aside as tokens; `ethAmount` is the balance DELTA across the swap, not the contract
    ///      balance, which may also hold router refunds from an earlier `processLiquidity`.
    /// @dev `ethToFund` is the slice of the routed ETH that actually reached the fee handler, i.e. the
    ///      creator fees. It differs from `ethAmount` for a token with a non-zero earnings allocation
    ///      (the dividends slice is withheld, and any stray balance is swept in on top), so accounting
    ///      must use this field and not `ethAmount`. The two are equal for a token with no allocation.
    event CreatorTaxSwapback(uint256 tokenAmountIn, uint256 ethAmount, uint256 ethToFund);

    /// @dev On V2 a payout in the token ITSELF must be buffered in token space: `UniswapV2Pair.swap`
    ///      reverts `INVALID_TO` when the recipient is one of the pair's own tokens, so there is no
    ///      ETH -> self-token route to buy it back with.
    function _isTokenSpaceDividendAsset(address asset) internal view virtual override returns (bool) {
        return asset == address(this);
    }

    /// @dev The share of total earnings the self-token dividend payout takes, in token space: all of
    ///      the dividends slice when the payout asset IS this token, none of it otherwise.
    /// @dev Gated on the warm `hasDividends` flag first, as `_sweepableAsset` below is: without dividends
    ///      asset 0's payout token is structurally zero and the answer can only be 0, so the cold SLOAD
    ///      buys nothing on the swap-back and earnings-routing paths of every non-dividend token.
    /// @dev Asset 0 alone answers this, and that is exact rather than an approximation: a self-token
    ///      payout may only be configured as the SOLE asset (`_initializeDividends` rejects it in any
    ///      larger set), so if it exists at all it is asset 0 and it takes the whole dividends slice.
    function _tokenSpaceDividendBps() internal view override returns (uint256) {
        return hasDividends && dividendAssets[0].token == address(this) ? dividendsBps : 0;
    }

    /// @dev The token's own balance is shared by the tax pool, the liquidity buffer, the self-token
    ///      dividend buffer and any undelivered self-token dividend pot. Everything that asks "how much
    ///      of this is unspoken for" asks here.
    function _sweepableAsset(address asset) internal view override returns (uint256) {
        if (asset != address(this)) return super._sweepableAsset(asset);

        uint256 balance = balanceOf(address(this));
        // Gated on warm-slot flags so a token with no allocation pays for no cold SLOAD here.
        uint256 reserved = liquidityBps != 0 ? liquidityPendingTokens : 0;
        // ONE cold read (asset 0's payout token) decides the whole dividend leg, and asset 0 is the only
        // slot that can hold it — a self-token payout is only legal as the sole asset. Only a self-token
        // payout has anything in token space: for a native or third-asset payout both
        // `dividendPendingTokens` and the ledger are structurally zero, and reading them on every sell
        // that reaches the swap-back branch is a cold SLOAD paid for a value that cannot be non-zero.
        if (hasDividends && dividendAssets[0].token == asset) {
            reserved += dividendPendingTokens + dividendAssets[0].owed;
        }
        return balance > reserved ? balance - reserved : 0;
    }
}
