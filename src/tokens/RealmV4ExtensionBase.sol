// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmTaxableTokenUniV4Base} from "src/tokens/RealmTaxableTokenUniV4Base.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {ERC20, IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IRealmDividendSwapRegistry} from "src/interfaces/IRealmDividendSwapRegistry.sol";

/// @title RealmV4ExtensionBase
/// @notice What every Uniswap-V4 token extension is: the token's storage layout, and nothing of the
///         token's behaviour.
///
/// @dev An extension is only ever reached through a `delegatecall` FROM a token, so its own copy of the
///      token's behaviour is dead weight — and, at ~7.4 KB, dead weight it cannot afford: an extension
///      is bound by the same EIP-170 limit as the token it serves. Reverting each entry point below
///      makes the machinery behind it unreachable and the compiler drops it: the transfer hook with its
///      anti-sniper and dividend tracking, the tax-config views and their decay arithmetic, the earnings
///      split and the fee-handler deposit. Measured on the V2 extension: 19,748 -> 12,322 bytes of
///      inherited surface, which is what buys the cold half its room. The reverts are also the honest
///      answer — none of these has anything to act on here.
///
/// @dev Shared by `RealmDividendLogicUniV4` and `RealmEarningsLogicUniV4` so the two cannot drift: a
///      stub missing from one of them would silently relink the whole hot path into it. Adds NO storage
///      of its own, so both extensions derive the token's layout exactly — the property the
///      `delegatecall` depends on, and what `just check-dividend-layout` pins.
abstract contract RealmV4ExtensionBase is RealmTaxableTokenUniV4Base {
    /// @dev An extension never delegates onward — the body it was called for is already inline here —
    ///      so both seams resolve to itself. Present only because the token declares them.
    function dividendLogic() public view virtual override returns (address) {
        return address(this);
    }

    function earningsLogic() public view virtual override returns (address) {
        return address(this);
    }

    //////////////////////// QUOTE HELPERS //////////////////////

    /// @dev Cap on what ONE call may spend out of a buffer.
    ///      - NATIVE keeps the absolute `MAX_EARNINGS_PER_PROCESS` it always had, per chain.
    ///      - An ERC20 quote gets a FRACTION of the buffer instead, because an absolute cap is
    ///        meaningless for a currency nobody calibrated it against: `MAX_EARNINGS_PER_PROCESS` is
    ///        denominated in the chain's native unit, and a creator picks their quote. A fraction needs
    ///        no calibration and does the same job — it bounds what a manipulated block can extract,
    ///        forcing a sandwich to re-pay its pump every block for a geometrically shrinking prize.
    /// @dev Either way this is the SECOND bound, not the first: the keeper gate is what actually stops a
    ///      caller choosing their own floor around their own manipulation.
    function _maxSpend(address quote, uint256 pending) internal pure returns (uint256) {
        if (quote != address(0)) {
            uint256 slice = pending * MAX_QUOTE_SPEND_BPS / 10_000;
            // A buffer too small to slice would otherwise never be spendable at all.
            return slice == 0 ? pending : slice;
        }
        return pending > MAX_EARNINGS_PER_PROCESS ? MAX_EARNINGS_PER_PROCESS : pending;
    }

    /// @dev This token's holdings of `quote`, native or ERC20.
    function _quoteHoldings(address quote) internal view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    /// @dev What of those holdings is committed to someone else.
    function _quoteReserved(address quote) internal view returns (uint256) {
        return quote == address(0) ? _reservedNative() : _reservedAsset(quote);
    }

    /// @dev What a swap actually consumed, measured as `(holdings drop) + (reserve growth)` rather than
    ///      either alone. A buy-back is a SWAP, so the hook's `accrueFees` lands earnings here mid-call:
    ///      that raises the holdings and the buffers together, and only the router's spend moves the two
    ///      apart. Arranged so neither side can underflow — reporting a spend of 0 merely re-earmarks
    ///      the whole amount, which is the safe direction.
    function _spent(address quote, uint256 holdingsBefore, uint256 reservedBefore) internal view returns (uint256) {
        uint256 lhs = holdingsBefore + _quoteReserved(quote);
        uint256 rhs = _quoteHoldings(quote) + reservedBefore;
        return lhs > rhs ? lhs - rhs : 0;
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

    /// @dev Only here because `IRealmTaxableToken` declares it. The storage every entry point touches
    ///      belongs to the token that `delegatecall`s in, so there is nothing here to initialize.
    function initialize(IRealmToken.InitializeParams memory, TaxConfigs memory, AntiSniperConfigs memory)
        external
        pure
    {
        revert NotAToken();
    }

    /// @dev The base token's own entry point; same reasoning as the 3-arg one above.
    function initialize(IRealmToken.InitializeParams memory, AntiSniperConfigs memory) external pure override {
        revert NotAToken();
    }

    /// @dev With every mint/transfer entry point stubbed, nothing reaches `_update` and the compiler drops
    ///      the whole transfer hook (`SniperProtection`, dividend share tracking) — the single largest saving.
    function transfer(address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert NotAToken();
    }

    function transferFrom(address, address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert NotAToken();
    }

    /// @dev Stubbed for the same reason `transfer` is — `_burn` reaches `_update` too, and `processBurn`
    ///      above deliberately routes its burn through an EXTERNAL call to the token's own `burn()` so
    ///      that path stays on the side that already carries the hot-path bytecode.
    function burn(uint256) public pure override {
        revert NotAToken();
    }

    function burnFrom(address, uint256) public pure override {
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

    function getLaunchpadFees(IRealmToken.LaunchpadTrade calldata)
        external
        pure
        override
        returns (IRealmToken.LaunchpadFees memory)
    {
        revert NotAToken();
    }

    function getTaxConfig() external pure override returns (TaxConfig memory) {
        revert NotAToken();
    }

    function getSwapFees(bool) external pure override returns (IRealmToken.RealmTradeFees memory) {
        revert NotAToken();
    }

    function initializeEarningsAllocation(uint16, uint16, uint16) external pure override {
        revert NotAToken();
    }
}
