// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {Clones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @title Launchpad pre-graduation fee routing — LP-fee split + creator tax
/// @notice The launchpad reads `getLaunchpadFees` per trade. The LP fee is split treasury/creator by
///         `treasuryShareBps`; the tax goes 100% to the creator. Events (`LpFeesAccrued`,
///         `CreatorTaxesAccrued`) mirror the post-graduation `RealmSwapHook` for accounting parity.
contract LaunchpadFeeSplitTest is LaunchpadBaseTestsWithUniv2Graduator {
    event LpFeesAccrued(address indexed token, uint256 creatorShare, uint256 treasuryShare);
    event CreatorTaxesAccrued(address indexed token, uint256 amount);

    RealmToken internal feeToken;

    /// @dev A tax window long enough to stay active for the duration of every trade in a test.
    uint32 internal constant LONG_TAX_WINDOW = uint32(3650 days);

    /// @dev Creates a fully-wired, tradeable taxable-V2 token with a custom fee config and a long tax
    ///      window: clone + initialize + registerFees(creator) + launchToken (pranked as a whitelisted
    ///      factory). A taxable token is used so the launchpad's tax routing (creation-anchored) can be
    ///      exercised; the tax rate flows through `TaxConfigInit`, the LP fee through `InitializeParams`.
    function _wireToken(uint16 lpFee, uint16 treasuryShare, uint16 taxBuy, uint16 taxSell)
        internal
        returns (RealmToken t)
    {
        return _wireTokenWindow(lpFee, treasuryShare, taxBuy, taxSell, LONG_TAX_WINDOW);
    }

    function _wireTokenWindow(uint16 lpFee, uint16 treasuryShare, uint16 taxBuy, uint16 taxSell, uint32 window)
        internal
        returns (RealmToken t)
    {
        t = RealmToken(payable(Clones.clone(address(realmTaxTokenV2))));
        RealmTaxableTokenUniV2(payable(address(t)))
            .initialize(
                IRealmToken.InitializeParams({
                    name: "SplitToken",
                    symbol: "SPLIT",
                    tokenOwner: creator,
                    graduator: address(graduatorV2),
                    launchpad: address(launchpad),
                    feeHandler: address(feeHandler),
                    vaultAllocation: 0,
                    lpFeeBps: lpFee,
                    treasuryShareBps: treasuryShare,
                    swapLpFeeBps: 0
                }),
                TaxConfigs({
                    buyTaxBps: taxBuy,
                    sellTaxBps: taxSell,
                    taxDurationSeconds: window,
                    startTaxFromLaunch: true,
                    buyTaxDecayStartBps: 0,
                    sellTaxDecayStartBps: 0,
                    taxDecayDuration: 0
                }),
                _emptyAntiSniperCfg()
            );
        // Register the creator as the sole (claimable) fee receiver so creator-share routing works.
        t.registerFees(_fs(creator));

        vm.prank(address(factoryV2Unified));
        launchpad.launchToken(address(t), IRealmBondingCurve(address(bondingCurve)));
    }

    function _buy(RealmToken t, uint256 value) internal returns (uint256) {
        vm.deal(buyer, value);
        vm.prank(buyer);
        return launchpad.buyTokensWithExactEth{value: value}(address(t), 0, DEADLINE);
    }

    function _creatorClaimable(RealmToken t) internal view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        return feeHandler.getClaimable(tokens, creator)[0];
    }

    /// @dev when treasuryShareBps is 100% and there's no tax, then the whole LP fee goes to treasury
    function test_buy_fullTreasuryShare_noTax() public {
        feeToken = _wireToken(100, 10_000, 0, 0);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;

        _buy(feeToken, value);

        assertEq(treasury.balance - t0, lpFee, "treasury gets full LP fee");
        assertEq(_creatorClaimable(feeToken), 0, "creator zero");
    }

    /// @dev when treasuryShareBps is 40% and there's no tax, then the LP fee splits 40/60 and emits LpFeesAccrued
    function test_buy_partialShare_noTax() public {
        feeToken = _wireToken(100, 4_000, 0, 0);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 treasuryShare = lpFee * 4_000 / 10_000;
        uint256 creatorShare = lpFee - treasuryShare;

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit LpFeesAccrued(address(feeToken), creatorShare, treasuryShare);
        _buy(feeToken, value);

        assertEq(treasury.balance - t0, treasuryShare, "treasury share");
        assertEq(_creatorClaimable(feeToken), creatorShare, "creator share");
    }

    /// @dev when a tax is configured, then it goes 100% to the creator and emits CreatorTaxesAccrued
    function test_buy_withTax_taxAllToCreator() public {
        // 1% LP (100% treasury) + 2% creator tax
        feeToken = _wireToken(100, 10_000, 200, 200);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 tax = value * 200 / 10_000;

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit CreatorTaxesAccrued(address(feeToken), tax);
        _buy(feeToken, value);

        assertEq(treasury.balance - t0, lpFee, "treasury gets LP fee");
        assertEq(_creatorClaimable(feeToken), tax, "creator gets tax");
    }

    /// @dev when both LP split and tax apply, then creator gets LP-creator-share + full tax
    function test_buy_splitPlusTax() public {
        feeToken = _wireToken(100, 4_000, 200, 200);
        uint256 t0 = treasury.balance;
        uint256 value = 1 ether;
        uint256 lpFee = value * 100 / 10_000;
        uint256 tax = value * 200 / 10_000;
        uint256 treasuryShare = lpFee * 4_000 / 10_000;
        uint256 creatorShare = lpFee - treasuryShare;

        _buy(feeToken, value);

        assertEq(treasury.balance - t0, treasuryShare, "treasury share");
        assertEq(_creatorClaimable(feeToken), creatorShare + tax, "creator gets lp creator share + tax");
    }

    /// @dev when the creation-anchored tax window expires between trades, then the launchpad stops
    ///      charging the tax — the per-trade `getLaunchpadFees` read reflects the window dynamically
    function test_buy_taxExpiresBetweenTrades() public {
        // 1% LP (100% treasury) + 2% creator tax, with a 1-hour window
        feeToken = _wireTokenWindow(100, 10_000, 200, 200, uint32(1 hours));
        uint256 value = 1 ether;
        uint256 tax = value * 200 / 10_000;

        // within the window: tax routed to the creator
        _buy(feeToken, value);
        assertEq(_creatorClaimable(feeToken), tax, "tax charged within window");

        // warp past the creation-anchored window
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 creatorBefore = _creatorClaimable(feeToken);
        uint256 t1 = treasury.balance;
        _buy(feeToken, value);
        assertEq(_creatorClaimable(feeToken), creatorBefore, "no tax after window expiry");
        assertEq(treasury.balance - t1, value * 100 / 10_000, "LP fee still charged after expiry");
    }

    /// @dev when the total fee (LP + tax) exceeds the launchpad's per-trade backstop, the trade reverts
    function test_buy_totalFeeAboveCap_reverts() public {
        // buy total = 2000 + 600 = 2600 > MAX_TRADING_FEE_BPS (2500). This config is only reachable by
        // wiring the token directly; the factory caps real tokens far below this backstop.
        feeToken = _wireToken(2000, 10_000, 600, 0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(RealmLaunchpad.InvalidLaunchpadFee.selector);
        launchpad.buyTokensWithExactEth{value: 1 ether}(address(feeToken), 0, DEADLINE);
    }
}
