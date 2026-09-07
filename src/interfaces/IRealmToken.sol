// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

interface IRealmToken is IERC20 {
    //////////////////////// Events //////////////////////

    event Graduated();
    event NewOwnerProposed(address owner, address proposedOwner, address caller);
    event OwnershipTransferred(address newOwner);

    /// @notice Emitted once during init with the pre-graduation LP-fee config the token carries.
    ///         The creator tax (taxable variants only) is reported separately by
    ///         `RealmTaxableTokenInitialized`.
    event LaunchpadFeesInitialized(uint16 lpFeeBps, uint16 treasuryShareBps);

    /// @notice Shared initialization parameters for Realm token clones
    /// @dev `vaultAllocation` is the amount of supply that is minted to the factory (`msg.sender` of
    ///      `initialize`) instead of the launchpad, so the factory can lock it in creator vaults.
    ///      Zero for normal tokens (full supply minted to the launchpad, identical to before).
    struct InitializeParams {
        string name;
        string symbol;
        address tokenOwner;
        address graduator;
        address launchpad;
        address feeHandler;
        uint256 vaultAllocation;
        uint16 lpFeeBps; // pre-graduation LP/trading fee on buys and sells (bps), split treasury/creator
        uint16 treasuryShareBps; // share of the LP fee routed to the treasury (bps); remainder to creator
        uint16 swapLpFeeBps; // post-graduation LP fee `LivoSwapHook` charges on V4 swaps (bps); 0 for V2, 50/100 for V4
    }

    /// @notice Tax configuration for a token.
    /// @dev LEGACY: superseded by `RealmTradeFees` / `getSwapFees`. Kept for backwards compatibility —
    ///      see `getTaxConfig`.
    struct TaxConfig {
        uint16 buyTaxBps; // Buy tax in basis points (max 500 = 5%)
        uint16 sellTaxBps; // Sell tax in basis points (max 500 = 5%)
        uint40 taxDurationSeconds; // Duration of the tax window from token creation (0 once the window has closed)
        uint40 graduationTimestamp; // Timestamp when token graduated (0 if not graduated)
    }

    /// @notice Pre-trade context the launchpad passes to `getLaunchpadFees` during pre-graduation trades.
    /// @dev Deliberately carries only objective pre-trade pool state. Two omissions are load-bearing:
    ///      - The trade's own gross size (ETH in / tokens out) is not provided: the launchpad treats
    ///        the fee as a constant bps and inverts it for exact-output quotes, so a fee that depended
    ///        on this trade's own size would make the forward and inverse quotes inconsistent.
    ///      - The trader identity is not provided: quotes are served from views (`RealmQuoter`, the
    ///        launchpad `quoteX` functions) whose `msg.sender` is the quoter caller, not the eventual
    ///        trader, so a trader-dependent fee could not be quoted consistently with execution.
    ///      The fee MUST therefore be a pure function of `(isBuy, ethReserves, releasedSupply, time)`.
    struct LaunchpadTrade {
        bool isBuy; // true for buys, false for sells
        uint256 ethReserves; // launchpad ETH reserves for this token, pre-trade
        uint256 releasedSupply; // circulating supply sold, pre-trade
    }

    /// @notice Pre-graduation fee policy returned by the token for a given trade. The launchpad always
    ///         charges the LP (trading) fee, splitting it between treasury and creator by
    ///         `treasuryShareBps`; the optional tax (0 when not configured) goes entirely to the creator.
    ///         Mirrors the post-graduation `LivoSwapHook` accounting (LP fee split + creator tax).
    struct LaunchpadFees {
        uint16 lpFeeBps; // LP/trading fee for THIS trade, in bps of gross ETH; split treasury/creator
        uint16 treasuryShareBps; // share of the LP fee routed to the treasury; remainder to the creator
        uint16 taxBps; // creator tax for THIS trade (0 if none), in bps of gross ETH; 100% to creator
    }

    /// @notice Fees `LivoSwapHook` charges on a single post-graduation V4 swap leg, for one direction.
    /// @dev Post-graduation analogue of `LaunchpadFees`, without `treasuryShareBps`: the LP-fee split is
    ///      performed downstream by `RealmLpFeeRouter`'s marketcap tiers, not by the token.
    struct RealmTradeFees {
        uint16 taxBps; // currently-effective creator tax for this leg (bps of gross ETH); 0 outside the tax window
        uint16 lpFeeBps; // post-graduation LP fee (bps); always effective; 0 for V2 tokens
    }

    ////////////////// STATE CHANGING FUNCTIONS ////////////////////

    function markGraduated() external;

    /// @notice Registers the token's initial fee receiver config in its fee handler.
    /// @dev Callable only by the factory that initialized the token.
    function registerFees(IRealmFactory.FeeShare[] calldata feeShares) external;

    /// @notice Routes ETH fees to the token's fee handler for the token's fee receiver
    function accrueFees() external payable;

    /// @notice Allows the current owner or whitelisted address to propose a new owner
    function proposeNewOwner(address newOwner) external;

    /// @notice Allows the proposed owner to accept the ownership
    function acceptTokenOwnership() external;

    /// @notice Allows the current owner to permanently renounce ownership
    function renounceOwnership() external;

    ////////////////// VIEW FUNCTIONS ////////////////////

    /// @notice Version of the Realm stack this token belongs to
    function VERSION() external view returns (string memory);

    /// @notice Returns the tax configuration for this token
    /// @return config The complete tax configuration
    /// @dev LEGACY, kept for backwards compatibility — do not remove. Superseded by `getSwapFees`, which
    ///      the current `LivoSwapHook` reads instead. Two live readers still depend on this: off-chain
    ///      integrators, and the PREVIOUSLY-DEPLOYED `LivoSwapHook` (which applies the tax expiry itself
    ///      from the returned rates + synthetic duration) — every token already graduated onto that hook
    ///      would break if this were dropped. New integrations should use `getSwapFees`.
    function getTaxConfig() external view returns (TaxConfig memory config);

    /// @notice Returns the fees `LivoSwapHook` charges right now on a V4 swap in the given direction:
    ///         the always-on LP fee plus the effective tax (non-zero only while the post-graduation tax
    ///         window is open).
    /// @dev Non-taxable tokens return only the LP fee (zero tax); taxable variants override to add the
    ///      windowed/decaying tax for `isBuy`. The hook passes the swap direction so the token reads only
    ///      the relevant side (mirroring `getLaunchpadFees`). Supersedes `getTaxConfig`.
    /// @param isBuy True for a buy (ETH->token), false for a sell (token->ETH).
    function getSwapFees(bool isBuy) external view returns (RealmTradeFees memory);

    /// @notice Returns the pre-graduation fee policy for a given trade.
    /// @dev Read by the launchpad on every pre-graduation buy/sell. `virtual` implementations may
    ///      derive the rate dynamically from the pre-trade context in `trade` (reserves, released
    ///      supply, timestamp); the base implementation returns the statically configured rates.
    ///      The trade's own gross size and the trader identity are deliberately NOT provided (see
    ///      `LaunchpadTrade`) — the fee must be a pure function of pre-trade pool state, otherwise
    ///      the launchpad's forward/inverse quotes (which treat the fee as a constant bps) and the
    ///      view-served quotes (whose `msg.sender` is not the trader) become inconsistent.
    function getLaunchpadFees(LaunchpadTrade calldata trade) external view returns (LaunchpadFees memory);

    /// @notice Contract in charge of handling the graduation process
    /// @dev Must implement IRealmGraduator interface
    function graduator() external view returns (address);

    /// @notice Returns true if already graduated
    function graduated() external view returns (bool);

    /// @notice Timestamp when this token was created (the `initialize` call). Anchors the
    ///         sniper-protection window and, on taxable variants, the creation-anchored tax window.
    function launchTimestamp() external view returns (uint40);

    /// @notice Address where liquidity is deployed after graduation
    function pair() external view returns (address);

    /// @notice The contract address where fees are claimed from
    function feeHandler() external view returns (address);

    /// @notice Owner of the token. The creator unless communityTakeOver takes place
    function owner() external view returns (address);

    /// @notice Address who can accept ownership of the token
    /// @dev It can be address(0) if no owner is proposed
    function proposedOwner() external view returns (address);

    /// @notice Returns the underlying fee receiver addresses and their share in basis points
    /// @dev Sourced from the master fee handler's per-token config: returns every current
    ///      recipient (direct + claimable) with their BPS share. Sum of shares is always 10_000.
    function getFeeReceivers() external view returns (address[] memory receivers, uint256[] memory sharesBps);

    /// @notice Returns the maximum amount of tokens `buyer` can purchase right now on the bonding curve.
    /// @dev Sniper-protected variants enforce per-tx and per-wallet caps during the protection window;
    ///      non-protected tokens always return `type(uint256).max` (no cap).
    /// @dev Integrators: feeding this value directly through `RealmLaunchpad.quoteBuyExactTokens` and
    ///      then `buyTokensWithExactEth` REVERTS with `MaxBuyPerTxExceeded`. The bonding curve isn't
    ///      symmetrically invertible (`forward(inverse(T)) > T`), so target slightly under this value
    ///      (e.g. `maxTokens - maxTokens / 100_000`) and verify with `quoteBuyTokensWithExactEth`
    ///      before broadcasting.
    function maxTokenPurchase(address buyer) external view returns (uint256);
}
