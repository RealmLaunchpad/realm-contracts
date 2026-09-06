// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoTaxableTokenUniV2Base} from "src/tokens/LivoTaxableTokenUniV2Base.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {TaxConfigs} from "src/interfaces/ILivoTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";

/// @title LivoDividendLogicUniV2
/// @notice The dividend extension `LivoTaxableTokenUniV2` `delegatecall`s its out-of-band entry
///         points into: the round machinery, the native -> payout-asset conversion, and the per-holder
///         push. Deployed once, by the token implementation's own constructor.
/// @dev It shares `LivoTaxableTokenUniV2Base` with the token and adds NO state of its own, so the
///      compiler derives the same storage layout for both — the property the delegatecall depends on.
///      Pinned by `just check-dividend-layout`.
contract LivoDividendLogicUniV2 is LivoTaxableTokenUniV2Base, DividendDistributionLogic {
    /// @dev Funds a self-token payout straight out of its token buffer — no conversion, no slippage,
    ///      and so no way for it to fail. Its threshold is `SWAP_THRESHOLD` (the same 0.05%-of-supply
    ///      size the swap-back amortises against) because the buffer is denominated in tokens, not
    ///      native. Every other payout asset is native-buffered and goes through the base.
    /// @dev Staleness is the threshold's ONLY bypass, for the reason the base spells out: a residual
    ///      below the threshold on a token nobody trades would otherwise strand forever.
    /// @dev A self-token payout is only ever configured as the SOLE asset, so `i` is 0 whenever this
    ///      branch is taken; the index is still threaded through so the base's asset-agnostic path stays
    ///      the one that decides.
    function _fundDividends(uint256 i, uint256 minOut) internal override returns (FundOutcome, uint256, uint256) {
        if (dividendAssets[i].token != address(this)) return super._fundDividends(i, minOut);

        uint256 buffered = dividendPendingTokens;
        if (buffered == 0) return (FundOutcome.NotReady, 0, 0);
        if (buffered < SWAP_THRESHOLD && !dividendsStale(i)) return (FundOutcome.NotReady, 0, 0);

        dividendPendingTokens = 0;
        return (FundOutcome.Funded, 0, buffered);
    }

    /// @dev Names the winner between the venue base's override and the `DividendDistribution` default
    ///      that reaches this contract through the cold-half branch. The venue base is what the token
    ///      uses; nothing here calls it, but a silently wrong answer is not worth leaving available.
    function _isTokenSpaceDividendAsset(address asset)
        internal
        view
        override(LivoTaxableTokenUniV2Base, DividendDistribution)
        returns (bool)
    {
        return LivoTaxableTokenUniV2Base._isTokenSpaceDividendAsset(asset);
    }

    /// @notice Creation-time dividend configuration, executed here on the token's storage. Guarded by
    ///         the transient `tokenFactory`, which the `delegatecall` shares with the token.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address _dividendToken
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            (address[] memory tokens, uint16[] memory weights) = _soleAssetSet(_dividendToken);
            dividendAssetCount = _initializeDividends(tokens, weights);
            hasDividends = true;
        }
    }

    /// @notice Multi-asset creation-time dividend configuration. See
    ///         `LivoTaxableToken.initializeEarningsAllocation(uint16,uint16,uint16,address[],uint16[])`.
    function initializeEarningsAllocation(
        uint16 _burnBps,
        uint16 _dividendsBps,
        uint16 _liquidityBps,
        address[] calldata _dividendTokens,
        uint16[] calldata _dividendWeightsBps
    ) external override {
        require(msg.sender == tokenFactory, Unauthorized());
        _initializeEarningsAllocation(_burnBps, _dividendsBps, _liquidityBps);
        if (_dividendsBps != 0) {
            dividendAssetCount = _initializeDividends(_dividendTokens, _dividendWeightsBps);
            hasDividends = true;
        }
    }

    ////////////////// NOT A TOKEN //////////////////
    // An extension is only ever reached through a `delegatecall` from a token, so its own copy of the
    // token's behaviour is dead weight — and, at ~7.4 KB, dead weight it cannot afford: the extension is
    // bound by the same EIP-170 limit as the token it serves. Reverting each entry point makes the
    // machinery behind it unreachable and the compiler drops it: the transfer hook with its anti-sniper
    // and dividend tracking, the tax-config views and their decay arithmetic, the earnings split and the
    // fee-handler deposit. Measured on the V2 extension: 19,748 -> 12,322 bytes of inherited surface,
    // which is what buys the cold half its room. The reverts are also the honest answer — none of these
    // has anything to act on here.

    /// @dev Kills the transfer hook, and with it `SniperProtection` and the dividend share tracking —
    ///      the single largest saving. An extension's own balances are never moved.
    function _update(address, address, uint256) internal pure override {
        revert NotAToken();
    }

    /// @dev Only here because `ILivoTaxableToken` declares it. The storage every entry point touches
    ///      belongs to the token that `delegatecall`s in, so there is nothing here to initialize.
    function initialize(ILivoToken.InitializeParams memory, TaxConfigs memory, AntiSniperConfigs memory) external pure {
        revert NotAToken();
    }

    function markGraduated() external pure override {
        revert NotAToken();
    }

    function rescueTokens(address) external pure override {
        revert NotAToken();
    }

    function setTaxBps(uint16, uint16) external pure override {
        revert NotAToken();
    }

    function accrueFees() external payable override {
        revert NotAToken();
    }

    /// @dev The second entry point into the earnings split, stubbed for the same reason `accrueFees` is:
    ///      an extension holds no balance, so it has no stray native — and leaving it live would link
    ///      `_allocateEthEarnings` and everything under it back into this contract's bytecode.
    function sweepStrayEth() external pure override {
        revert NotAToken();
    }

    function getLaunchpadFees(ILivoToken.LaunchpadTrade calldata)
        external
        pure
        override
        returns (ILivoToken.LaunchpadFees memory)
    {
        revert NotAToken();
    }

    function getTaxConfig() external pure override returns (TaxConfig memory) {
        revert NotAToken();
    }

    function getSwapFees(bool) external pure override returns (ILivoToken.LivoTradeFees memory) {
        revert NotAToken();
    }

    function initializeEarningsAllocation(uint16, uint16, uint16) external pure override {
        revert NotAToken();
    }

    /// @dev The cold half is already inline here, so the token stubs this contract inherits would
    ///      `delegatecall` into itself if they were ever reached. They are not: `DividendDistributionLogic`
    ///      carries the real bodies.
    function dividendLogic() public view override returns (address) {
        return address(this);
    }
}
