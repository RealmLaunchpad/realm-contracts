// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigInit} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";

/// @notice Dispatch + field-readback tests for `RealmFactoryUniV4Unified`. The unified factory
///         dispatches between four token implementations based on whether `taxCfg` and
///         `antiSniperCfg` are configured. These tests lock in:
///         (1) `previewTokenImplementation(...)` returns the same address that `createToken`
///         actually clones from for each of the 4 dispatch combos — load-bearing for frontend
///         salt mining; and (2) the configs are correctly propagated from the factory to the
///         cloned token's storage.
contract RealmFactoryUniV4UnifiedTests is LaunchpadBaseTestsWithUniv4Graduator {
    // ───────────── Dispatch — preview returns correct impl per combo ─────────────

    function test_dispatch_base_returnsBaseImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(realmToken));
    }

    function test_dispatch_antiSniper_returnsAntiSniperImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(realmTokenSniper));
    }

    function test_dispatch_tax_returnsTaxImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_taxCfg(0, 400, uint32(7 days))), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(realmTaxToken));
    }

    function test_dispatch_taxAntiSniper_returnsTaxAntiSniperImpl() public view {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_taxCfg(0, 400, uint32(7 days))), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(realmTaxTokenSniper));
    }

    // ───────────── Dispatch — preview matches deployed for each combo ─────────────

    function test_createToken_dispatchMatchesPreview_base() public {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = _predictToken(address(factoryV4Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_antiSniper() public {
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = _predictToken(address(factoryV4Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_tax() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = _predictToken(address(factoryV4Unified), impl, creator, salt);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_taxAntiSniper() public {
        TaxConfigInit memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _defaultAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);
        address expected = _predictToken(address(factoryV4Unified), impl, creator, salt);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _defaultAntiSniperCfg());

        assertEq(token, expected);
    }

    // ───────────── Config field readback ─────────────

    function test_createToken_antiSniper_configFieldsStoredOnToken() public {
        address[] memory wl = new address[](2);
        wl[0] = alice;
        wl[1] = bob;
        AntiSniperConfigs memory snipCfg = _antiSniperCfg(50, 100, 30 minutes, wl);

        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, _emptyTaxCfg(), snipCfg);

        RealmToken t = RealmToken(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 30 minutes);
        assertTrue(t.sniperBypass(alice));
        assertTrue(t.sniperBypass(bob));
        assertFalse(t.sniperBypass(creator));
    }

    function test_createToken_tax_configFieldsStoredOnToken() public {
        TaxConfigInit memory cfg = _taxCfg(150, 250, uint32(3 days));
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        RealmTaxableTokenUniV4 t = RealmTaxableTokenUniV4(payable(token));
        assertEq(t.buyTaxBps(), 150);
        assertEq(t.sellTaxBps(), 250);
        assertEq(uint256(t.taxDurationSeconds()), 3 days);
    }

    function test_createToken_taxAntiSniper_bothFieldsStored() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;
        TaxConfigInit memory taxCfg = _taxCfg(100, 200, uint32(1 days));
        AntiSniperConfigs memory snipCfg = _antiSniperCfg(25, 100, 2 hours, wl);

        address impl = factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(taxCfg), snipCfg);
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token = factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, taxCfg, snipCfg);

        RealmTaxableTokenUniV4 t = RealmTaxableTokenUniV4(payable(token));
        assertEq(t.buyTaxBps(), 100);
        assertEq(t.sellTaxBps(), 200);
        assertEq(uint256(t.taxDurationSeconds()), 1 days);
        assertEq(t.maxBuyPerTxBps(), 25);
        assertEq(t.maxWalletBps(), 100);
        assertEq(uint256(t.protectionWindowSeconds()), 2 hours);
        assertTrue(t.sniperBypass(alice));
    }

    // ───────────── Renounce ownership ─────────────

    function test_createToken_renounceOwnership_setsOwnerToZero_taxVariant() public {
        TaxConfigInit memory cfg = _taxCfg(0, 400, uint32(14 days));
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), true, cfg, _emptyAntiSniperCfg());

        assertEq(RealmTaxableTokenUniV4(payable(token)).owner(), address(0));
    }

    function test_createToken_keepOwnership_setsOwnerToCaller_taxVariant() public {
        TaxConfigInit memory cfg = _taxCfg(0, 400, uint32(14 days));
        address impl =
            factoryV4Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(cfg), _emptyAntiSniperCfg());
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), impl);

        vm.prank(creator);
        address token =
            factoryV4Unified.createToken("T", "T", salt, _fs(creator), _noSs(), false, cfg, _emptyAntiSniperCfg());

        assertEq(RealmTaxableTokenUniV4(payable(token)).owner(), creator);
    }

    // ───────────── Tax / anti-sniper sentinel validation ─────────────

    function test_preview_revertsOnDisabledTaxWithNonZeroBps() public {
        vm.expectRevert(IRealmFactory.InvalidTaxConfig.selector);
        factoryV4Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_taxCfg(100, 0, 0)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnDisabledTaxWithNonZeroBps() public {
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxConfig.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(100, 0, 0), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnTaxDurationWithoutBps() public {
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxConfig.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 0, uint32(1 days)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_revertsOnDisabledAntiSniperWithNonZeroFields() public {
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 0, 0, new address[](0));

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidAntiSniperConfig.selector);
        factoryV4Unified.createToken("T", "T", "0x12", _fs(creator), _noSs(), false, _emptyTaxCfg(), cfg);
    }

    function test_createToken_revertsOnInvalidTaxBps() public {
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(0, 401, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }

    // ───────────── Aggregate fee cap: LP fee + tax never exceeds 5% ─────────────
    //
    // The fee a swapper pays is LP fee + tax. The positional overload always uses the 1% LP hook,
    // so tax is capped at 4%. The struct overload exposes the 0.5% LP hook, where tax can go to 4.5%.

    function test_createToken_positional_succeedsAtFourPercentTax() public {
        // 1% LP + 4% tax (buy and sell) == 5% total, the boundary.
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));
        vm.prank(creator);
        factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), false, _taxCfg(400, 400, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_positional_revertsWhenBuyTaxExceedsFourPercent() public {
        // 1% LP + 4.01% buy tax == 5.01% total > 5%.
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV4Unified.createToken(
            "T", "T", "0x12", _fs(creator), _noSs(), false, _taxCfg(401, 0, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }

    function test_createToken_struct_halfPercentLp_succeedsAtFourPointFivePercentTax() public {
        // 0.5% LP + 4.5% tax (buy and sell) == 5% total, the boundary.
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "T", symbol: "T", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 50});

        vm.prank(creator);
        factoryV4Unified.createToken(
            setup,
            _toCfgs(_taxCfg(450, 450, uint32(14 days))),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_createToken_pregradLpFee_isOnePercent_regardlessOfHookFee() public {
        // A token that selects the 0.5% post-graduation hook still pays 1% LP on the bonding curve:
        // the pre-graduation launchpad LP fee is a fixed launchpad policy, decoupled from the hook fee.
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "T", symbol: "T", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 50});

        // The post-graduation marker still reflects the chosen 0.5% hook fee.
        vm.expectEmit(false, false, false, true);
        emit IRealmFactory.LpFeeBpsSet(address(0), 50);
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            setup,
            _toCfgs(_emptyTaxCfg()),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );

        // The pre-graduation LP fee the launchpad reads each trade is 1%, not the 0.5% hook fee.
        IRealmToken.LaunchpadFees memory buyFees = RealmToken(token)
            .getLaunchpadFees(IRealmToken.LaunchpadTrade({isBuy: true, ethReserves: 0, releasedSupply: 0}));
        assertEq(buyFees.lpFeeBps, 100, "pre-grad LP fee fixed at 1%");
        assertEq(uint256(RealmToken(token).lpFeeBps()), 100, "token stores 1% pre-grad LP fee");
    }

    function test_createToken_struct_halfPercentLp_revertsAboveFourPointFivePercentTax() public {
        // 0.5% LP + 4.51% sell tax == 5.01% total > 5%.
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "T", symbol: "T", salt: "0x12", feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 50});

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV4Unified.createToken(
            setup,
            _toCfgs(_taxCfg(0, 451, uint32(14 days))),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_createToken_struct_onePercentLp_revertsAboveFourPercentTax() public {
        // 1% LP + 4.01% buy tax == 5.01% total > 5%, even though 4.01% is below the absolute cap.
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "T", symbol: "T", salt: "0x12", feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV4Unified.createToken(
            setup,
            _toCfgs(_taxCfg(401, 0, uint32(14 days))),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
    }

    function test_createToken_revertsOnInvalidTaxDuration() public {
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        factoryV4Unified.createToken(
            "T",
            "T",
            "0x12",
            _fs(alice),
            _noSs(),
            true,
            _taxCfg(0, 400, uint32(120 * 365 days + 1)),
            _emptyAntiSniperCfg()
        );
    }

    // ───────────── Extended durations — no restrictions beyond the 120-year cap ─────────────
    //
    // Any deployer can pick any tax duration up to MAX_TAX_DURATION_SECONDS (120 years, an
    // overflow-prevention bound). Fee-receiver identity and ownership are unrestricted at any
    // duration.

    function test_createToken_succeedsOnExtendedTaxWhenFeeReceiverIsDeployer() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), true, _taxCfg(0, 400, uint32(365 days + 1)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(RealmTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 365 days + 1);
    }

    function test_createToken_succeedsOnExtendedTaxWithMultipleReceivers() public {
        IRealmFactory.FeeShare[] memory two = new IRealmFactory.FeeShare[](2);
        two[0] = IRealmFactory.FeeShare({account: alice, shares: 5_000, directFeesEnabled: false});
        two[1] = IRealmFactory.FeeShare({account: bob, shares: 5_000, directFeesEnabled: false});

        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, two, _noSs(), true, _taxCfg(0, 400, uint32(365 days + 1)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(RealmTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 365 days + 1);
    }

    function test_createToken_succeedsOnExtendedTaxWhenOwnershipNotRenounced() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(alice), _noSs(), false, _taxCfg(0, 400, uint32(365 days + 1)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(RealmTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 365 days + 1);
        assertEq(RealmTaxableTokenUniV4(payable(token)).owner(), creator);
    }

    function test_createToken_allowsExtendedTaxRenounced() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(alice), _noSs(), true, _taxCfg(0, 400, uint32(365 days + 1)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(RealmTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 365 days + 1);
        assertEq(RealmTaxableTokenUniV4(payable(token)).owner(), address(0));
    }

    function test_createToken_allowsMaxDuration() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            "T", "T", salt, _fs(alice), _noSs(), true, _taxCfg(0, 400, uint32(120 * 365 days)), _emptyAntiSniperCfg()
        );

        assertEq(uint256(RealmTaxableTokenUniV4(payable(token)).taxDurationSeconds()), 120 * 365 days);
    }

    function test_preview_returnsTaxImplForExtendedTax() public {
        vm.prank(creator);
        address impl = factoryV4Unified.previewTokenImplementation(
            _fs(alice), _noSs(), _toCfgs(_taxCfg(0, 400, uint32(365 days + 1))), _emptyAntiSniperCfg()
        );

        assertEq(impl, address(realmTaxToken));
    }

    // ───────────── InvalidTokenAddress on tax dispatch path ─────────────

    function test_createToken_revertsOnInvalidTokenAddress_taxVariant() public {
        // Find a salt that does NOT yield a 0x1110-suffixed address for the tax impl.
        bytes32 badSalt;
        for (uint256 i = 0;; i++) {
            bytes32 s = bytes32(i);
            address predicted = _predictToken(address(factoryV4Unified), address(realmTaxToken), creator, s);
            if (uint16(uint160(predicted)) != 0x1110) {
                badSalt = s;
                break;
            }
        }

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTokenAddress.selector);
        factoryV4Unified.createToken(
            "T", "T", badSalt, _fs(creator), _noSs(), false, _taxCfg(0, 400, uint32(14 days)), _emptyAntiSniperCfg()
        );
    }

    // ───────────── Referral overload ─────────────

    function test_createToken_referral_emitsTokenReferral() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "R", symbol: "R", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
        address referral = makeAddr("relayer");
        address expected = _predictToken(address(factoryV4Unified), address(realmToken), creator, salt);

        vm.expectEmit(true, true, false, false);
        emit IRealmFactory.TokenReferral(expected, referral);
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            setup,
            _toCfgs(_emptyTaxCfg()),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            referral
        );
        assertEq(token, expected);
    }

    /// @dev A zero referral emits no `TokenReferral` (the common no-referral deploy stays quiet).
    function test_createToken_zeroReferral_noTokenReferralEvent() public {
        bytes32 salt = _nextValidSalt(address(factoryV4Unified), address(realmToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "R", symbol: "R", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        RealmFactoryUniV4Unified.UniV4Configs memory cfg =
            RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});

        vm.recordLogs();
        vm.prank(creator);
        factoryV4Unified.createToken(
            setup,
            _toCfgs(_emptyTaxCfg()),
            cfg,
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("TokenReferral(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "no TokenReferral for zero referral");
        }
    }
}
