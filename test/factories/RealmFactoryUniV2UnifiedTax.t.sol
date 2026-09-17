// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {RealmFactoryUniV2Unified} from "src/factories/RealmFactoryUniV2Unified.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";

/// @notice Tax dispatch + tax-config validation tests for `RealmFactoryUniV2Unified`. Mirrors the
///         V4 unified tax tests. Locks in: (1) the four-cell dispatch matrix (tax × anti-sniper)
///         resolves to the correct implementation; (2) `previewTokenImplementation` returns the
///         same address `createToken` clones; (3) tax-config validation matches the V4 factory
///         (max bps, max duration up to the 120-year overflow cap, no fee-receiver/ownership
///         gating); (4) tax fields propagate to the deployed token; (5) ownership rule (all V2
///         tokens are ownerless at creation).
contract RealmFactoryUniV2UnifiedTaxTests is LaunchpadBaseTestsWithUniv2Graduator {
    // ───────────── Dispatch — preview returns correct impl per combo ─────────────

    function test_dispatch_tax_returnsTaxImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(_taxCfg(0, 400, uint32(7 days))),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        assertEq(impl, address(realmTaxTokenV2));
    }

    function test_dispatch_taxAntiSniper_returnsTaxAntiSniperImpl() public view {
        address impl = factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(_taxCfg(0, 400, uint32(7 days))),
            _noSs(),
            _defaultAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        assertEq(impl, address(realmTaxTokenV2Sniper));
    }

    // ───────────── Dispatch — preview matches deployed for each tax combo ─────────────

    function test_createToken_dispatchMatchesPreview_tax() public {
        TaxConfigs memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl = factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertEq(token, expected);
    }

    function test_createToken_dispatchMatchesPreview_taxAntiSniper() public {
        TaxConfigs memory cfg = _taxCfg(100, 200, uint32(7 days));
        address impl = factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _defaultAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);
        address expected = _predictToken(address(factoryV2Unified), impl, creator, salt);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _defaultAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertEq(token, expected);
    }

    // ───────────── Tax config readback ─────────────

    function test_createToken_tax_configFieldsStoredOnToken() public {
        TaxConfigs memory cfg = _taxCfg(150, 250, uint32(7 days));
        address impl = factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), impl);

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        RealmTaxableTokenUniV2 t = RealmTaxableTokenUniV2(payable(token));
        assertEq(t.buyTaxBps(), 150);
        assertEq(t.sellTaxBps(), 250);
        assertEq(uint256(t.taxDurationSeconds()), 7 days);
        assertEq(uint256(t.graduationTimestamp()), 0); // not graduated yet
    }

    // ───────────── Tax sentinel validation ─────────────

    function test_preview_revertsOnDisabledTaxWithNonZeroBps() public {
        TaxConfigs memory cfg = _taxCfg(100, 0, 0);
        vm.expectRevert(IRealmFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function test_preview_revertsOnEnabledTaxWithZeroBps() public {
        TaxConfigs memory cfg = _taxCfg(0, 0, uint32(7 days));
        vm.expectRevert(IRealmFactory.InvalidTaxConfig.selector);
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function test_preview_acceptsBpsAtMax() public view {
        // 500 bps is the V2 tax cap: V2 has no post-graduation LP fee, so the tax can use the full
        // MAX_TOTAL_FEE_BPS. The pre-graduation launchpad LP fee does not count against it. Boundary
        // value must be accepted.
        TaxConfigs memory cfg = _taxCfg(500, 500, uint32(7 days));
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function test_preview_revertsOnTaxBpsOverMax() public {
        TaxConfigs memory cfg = _taxCfg(501, 0, uint32(7 days));
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function test_preview_revertsOnSellTaxBpsOverMax() public {
        TaxConfigs memory cfg = _taxCfg(0, 501, uint32(7 days));
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    function test_preview_revertsOnDurationOverCap() public {
        TaxConfigs memory cfg = _taxCfg(100, 0, uint32(120 * 365 days + 1));
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        factoryV2Unified.previewTokenImplementation(
            _setupTiered("", "", bytes32(0), _fs(alice)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    // ───────────── Extended durations — no restrictions beyond the 120-year cap ─────────────

    function test_createToken_succeedsForExtendedDurationWithDeployerAsFeeReceiver() public {
        TaxConfigs memory cfg = _taxCfg(100, 0, uint32(5 * 365 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        RealmTaxableTokenUniV2 t = RealmTaxableTokenUniV2(payable(token));
        assertEq(uint256(t.taxDurationSeconds()), 5 * 365 days);
        assertEq(t.owner(), address(0));
    }

    function test_createToken_succeedsForExtendedDurationWithMultipleReceivers() public {
        TaxConfigs memory cfg = _taxCfg(100, 0, uint32(365 days + 1));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2));

        IRealmFactory.FeeShare[] memory two = new IRealmFactory.FeeShare[](2);
        two[0] = IRealmFactory.FeeShare({account: alice, shares: 5_000, directFeesEnabled: false});
        two[1] = IRealmFactory.FeeShare({account: bob, shares: 5_000, directFeesEnabled: false});

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, two), _noAlloc(cfg), _noSs(), _emptyAntiSniperCfg(), _noVaults(), address(0)
        );

        assertEq(uint256(RealmTaxableTokenUniV2(payable(token)).taxDurationSeconds()), 365 days + 1);
    }

    function test_createToken_succeedsForMaxDuration() public {
        TaxConfigs memory cfg = _taxCfg(100, 0, uint32(120 * 365 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(alice)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        RealmTaxableTokenUniV2 t = RealmTaxableTokenUniV2(payable(token));
        assertEq(uint256(t.taxDurationSeconds()), 120 * 365 days);
    }

    // ───────────── Ownership semantics ─────────────

    function test_createToken_taxVariant_alwaysSetsOwnerToZero() public {
        TaxConfigs memory cfg = _taxCfg(100, 100, uint32(7 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertEq(RealmTaxableTokenUniV2(payable(token)).owner(), address(0));
    }

    function test_createToken_taxAntiSniperVariant_alwaysSetsOwnerToZero() public {
        TaxConfigs memory cfg = _taxCfg(100, 100, uint32(7 days));
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2Sniper));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(cfg),
            _noSs(),
            _defaultAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertEq(RealmTaxableTokenUniV2(payable(token)).owner(), address(0));
    }

    function test_createToken_nonTaxVariant_alwaysSetsOwnerToZero() public {
        bytes32 salt = _nextValidSalt(address(factoryV2Unified), address(realmToken));

        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            _setupTiered("T", "T", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        assertEq(RealmTaxableTokenUniV2(payable(token)).owner(), address(0));
    }
}
