// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Dev-supplied anti-sniper config, passed to the token's initializer. Immutable once set.
struct AntiSniperConfigs {
    /// @notice Max tokens per tx, in basis points of TOTAL_SUPPLY. Range: 10..300 (0.1%..3%).
    uint16 maxBuyPerTxBps;
    /// @notice Max wallet balance, in basis points of TOTAL_SUPPLY. Range: 10..300 (0.1%..3%).
    uint16 maxWalletBps;
    /// @notice Duration the protection remains active after token creation. Range: 1 minute..24h.
    uint40 protectionWindowSeconds;
    /// @notice Addresses that bypass the caps during the protection window.
    address[] whitelist;
}

/// @title SniperProtection
/// @notice Anti-sniper mixin active for a window post-launch and disabled on graduation.
///         Per-wallet cap fires on every incoming transfer (blocks sybil → consolidate);
///         per-tx cap fires only on curve buys.
/// @dev Inheriting tokens call `_initializeSniperProtection(cfg, launchTimestamp)` in their
///      initializer and `_checkSniperProtection(...)` at the top of `_update`.
abstract contract SniperProtection {
    /// @notice Min allowed value for max-per-tx and max-wallet caps, in bps.
    uint16 public constant ANTI_SNIPER_MIN_BPS = 10; // 0.1%

    /// @notice Max allowed value for max-per-tx and max-wallet caps, in bps.
    uint16 public constant ANTI_SNIPER_MAX_BPS = 300; // 3%

    /// @notice Min allowed protection window duration.
    uint40 public constant ANTI_SNIPER_MIN_WINDOW = 1 minutes;

    /// @notice Max allowed protection window duration.
    uint40 public constant ANTI_SNIPER_MAX_WINDOW = 1 days;

    /// @notice Max whitelist entries (includes the deployer if the dev opts to add it).
    uint256 public constant MAX_WHITELISTED = 50;

    /// @dev Mirrors `RealmToken.TOTAL_SUPPLY`; renamed to avoid a multiple-inheritance collision.
    /// @dev Caps are intentionally measured against the fixed total supply, NOT a token's
    ///      circulating float. Creator-vault tokens lock part of the supply, so a given bps is a
    ///      slightly larger share of their (smaller) tradable float — by design, not a bug.
    uint256 internal constant _ANTI_SNIPER_TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Max tokens per tx during the protection window, in bps of TOTAL_SUPPLY.
    uint16 public maxBuyPerTxBps;

    /// @notice Max wallet balance during the protection window, in bps of TOTAL_SUPPLY.
    uint16 public maxWalletBps;

    /// @notice Duration the protection remains active after the host token's `launchTimestamp`.
    uint40 public protectionWindowSeconds;

    /// @notice Absolute timestamp at which the protection window closes: the host token's
    ///         `launchTimestamp + protectionWindowSeconds`, cached at init so the hot-path window
    ///         check is a single SLOAD from this slot (no read of the base `launchTimestamp` slot).
    ///         Reads 0 until `_initializeSniperProtection` runs (after the initial mint), so the
    ///         mint observes a closed window and stays uncapped. Packs into this slot.
    uint40 public protectionWindowEnd;

    /// @notice Dev-supplied addresses that bypass the caps during the protection window.
    mapping(address account => bool isWhitelisted) public sniperBypass;

    error MaxBuyPerTxExceeded();
    error MaxWalletExceeded();
    error MaxBuyPerTxBpsTooLow();
    error MaxBuyPerTxBpsTooHigh();
    error MaxWalletBpsTooLow();
    error MaxWalletBpsTooHigh();
    error MaxBuyPerTxBpsExceedsMaxWalletBps();
    error ProtectionWindowTooShort();
    error ProtectionWindowTooLong();
    error WhitelistTooLong();

    event SniperProtectionInitialized(
        uint16 maxBuyPerTxBps, uint16 maxWalletBps, uint40 protectionWindowSeconds, address[] whitelist
    );

    /// @dev Validates configs and records the whitelist. `launchTimestamp` is the host token's
    ///      creation timestamp (set by `RealmToken._initializeRealmToken`, which runs first); it is
    ///      cached here as the absolute `protectionWindowEnd` so the check functions below read a
    ///      single slot instead of also touching the base `launchTimestamp` slot.
    function _initializeSniperProtection(AntiSniperConfigs memory cfg, uint40 launchTimestamp) internal {
        require(cfg.maxBuyPerTxBps >= ANTI_SNIPER_MIN_BPS, MaxBuyPerTxBpsTooLow());
        require(cfg.maxBuyPerTxBps <= ANTI_SNIPER_MAX_BPS, MaxBuyPerTxBpsTooHigh());
        require(cfg.maxWalletBps >= ANTI_SNIPER_MIN_BPS, MaxWalletBpsTooLow());
        require(cfg.maxWalletBps <= ANTI_SNIPER_MAX_BPS, MaxWalletBpsTooHigh());
        require(cfg.maxBuyPerTxBps <= cfg.maxWalletBps, MaxBuyPerTxBpsExceedsMaxWalletBps());
        require(cfg.protectionWindowSeconds >= ANTI_SNIPER_MIN_WINDOW, ProtectionWindowTooShort());
        require(cfg.protectionWindowSeconds <= ANTI_SNIPER_MAX_WINDOW, ProtectionWindowTooLong());
        require(cfg.whitelist.length <= MAX_WHITELISTED, WhitelistTooLong());

        maxBuyPerTxBps = cfg.maxBuyPerTxBps;
        maxWalletBps = cfg.maxWalletBps;
        protectionWindowSeconds = cfg.protectionWindowSeconds;
        protectionWindowEnd = launchTimestamp + cfg.protectionWindowSeconds;

        uint256 n = cfg.whitelist.length;
        for (uint256 i; i < n; ++i) {
            sniperBypass[cfg.whitelist[i]] = true;
        }

        emit SniperProtectionInitialized(
            cfg.maxBuyPerTxBps, cfg.maxWalletBps, cfg.protectionWindowSeconds, cfg.whitelist
        );
    }

    /// @param factoryAddr Host token's `tokenFactory` transient slot; non-zero only inside the
    ///        deploy tx (the only window in which the launchpad → factory → supplyShares
    ///        deployer-buy hops happen). Reads `address(0)` afterwards.
    /// @param toBalance Recipient's balance BEFORE this transfer (`balanceOf(to)`).
    /// @dev Bypasses (any one short-circuits the check):
    ///        - `to == launchpadAddr`: sell back to the curve.
    ///        - `to == factoryAddr`: launchpad → factory deployer-buy hop.
    ///        - `to == graduatorAddr`: launchpad → graduator graduation hop (~80% of supply,
    ///          pre-`markGraduated()`; would otherwise revert).
    ///        - `from == factoryAddr`: factory → supplyShare recipients during the deployer-buy
    ///          split. Dev-configured, may legitimately exceed the per-wallet cap.
    ///        - `sniperBypass[to]`: dev-supplied whitelist.
    ///      `from == graduatorAddr` is intentionally NOT exempt: graduator outgoing transfers
    ///      happen post-`markGraduated()`, which the caller's `!graduated` gate already skips.
    /// @dev Mints (`from == 0`) only happen during `_initializeRealmToken`, before
    ///      `_initializeSniperProtection` runs, so `protectionWindowEnd == 0` and the window
    ///      early-return covers them. Burns (`to == 0`) are rejected by OZ ERC20 v5 before `_update`.
    ///      Launchpad fees are ignored in the cap math.
    function _checkSniperProtection(
        address from,
        address to,
        uint256 amount,
        address launchpadAddr,
        address factoryAddr,
        address graduatorAddr,
        uint256 toBalance
    ) internal view {
        if (block.timestamp >= protectionWindowEnd) return;

        // sells back to the curve
        if (to == launchpadAddr) return;

        // token creation / graduation hops
        if (to == factoryAddr) return;
        if (to == graduatorAddr) return;
        if (from == factoryAddr) return;

        if (sniperBypass[to]) return;

        // Per-tx cap: curve buys only. Checked before the per-wallet cap so an oversized buy
        // reverts with the more specific `MaxBuyPerTxExceeded`.
        if (from == launchpadAddr) {
            uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
            require(amount <= maxTx, MaxBuyPerTxExceeded());
        }

        uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
        require(toBalance + amount <= maxWallet, MaxWalletExceeded());
    }

    /// @notice Largest token amount `buyer` may receive from the launchpad right now without
    ///         tripping the sniper caps. Returns `type(uint256).max` when no cap applies
    ///         (window closed, graduated, or whitelisted).
    /// @dev Doesn't model launchpad-side limits; callers should `min()` with
    ///      `RealmLaunchpad.getMaxEthToSpend` converted via the bonding curve.
    /// @dev Factory/graduator/launchpad bypasses from `_checkSniperProtection` are NOT mirrored
    ///      here: none of those addresses ever buys via `buyTokensWithExactEth`.
    function _maxTokenPurchase(address buyer, uint256 buyerBalance, bool graduated) internal view returns (uint256) {
        if (graduated) return type(uint256).max;
        if (sniperBypass[buyer]) return type(uint256).max;
        if (block.timestamp >= protectionWindowEnd) return type(uint256).max;

        uint256 maxTx = (_ANTI_SNIPER_TOTAL_SUPPLY * maxBuyPerTxBps) / 10_000;
        uint256 maxWallet = (_ANTI_SNIPER_TOTAL_SUPPLY * maxWalletBps) / 10_000;
        uint256 walletRemaining = buyerBalance >= maxWallet ? 0 : maxWallet - buyerBalance;

        return maxTx < walletRemaining ? maxTx : walletRemaining;
    }
}
