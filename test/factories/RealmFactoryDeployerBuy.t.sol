// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LaunchpadBaseTestsWithUniv2Graduator,
    LaunchpadBaseTestsWithUniv4GraduatorTaxableToken
} from "test/launchpad/base.t.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";
import {RealmFactoryUniV4Unified} from "src/factories/RealmFactoryUniV4Unified.sol";

contract RealmFactoryUniV4DeployerBuyTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Happy Path ============

    /// @dev deployer buy with a single supply recipient defaults the bought supply to that recipient
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmToken(token).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000); // <= 10%

        assertEq(RealmToken(token).balanceOf(address(factoryV2)), 0);

        TokenState memory state = launchpad.getTokenState(token);
        assertGt(state.ethCollected, 0);
        assertEq(state.releasedSupply, creatorBalance);
    }

    /// @dev createToken with msg.value=0 still works (supplyShares must be empty)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertEq(RealmToken(token).balanceOf(creator), 0);
        assertEq(RealmToken(token).balanceOf(address(launchpad)), TOTAL_SUPPLY);
    }

    /// @dev splitting bought supply across two recipients distributes proportionally and leaves no dust in the factory
    function test_createToken_supplySplit_twoRecipients_balancesMatchShares() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](2);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 3_000}); // 30%
        ss[1] = IRealmFactory.SupplyShare({account: bob, shares: 7_000}); // 70%

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        uint256 aliceBal = RealmToken(token).balanceOf(alice);
        uint256 bobBal = RealmToken(token).balanceOf(bob);
        uint256 total = aliceBal + bobBal;

        // total equals the launchpad-released supply
        TokenState memory state = launchpad.getTokenState(token);
        assertEq(state.releasedSupply, total);
        // factory holds nothing
        assertEq(RealmToken(token).balanceOf(address(factoryV2)), 0);
        // ratio roughly matches 30/70 (last recipient absorbs dust)
        assertApproxEqRel(aliceBal, total * 3 / 10, 1e15); // within 0.1%
    }

    /// @dev rounding dust from integer division goes to the last recipient
    function test_createToken_supplySplit_dustGoesToLastRecipient() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](3);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 3_333});
        ss[1] = IRealmFactory.SupplyShare({account: bob, shares: 3_333});
        ss[2] = IRealmFactory.SupplyShare({account: seller, shares: 3_334});

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        uint256 aliceBal = RealmToken(token).balanceOf(alice);
        uint256 bobBal = RealmToken(token).balanceOf(bob);
        uint256 sellerBal = RealmToken(token).balanceOf(seller);

        // alice and bob get identical amounts (same shares), seller absorbs any remainder
        assertEq(aliceBal, bobBal);
        // seller's balance must equal the released supply minus the other two
        TokenState memory state = launchpad.getTokenState(token);
        assertEq(sellerBal, state.releasedSupply - aliceBal - bobBal);
        // factory holds no dust
        assertEq(RealmToken(token).balanceOf(address(factoryV2)), 0);
    }

    // ============ Supply-share validation ============

    /// @dev shares not summing to 10 000 revert with InvalidShares
    function test_createToken_supplySplit_revertsOnSharesNotSummingTo10000() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));
        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](2);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 3_000});
        ss[1] = IRealmFactory.SupplyShare({account: bob, shares: 6_000}); // sum = 9_000

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev a zero-share entry reverts with InvalidShares
    function test_createToken_supplySplit_revertsOnZeroShare() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));
        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](2);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 10_000});
        ss[1] = IRealmFactory.SupplyShare({account: bob, shares: 0});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev a zero-address entry reverts with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnZeroAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));
        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](1);
        ss[0] = IRealmFactory.SupplyShare({account: address(0), shares: 10_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev duplicate recipients revert with InvalidSupplyShares
    function test_createToken_supplySplit_revertsOnDuplicateAccount() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));
        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](2);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 5_000});
        ss[1] = IRealmFactory.SupplyShare({account: alice, shares: 5_000});

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), ss, _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev passing supplyShares with msg.value == 0 is rejected
    function test_createToken_revertsOnSupplySharesProvidedWithoutMsgValue() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    /// @dev sending msg.value without supplyShares is rejected
    function test_createToken_revertsOnMsgValueWithoutSupplyShares() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            "TestToken", "TEST", salt, _fs(creator), _noSs(), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ Graduation ceiling ============

    /// @dev No buy-on-deploy cap: the deploy buy is bounded only by graduation. A buy whose ETH would push
    ///      the curve past `graduationThreshold + maxExcessOverThreshold` reverts `MaxEthReservesExceeded`
    ///      (DEFAULT threshold is 3.75 ETH, so 10 ETH is comfortably over the ceiling).
    function test_createToken_revertsWhenBuyExceedsGraduationCeiling() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmBondingCurve.MaxEthReservesExceeded.selector));
        factoryV2.createToken{value: 10 ether}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ Events ============

    /// @dev BuyOnDeploy event is emitted with correct buyer
    function test_createToken_emitsBuyOnDeployEvent() public {
        uint256 ethToSpend = 0.05 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectEmit(false, true, false, false);
        emit IRealmFactory.BuyOnDeploy(address(0), creator, 0, 0, new address[](0), new uint256[](0));
        factoryV2.createToken{value: ethToSpend}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded =
            factoryV2.quoteBuyOnDeploy(LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_emptyTaxCfg()));

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev At `maxBuyOnDeploy` the deploy buy reaches the graduation threshold: createToken succeeds
    ///      (no MaxEthReservesExceeded) and the token graduates in the same tx.
    function test_maxBuyOnDeploy_reachesGraduation() public {
        uint256 maxTokens = factoryV2.maxBuyOnDeploy(LiquidityTier.DEFAULT, 0);
        uint256 totalEthNeeded =
            factoryV2.quoteBuyOnDeploy(LiquidityTier.DEFAULT, maxTokens, 0, _toCfgs(_emptyTaxCfg()));

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken", "TEST", salt, _fs(creator), _ss(creator), _emptyTaxCfg(), _emptyAntiSniperCfg()
        );

        assertGe(RealmToken(token).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy must graduate the token");
    }

    /// @dev With a graduation-anchored tax window (`startTaxFromLaunch == false`) the deploy buy pays
    ///      no tax — the window hasn't opened — so the quote must exclude `buyTaxBps`. A quote that
    ///      includes it over-estimates the ETH and the exact-ETH-in deploy buy overshoots the quoted
    ///      token amount.
    function test_quoteBuyOnDeploy_graduationAnchoredTax_quoteIsTight() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_taxCfg(400, 0, uint32(14 days), false))
        );

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            _taxCfg(400, 0, uint32(14 days), false),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // within 0.5% of the quote
    }
}

contract RealmFactoryTaxTokenDeployerBuyTest is LaunchpadBaseTestsWithUniv4GraduatorTaxableToken {
    /// @dev The V4 config these tests deploy with: 100-bps hook LP fee, ownership retained. The
    ///      positional `createToken` overload they use hardcodes the same 100-bps fee, so passing this
    ///      to `quoteBuyOnDeploy` matches the token's actual buy fee.
    function _univ4Cfg100() internal pure returns (RealmFactoryUniV4Unified.UniV4Configs memory) {
        return RealmFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100});
    }

    // ============ Happy Path ============

    /// @dev deployer can buy tokens with ETH during createToken
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: ethToSpend}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGt(creatorBalance, 0);
        assertLe(creatorBalance, TOTAL_SUPPLY * 1_000 / 10_000);
        assertEq(RealmTaxableTokenUniV4(payable(token)).balanceOf(address(factoryTax)), 0);
    }

    /// @dev createToken with msg.value=0 still works (supplyShares must be empty)
    function test_createToken_noEth_backwardCompatible() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _noSs(),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        assertEq(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), 0);
    }

    // ============ Graduation ceiling ============

    /// @dev No buy-on-deploy cap: a deploy buy past `graduationThreshold + maxExcessOverThreshold`
    ///      reverts `MaxEthReservesExceeded` (DEFAULT threshold 3.75 ETH; 10 ETH is over the ceiling).
    function test_createToken_revertsWhenBuyExceedsGraduationCeiling() public {
        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmBondingCurve.MaxEthReservesExceeded.selector));
        factoryTax.createToken{value: 10 ether}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_taxCfg(0, 400, uint32(14 days))), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev With a non-zero BUY tax the deploy-buy fee is LP + buy tax, so the quote must be told that
    ///      full fee. Exercises that `buyFeeBps` is threaded into `quoteBuyOnDeploy` — the old
    ///      hardcoded-100 quote under-quoted here and the deployer would receive fewer than `tokenAmount`.
    function test_quoteBuyOnDeploy_roundTrip_withBuyTax() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint16 buyTax = 300; // 3%; with the 100 bps V4 LP fee the deploy-buy fee is 400 bps
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_taxCfg(buyTax, 0, uint32(14 days))), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(buyTax, 0, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev A decay-only token's deploy buy lands at elapsed≈0, so it pays the FULL decay start rate
    ///      (here 10%). The quote must include it (on top of the 1% V4 LP fee). A quote that ignores
    ///      decay under-quotes and the exact-ETH-in deploy buy receives fewer than `tokenAmount`.
    function test_quoteBuyOnDeploy_roundTrip_withDecayTax() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, tokenAmount, 0, _decayCfg(1000, 0, 20 minutes, true), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "TestToken", symbol: "TEST", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            setup,
            _decayCfg(1000, 0, 20 minutes, true),
            _univ4Cfg100(),
            _ss(creator),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );

        uint256 creatorBalance = RealmTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev At `maxBuyOnDeploy` the tax-token deploy buy reaches graduation: createToken succeeds and the
    ///      token graduates in the same tx.
    function test_maxBuyOnDeploy_reachesGraduation() public {
        uint256 maxTokens = factoryTax.maxBuyOnDeploy(LiquidityTier.DEFAULT, 0);
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, maxTokens, 0, _toCfgs(_taxCfg(0, 400, uint32(14 days))), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(0, 400, uint32(14 days)),
            _emptyAntiSniperCfg()
        );

        assertGe(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy must graduate the token");
    }

    /// @dev `maxBuyOnDeploy` is a TOKEN amount, independent of fees/taxes (the curve reserve ceiling is on
    ///      post-fee reserves). So a token launching with a BUY tax active from launch still graduates on a
    ///      max deploy buy: the deploy buy pays LP fee + launch buy tax, but `quoteBuyOnDeploy` grosses the
    ///      ETH up for both, so reserves still land at the graduation threshold. 4% buy tax (+1% V4 LP fee).
    function test_maxBuyOnDeploy_reachesGraduation_withLaunchBuyTax() public {
        uint256 maxTokens = factoryTax.maxBuyOnDeploy(LiquidityTier.DEFAULT, 0);
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, maxTokens, 0, _toCfgs(_taxCfg(400, 0, uint32(14 days))), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(400, 0, uint32(14 days)), // buyTax 400, startTaxFromLaunch defaults true
            _emptyAntiSniperCfg()
        );

        assertGe(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy with launch buy tax must graduate");
    }

    /// @dev Same, with a launch-anchored decaying buy tax (decay-only token): at elapsed≈0 the deploy buy
    ///      pays the full 10% decay-start buy rate (+1% LP), and the max deploy buy still graduates because
    ///      `quoteBuyOnDeploy` grosses the ETH up for the decay-start rate.
    function test_maxBuyOnDeploy_reachesGraduation_withLaunchDecayBuyTax() public {
        uint256 maxTokens = factoryTax.maxBuyOnDeploy(LiquidityTier.DEFAULT, 0);
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, maxTokens, 0, _decayCfg(1000, 0, 20 minutes, true), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "TestToken", symbol: "TEST", salt: salt, feeShares: _fs(creator), liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            setup,
            _decayCfg(1000, 0, 20 minutes, true),
            _univ4Cfg100(),
            _ss(creator),
            _emptyAntiSniperCfg(),
            new IRealmFactory.CreatorVault[](0),
            address(0)
        );

        assertGe(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy with launch decay buy tax must graduate");
    }

    /// @dev Tightest deploy-buy: max creator vault (30%) locked + a launch-anchored BUY tax. `maxBuyOnDeploy`
    ///      reads the 30%-vault curve (a smaller float) and `quoteBuyOnDeploy` grosses the ETH up for LP +
    ///      launch buy tax — the max deploy buy still graduates in the same tx with no revert. 4% buy tax.
    function test_maxBuyOnDeploy_reachesGraduation_withMaxVaultAndLaunchBuyTax() public {
        uint256 vaultBps = 3000; // 30% max
        uint256 maxTokens = factoryTax.maxBuyOnDeploy(LiquidityTier.DEFAULT, vaultBps);
        TaxConfigs memory taxConfigs = _toCfgs(_taxCfg(400, 0, uint32(14 days)));
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(LiquidityTier.DEFAULT, maxTokens, vaultBps, taxConfigs, _univ4Cfg100());

        address token = _createMaxVaultTaxToken(vaultBps, taxConfigs, totalEthNeeded);

        assertGe(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy w/ 30% vault + launch buy tax must graduate");
    }

    /// @dev Same tightest scenario with a launch-anchored decaying buy tax (10% decay start).
    function test_maxBuyOnDeploy_reachesGraduation_withMaxVaultAndLaunchDecayTax() public {
        uint256 vaultBps = 3000; // 30% max
        uint256 maxTokens = factoryTax.maxBuyOnDeploy(LiquidityTier.DEFAULT, vaultBps);
        TaxConfigs memory taxConfigs = _decayCfg(1000, 0, 20 minutes, true);
        uint256 totalEthNeeded =
            factoryTax.quoteBuyOnDeploy(LiquidityTier.DEFAULT, maxTokens, vaultBps, taxConfigs, _univ4Cfg100());

        address token = _createMaxVaultTaxToken(vaultBps, taxConfigs, totalEthNeeded);

        assertGe(RealmTaxableTokenUniV4(payable(token)).balanceOf(creator), maxTokens);
        assertTrue(launchpad.getTokenState(token).graduated, "max buy w/ 30% vault + launch decay tax must graduate");
    }

    /// @dev Deploys a DEFAULT-tier tax token with a single 30%-vault, funding the deployer buy with `value`.
    function _createMaxVaultTaxToken(uint256 vaultBps, TaxConfigs memory taxConfigs, uint256 value)
        internal
        returns (address token)
    {
        IRealmFactory.CreatorVault[] memory vaults = new IRealmFactory.CreatorVault[](1);
        vaults[0] =
            IRealmFactory.CreatorVault({owner: creator, supplyBps: vaultBps, cliffSeconds: 0, vestingSeconds: 1});
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "TestToken",
            symbol: "TEST",
            salt: _nextValidSalt(address(factoryTax), address(realmTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });

        vm.prank(creator);
        token = factoryTax.createToken{value: value}(
            setup, taxConfigs, _univ4Cfg100(), _ss(creator), _emptyAntiSniperCfg(), vaults, address(0)
        );
    }

    /// @dev With a graduation-anchored tax window (`startTaxFromLaunch == false`) the deploy buy pays
    ///      no tax — the window hasn't opened — so the quote must exclude `buyTaxBps`. A quote that
    ///      includes it over-estimates the ETH and the exact-ETH-in deploy buy overshoots the quoted
    ///      token amount.
    function test_quoteBuyOnDeploy_graduationAnchoredTax_quoteIsTight() public {
        uint256 tokenAmount = 30_000_000e18; // 3% of supply, under the 10% cap
        uint16 buyTax = 400;
        uint256 totalEthNeeded = factoryTax.quoteBuyOnDeploy(
            LiquidityTier.DEFAULT, tokenAmount, 0, _toCfgs(_taxCfg(buyTax, 0, uint32(14 days), false)), _univ4Cfg100()
        );

        bytes32 salt = _nextValidSalt(address(factoryTax), address(realmTaxToken));

        vm.prank(creator);
        address token = factoryTax.createToken{value: totalEthNeeded}(
            "TestToken",
            "TEST",
            salt,
            _fs(creator),
            _ss(creator),
            false,
            _taxCfg(buyTax, 0, uint32(14 days), false),
            _emptyAntiSniperCfg()
        );

        uint256 creatorBalance = RealmTaxableTokenUniV4(payable(token)).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // within 0.5% of the quote
    }
}
