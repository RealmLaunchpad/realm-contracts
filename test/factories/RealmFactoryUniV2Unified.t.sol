// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";

/// @notice Dispatch + field-readback tests for `RealmFactoryUniV2Unified`. These non-tax tests lock
///         in dispatch between the base and anti-sniper implementations based on
///         `antiSniperCfg.protectionWindowSeconds != 0`:
///         (1) `previewTokenImplementation(...)` returns the same address that `createToken`
///         actually clones from — load-bearing for frontend salt mining; and (2) the configs
///         are correctly propagated from the factory to the cloned token's storage.
contract RealmFactoryUniV2UnifiedTests is LaunchpadBaseTestsWithUniv2Graduator {
    // ───────────── Dispatch — preview ─────────────

    function test_dispatch_noAntiSniper_returnsBaseImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        assertEq(impl, address(realmToken));
    }

    function test_dispatch_withAntiSniper_returnsAntiSniperImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        assertEq(impl, address(realmTokenSniper));
    }

    // ───────────── Dispatch — preview matches deployed ─────────────

    function test_createToken_dispatchMatchesPreview_base() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(token, expected);
    }

    /// @dev A no-vault token resolves to the base `BONDING_CURVE`; BondingCurveAssigned carries it.
    function test_createToken_emitsBondingCurveAssigned() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _emptyAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.expectEmit(true, true, false, false);
        emit IRealmFactory.BondingCurveAssigned(expected, address(factoryV2Unified.BONDING_CURVE()));
        vm.prank(creator);
        factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    function test_createToken_dispatchMatchesPreview_antiSniper() public {
        address impl = factoryV2Unified.previewTokenImplementation(
            _fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), _defaultAntiSniperCfg()
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(token, expected);
    }

    // ───────────── Anti-sniper config propagation ─────────────

    function test_createToken_antiSniper_configFieldsStoredOnToken() public {
        address[] memory wl = new address[](2);
        wl[0] = alice;
        wl[1] = bob;
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 150, 45 minutes, wl);

        address impl = factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), cfg);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), cfg);

        RealmToken t = RealmToken(token);
        assertEq(t.maxBuyPerTxBps(), 50);
        assertEq(t.maxWalletBps(), 150);
        assertEq(uint256(t.protectionWindowSeconds()), 45 minutes);
        assertTrue(t.sniperBypass(alice));
        assertTrue(t.sniperBypass(bob));
        assertFalse(t.sniperBypass(creator));
    }

    // ───────────── Anti-sniper sentinel validation ─────────────

    function test_preview_revertsOnDisabledAntiSniperWithNonZeroFields() public {
        AntiSniperConfigs memory cfg = _antiSniperCfg(50, 0, 0, new address[](0));

        vm.expectRevert(IRealmFactory.InvalidAntiSniperConfig.selector);
        factoryV2Unified.previewTokenImplementation(_fs(creator), _noSs(), _toCfgs(_emptyTaxCfg()), cfg);
    }

    function test_createToken_revertsOnDisabledAntiSniperWithWhitelist() public {
        address[] memory wl = new address[](1);
        wl[0] = alice;
        AntiSniperConfigs memory cfg = _antiSniperCfg(0, 0, 0, wl);

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidAntiSniperConfig.selector);
        factoryV2Unified.createToken("T", "T", "0x12", _fs(creator), _noSs(), _emptyTaxCfg(), cfg);
    }

    // ───────────── Ownership: V2 is always ownerless ─────────────

    function test_createToken_alwaysSetsOwnerToZero_base() public {
        address impl = address(realmToken);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token =
            factoryV2Unified.createToken("T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());

        assertEq(RealmToken(token).owner(), address(0));
    }

    function test_createToken_alwaysSetsOwnerToZero_antiSniper() public {
        address impl = address(realmTokenSniper);
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            "T", "T", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _defaultAntiSniperCfg()
        );

        assertEq(RealmToken(token).owner(), address(0));
    }

    // ───────────── Empty fee receivers (V2 specific) ─────────────

    function test_createToken_revertsOnEmptyFeeReceivers() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidFeeReceiver.selector);
        factoryV2Unified.createToken("T", "T", salt, _noFs(), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg());
    }

    // ───────────── Referral overload ─────────────

    function test_createToken_referral_emitsTokenReferral() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "R", symbol: "R", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });
        address referral = makeAddr("relayer");
        address expected = _predictToken(address(factoryV2Unified), address(realmToken), creator, salt);

        vm.expectEmit(true, true, false, false);
        emit IRealmFactory.TokenReferral(expected, referral);
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            setup,
            _toCfgs(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            referral
        );
        assertEq(token, expected);
    }

    /// @dev A zero referral emits no `TokenReferral` (the common no-referral deploy stays quiet).
    function test_createToken_zeroReferral_noTokenReferralEvent() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "R", symbol: "R", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.recordLogs();
        vm.prank(creator);
        factoryV2Unified.createToken(
            setup,
            _toCfgs(_emptyTaxCfg()),
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
