// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {LaunchpadBaseTestsWithUniv4Graduator} from "test/launchpad/base.t.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {ILivoToken} from "src/interfaces/ILivoToken.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {LivoCreatorVault} from "src/vaults/LivoCreatorVault.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {LivoQuoter} from "src/LivoQuoter.sol";
import {ILivoQuoter2} from "src/interfaces/ILivoQuoter2.sol";
import {LimitReason} from "src/interfaces/ILivoQuoter.sol";

/// @notice End-to-end tests for the creator-vault feature: createToken-with-vaults across the
///         V2/V4 + tax/sniper variants, the supply split, allocation-specific curve selection,
///         graduation invariants vs a baseline token, and the vault vesting lifecycle.
contract CreatorVaultsE2ETest is LaunchpadBaseTestsWithUniv4Graduator {
    uint256 constant TOKEN_TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant T_GRAD = 285714285714285714285714285; // tokens into liquidity, identical for all curves

    address vaultOwner = makeAddr("vaultOwner");
    address vaultOwner2 = makeAddr("vaultOwner2");

    bytes32 constant TOKEN_GRADUATED_SIG = keccak256("TokenGraduated(address,uint256,uint256)");
    bytes32 constant VAULT_DEPLOYED_SIG =
        keccak256("CreatorVaultDeployed(address,address,address,uint256,uint256,uint256)");

    /////////////////////////// helpers ///////////////////////////

    function _vault(address owner, uint256 bps, uint256 cliff, uint256 vesting)
        internal
        pure
        returns (ILivoFactory.CreatorVault memory)
    {
        return ILivoFactory.CreatorVault({owner: owner, supplyBps: bps, cliffSeconds: cliff, vestingSeconds: vesting});
    }

    function _one(ILivoFactory.CreatorVault memory v) internal pure returns (ILivoFactory.CreatorVault[] memory arr) {
        arr = new ILivoFactory.CreatorVault[](1);
        arr[0] = v;
    }

    /// @dev Creates a plain (non-tax, non-sniper) V4 token with the given vaults.
    function _createV4(ILivoFactory.CreatorVault[] memory vaults) internal returns (address token) {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "Vault",
            symbol: "VLT",
            salt: _nextValidSalt(address(factoryV4Unified), address(livoToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        LivoFactoryUniV4Unified.UniV4Configs memory cfg =
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
        vm.prank(creator);
        token = factoryV4Unified.createToken(
            setup, _toCfgs(_emptyTaxCfg()), cfg, _noSs(), _emptyAntiSniperCfg(), vaults, address(0)
        );
    }

    /// @dev Creates a token and returns the (single) deployed vault address by scanning logs.
    function _createV4AndVault(ILivoFactory.CreatorVault[] memory vaults)
        internal
        returns (address token, address vault)
    {
        vm.recordLogs();
        token = _createV4(vaults);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VAULT_DEPLOYED_SIG) {
                vault = address(uint160(uint256(logs[i].topics[1])));
                return (token, vault);
            }
        }
        revert("vault not deployed");
    }

    /// @dev Buys exactly up to the graduation threshold and returns the graduation payload.
    function _graduateAndCapture(address token) internal returns (uint256 ethCollected, uint256 tokensForGraduation) {
        uint256 ethReserves = launchpad.getTokenState(token).ethCollected;
        uint256 missing = _increaseWithFees(GRADUATION_THRESHOLD - ethReserves);
        vm.recordLogs();
        _launchpadBuy(token, missing);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == TOKEN_GRADUATED_SIG && address(uint160(uint256(logs[i].topics[1]))) == token) {
                (ethCollected, tokensForGraduation) = abi.decode(logs[i].data, (uint256, uint256));
                return (ethCollected, tokensForGraduation);
            }
        }
        revert("graduation event not found");
    }

    /////////////////////////// supply split ///////////////////////////

    function test_mintSplit_30pct_launchpadAndVaultBalances() public {
        (address token, address vault) = _createV4AndVault(_one(_vault(vaultOwner, 3000, 30 days, 365 days)));

        uint256 expectedVault = TOKEN_TOTAL_SUPPLY * 3000 / 10_000; // 300M
        assertEq(ILivoToken(token).totalSupply(), TOKEN_TOTAL_SUPPLY, "total supply unchanged at 1B");
        assertEq(ILivoToken(token).balanceOf(vault), expectedVault, "vault holds 30%");
        assertEq(
            ILivoToken(token).balanceOf(address(launchpad)), TOKEN_TOTAL_SUPPLY - expectedVault, "launchpad holds 70%"
        );
        assertEq(ILivoToken(token).balanceOf(address(factoryV4Unified)), 0, "factory holds nothing after distribution");
    }

    function test_mintSplit_multipleVaults_sumExact() public {
        ILivoFactory.CreatorVault[] memory vaults = new ILivoFactory.CreatorVault[](2);
        vaults[0] = _vault(vaultOwner, 1000, 0, 100 days); // 10%
        vaults[1] = _vault(vaultOwner2, 1500, 0, 100 days); // 15%

        vm.recordLogs();
        address token = _createV4(vaults);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address[] memory found = new address[](2);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VAULT_DEPLOYED_SIG) {
                found[n++] = address(uint160(uint256(logs[i].topics[1])));
            }
        }
        assertEq(n, 2, "two vaults deployed");
        assertEq(ILivoToken(token).balanceOf(found[0]), TOKEN_TOTAL_SUPPLY * 1000 / 10_000, "vault0 10%");
        assertEq(ILivoToken(token).balanceOf(found[1]), TOKEN_TOTAL_SUPPLY * 1500 / 10_000, "vault1 15%");
        // total 25% locked, launchpad holds 75%
        assertEq(ILivoToken(token).balanceOf(address(launchpad)), TOKEN_TOTAL_SUPPLY * 7500 / 10_000, "launchpad 75%");
    }

    /////////////////////////// curve selection ///////////////////////////

    function test_curveSelection_perAllocation() public {
        uint256[6] memory bps = [uint256(500), 1000, 1500, 2000, 2500, 3000];
        for (uint256 i; i < 6; ++i) {
            address token = _createV4(_one(_vault(vaultOwner, bps[i], 0, 1 days)));
            assertEq(
                address(launchpad.getTokenConfig(token).bondingCurve),
                vaultCurves[i],
                "token must use the allocation-specific curve"
            );
        }
    }

    function test_emptyVaults_usesBaseCurve() public {
        address token = _createV4(new ILivoFactory.CreatorVault[](0));
        assertEq(
            address(launchpad.getTokenConfig(token).bondingCurve), address(bondingCurve), "base curve when no vaults"
        );
        assertEq(ILivoToken(token).balanceOf(address(launchpad)), TOKEN_TOTAL_SUPPLY, "launchpad holds full supply");
    }

    /////////////////////////// validation reverts ///////////////////////////

    function test_revert_tooManyVaults() public {
        // cap is 5; the count check fires before the total-allocation check
        ILivoFactory.CreatorVault[] memory vaults = new ILivoFactory.CreatorVault[](6);
        for (uint256 i; i < 6; ++i) {
            vaults[i] = _vault(vaultOwner, 500, 0, 1 days);
        }
        vm.expectRevert(ILivoFactory.TooManyCreatorVaults.selector);
        _createV4(vaults);
    }

    function test_revert_bpsNotMultipleOf500() public {
        vm.expectRevert(ILivoFactory.InvalidCreatorVault.selector);
        _createV4(_one(_vault(vaultOwner, 300, 0, 1 days)));
    }

    function test_revert_totalAbove30pct() public {
        ILivoFactory.CreatorVault[] memory vaults = new ILivoFactory.CreatorVault[](2);
        vaults[0] = _vault(vaultOwner, 2000, 0, 1 days);
        vaults[1] = _vault(vaultOwner2, 1500, 0, 1 days); // total 35%
        vm.expectRevert(ILivoFactory.CreatorVaultAllocationTooHigh.selector);
        _createV4(vaults);
    }

    function test_revert_zeroOwner() public {
        vm.expectRevert(ILivoFactory.InvalidCreatorVault.selector);
        _createV4(_one(_vault(address(0), 500, 0, 1 days)));
    }

    function test_revert_zeroBps() public {
        vm.expectRevert(ILivoFactory.InvalidCreatorVault.selector);
        _createV4(_one(_vault(vaultOwner, 0, 0, 1 days)));
    }

    /////////////////////////// graduation invariants ///////////////////////////

    function test_graduation_vaultToken_depositsSameAsBaseToken() public {
        // baseline (no vault)
        address baseToken = _createV4(new ILivoFactory.CreatorVault[](0));
        (uint256 baseEth, uint256 baseTokens) = _graduateAndCapture(baseToken);

        // 30% vault token, graduated the same way
        address vaultToken = _createV4(_one(_vault(vaultOwner, 3000, 0, 1 days)));
        (uint256 vaultEth, uint256 vaultTokens) = _graduateAndCapture(vaultToken);

        // Core invariant: a vault token graduates IDENTICALLY to a baseline token (to the wei).
        assertEq(vaultTokens, baseTokens, "tokens into liquidity must be identical");
        assertEq(vaultEth, baseEth, "eth reserves at graduation must be identical");
        // Sanity vs the design targets (1-wei rounding dust on the curve's floor division).
        assertApproxEqAbs(vaultTokens, T_GRAD, 10, "tokens into liquidity ~= T_GRAD");
        assertGe(vaultEth, GRADUATION_THRESHOLD, "eth reserves at least the graduation threshold");
        assertLe(vaultEth, GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS, "eth reserves within the graduation window");
    }

    function test_graduation_eachAllocation_depositsTGRAD() public {
        uint256[6] memory bps = [uint256(500), 1000, 1500, 2000, 2500, 3000];
        for (uint256 i; i < 6; ++i) {
            address token = _createV4(_one(_vault(vaultOwner, bps[i], 0, 1 days)));
            (uint256 ethCollected, uint256 tokensForGraduation) = _graduateAndCapture(token);
            assertApproxEqAbs(tokensForGraduation, T_GRAD, 10, "tokens into liquidity ~= T_GRAD for every allocation");
            assertGe(ethCollected, GRADUATION_THRESHOLD, "eth reserves at least the threshold");
            assertLe(ethCollected, GRADUATION_THRESHOLD + MAX_THRESHOLD_EXCESS, "eth reserves within the window");
        }
    }

    /////////////////////////// sniper / tax exclusion ///////////////////////////

    function test_sniperToken_vaultExceedsMaxWallet_stillFunded() public {
        // sniper config with a tiny max-wallet cap (0.5%); the 30% vault is 60x that cap.
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "VaultSniper",
            symbol: "VS",
            salt: _nextValidSalt(address(factoryV4Unified), address(livoTokenSniper)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        LivoFactoryUniV4Unified.UniV4Configs memory cfg =
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
        AntiSniperConfigs memory sniper = AntiSniperConfigs({
            maxBuyPerTxBps: 50,
            maxWalletBps: 50, // 0.5%
            protectionWindowSeconds: 1 hours,
            whitelist: new address[](0)
        });

        vm.recordLogs();
        vm.prank(creator);
        address token = factoryV4Unified.createToken(
            setup, _toCfgs(_emptyTaxCfg()), cfg, _noSs(), sniper, _one(_vault(vaultOwner, 3000, 0, 1 days)), address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VAULT_DEPLOYED_SIG) vault = address(uint160(uint256(logs[i].topics[1])));
        }
        // factory→vault transfer bypassed the sniper cap (from == tokenFactory)
        assertEq(
            ILivoToken(token).balanceOf(vault), TOKEN_TOTAL_SUPPLY * 3000 / 10_000, "vault funded past max-wallet cap"
        );
    }

    function test_v2TaxToken_vaultFunding_notTaxed() public {
        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "VaultTaxV2",
            symbol: "VTX",
            salt: _nextValidSalt(address(factoryV2Unified), address(livoTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });

        vm.recordLogs();
        vm.prank(creator);
        address token = factoryV2Unified.createToken(
            setup,
            _toCfgs(_taxCfg(300, 300, uint32(7 days))),
            _noSs(),
            _emptyAntiSniperCfg(),
            _one(_vault(vaultOwner, 2000, 0, 1 days)),
            address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == VAULT_DEPLOYED_SIG) vault = address(uint160(uint256(logs[i].topics[1])));
        }
        // vault funding is a non-pair transfer, so no tax is skimmed: exact 20%.
        assertEq(ILivoToken(token).balanceOf(vault), TOKEN_TOTAL_SUPPLY * 2000 / 10_000, "no tax on vault funding");
        assertEq(ILivoToken(token).balanceOf(token), 0, "tax contract accrued nothing from vault funding");
    }

    /////////////////////////// vesting lifecycle ///////////////////////////
    // The vesting clock starts at token creation (vault init); claims are gated on graduation.

    function test_vault_claimBeforeGraduation_reverts() public {
        (address token, address vault) = _createV4AndVault(_one(_vault(vaultOwner, 1000, 0, 30 days)));
        // schedule has progressed, but the token has not graduated yet
        vm.warp(block.timestamp + 15 days);
        assertEq(LivoCreatorVault(payable(vault)).claimable(), 0, "nothing claimable before graduation");
        vm.prank(vaultOwner);
        vm.expectRevert(LivoCreatorVault.NotGraduated.selector);
        LivoCreatorVault(payable(vault)).claim();
        // graduating then unlocks the already-vested portion
        _graduateAndCapture(token);
        assertGt(LivoCreatorVault(payable(vault)).claimable(), 0, "claimable after graduation");
    }

    function test_vault_claimByNonOwner_reverts() public {
        (address token, address vault) = _createV4AndVault(_one(_vault(vaultOwner, 1000, 0, 30 days)));
        _graduateAndCapture(token);
        vm.warp(block.timestamp + 15 days);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(LivoCreatorVault.NotOwner.selector);
        LivoCreatorVault(payable(vault)).claim();
    }

    function test_vault_cliffBlocksClaim_thenLinearVesting() public {
        uint256 cliff = 30 days;
        uint256 vesting = 100 days;
        uint256 alloc = TOKEN_TOTAL_SUPPLY * 1000 / 10_000; // 10%
        (address token, address vault) = _createV4AndVault(_one(_vault(vaultOwner, 1000, cliff, vesting)));

        _graduateAndCapture(token);
        uint256 start = LivoCreatorVault(payable(vault)).startTimestamp(); // creation time

        // during the cliff: nothing claimable
        vm.warp(start + cliff - 1);
        assertEq(LivoCreatorVault(payable(vault)).claimable(), 0, "no claim during cliff");
        vm.prank(vaultOwner);
        vm.expectRevert(LivoCreatorVault.NothingToClaim.selector);
        LivoCreatorVault(payable(vault)).claim();

        // half-way through linear vesting: ~50%
        vm.warp(start + cliff + vesting / 2);
        assertApproxEqRel(LivoCreatorVault(payable(vault)).claimable(), alloc / 2, 0.0001e18, "~50% vested at half");
        vm.prank(vaultOwner);
        LivoCreatorVault(payable(vault)).claim();
        assertApproxEqRel(ILivoToken(token).balanceOf(vaultOwner), alloc / 2, 0.0001e18, "owner got ~50%");

        // past the end: remainder claimable, total == allocation
        vm.warp(start + cliff + vesting + 1);
        assertEq(
            LivoCreatorVault(payable(vault)).claimable(), alloc - ILivoToken(token).balanceOf(vaultOwner), "remainder"
        );
        vm.prank(vaultOwner);
        LivoCreatorVault(payable(vault)).claim();
        assertEq(ILivoToken(token).balanceOf(vaultOwner), alloc, "owner received full allocation");
        assertEq(ILivoToken(token).balanceOf(vault), 0, "vault emptied");
        assertEq(LivoCreatorVault(payable(vault)).claimable(), 0, "nothing left to claim");
    }

    function test_vault_zeroCliffZeroVesting_fullUnlockAtGraduation() public {
        uint256 alloc = TOKEN_TOTAL_SUPPLY * 500 / 10_000; // 5%
        (address token, address vault) = _createV4AndVault(_one(_vault(vaultOwner, 500, 0, 0)));
        // zero cliff + zero vesting => schedule says fully vested immediately, but claim is gated
        assertEq(LivoCreatorVault(payable(vault)).vestedAmount(), alloc, "schedule fully vested");
        assertEq(LivoCreatorVault(payable(vault)).claimable(), 0, "but nothing claimable before graduation");
        _graduateAndCapture(token);
        assertEq(LivoCreatorVault(payable(vault)).claimable(), alloc, "fully claimable at graduation");
        vm.prank(vaultOwner);
        LivoCreatorVault(payable(vault)).claim();
        assertEq(ILivoToken(token).balanceOf(vaultOwner), alloc, "owner got everything");
    }

    /////////////////////////// quoter regression ///////////////////////////

    /// @dev `LivoQuoter` composes the launchpad's quote views, which read the token's REGISTERED
    ///      bonding curve. So a vault token must quote against its allocation-specific curve with no
    ///      quoter changes. This locks that in.
    function test_quoter_usesRegisteredVaultCurve() public {
        LivoQuoter quoter = new LivoQuoter(address(launchpad));
        address token = _createV4(_one(_vault(vaultOwner, 3000, 0, 1 days)));

        uint256 ethValue = 0.1 ether;
        ILivoQuoter2.BuyExactEthQuote memory q = quoter.quoteBuyTokensWithExactEth(token, buyer, ethValue);
        assertEq(uint256(q.reason), uint256(LimitReason.NONE), "quote should be valid");
        assertGt(q.tokensToReceive, 0, "non-zero tokens");

        // matches the launchpad's direct quote (both read the registered vault curve)
        (, uint256 ethFee, uint256 tokensDirect,) = launchpad.quoteBuyTokensWithExactEth(token, ethValue);
        assertEq(q.tokensToReceive, tokensDirect, "quoter matches launchpad on the vault curve");
        assertEq(q.ethFee, ethFee, "fee matches");
    }

    /// @dev The vault-aware `quoteBuyOnDeploy(tokenAmount, creatorVaults)` must price the same curve
    ///      `createToken` registers, so a deployer who funds with the quote receives ~`tokenAmount`.
    ///      The base single-arg form under-quotes for vault tokens.
    function test_quoteBuyOnDeploy_vaultAware_isAccurate() public {
        ILivoFactory.CreatorVault[] memory vaults = _one(_vault(vaultOwner, 3000, 0, 1 days));
        uint256 tokenAmount = 50_000_000e18; // 5% of supply, under the 10% buy-on-deploy cap

        LivoFactoryUniV4Unified.UniV4Configs memory cfg =
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});

        uint256 ethVaultAware =
            factoryV4Unified.quoteBuyOnDeploy(LiquidityTier.DEFAULT, tokenAmount, 3000, _toCfgs(_emptyTaxCfg()), cfg);
        uint256 ethBaseOnly =
            factoryV4Unified.quoteBuyOnDeploy(LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_emptyTaxCfg()), cfg);
        // the 30% curve starts steeper, so the same tokens cost MORE ETH than the base quote
        assertGt(ethVaultAware, ethBaseOnly, "vault-aware quote must exceed the base quote");

        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "VQ",
            symbol: "VQ",
            salt: _nextValidSalt(address(factoryV4Unified), address(livoToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });

        vm.deal(creator, ethVaultAware);
        vm.prank(creator);
        address token = factoryV4Unified.createToken{value: ethVaultAware}(
            setup, _toCfgs(_emptyTaxCfg()), cfg, _ss(creator), _emptyAntiSniperCfg(), vaults
        );

        // deployer (sole supply-share recipient) receives ~tokenAmount, never less than quoted
        uint256 received = ILivoToken(token).balanceOf(creator);
        assertGe(received, tokenAmount, "deployer gets at least the quoted amount");
        assertApproxEqRel(received, tokenAmount, 0.00000001e18, "deployer gets ~the quoted token amount (<=1e-6%)");
    }
}
