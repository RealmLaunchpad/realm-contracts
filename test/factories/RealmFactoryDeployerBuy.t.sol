// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {RealmToken} from "src/tokens/RealmToken.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {TokenState} from "src/types/tokenData.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IRealmToken} from "src/interfaces/IRealmToken.sol";
import {IRealmBondingCurve} from "src/interfaces/IRealmBondingCurve.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";
import {RealmLaunchpad} from "src/RealmLaunchpad.sol";

contract RealmFactoryUniV4DeployerBuyTest is LaunchpadBaseTestsWithUniv2Graduator {
    // ============ Happy Path ============

    /// @dev deployer buy with a single supply recipient defaults the bought supply to that recipient
    function test_createToken_deployerBuy() public {
        uint256 ethToSpend = 0.1 ether;
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: ethToSpend}(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            ss,
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    /// @dev passing supplyShares with msg.value == 0 is rejected
    function test_createToken_revertsOnSupplySharesProvidedWithoutMsgValue() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    /// @dev sending msg.value without supplyShares is rejected
    function test_createToken_revertsOnMsgValueWithoutSupplyShares() public {
        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IRealmFactory.InvalidSupplyShares.selector));
        factoryV2.createToken{value: 0.01 ether}(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _noSs(),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );
    }

    // ============ quoteBuyOnDeploy ============

    /// @dev quoteBuyOnDeploy returns correct ETH that yields exactly tokenAmount
    function test_quoteBuyOnDeploy_roundTrip() public {
        uint256 tokenAmount = 50_000_000e18; // 5% of supply
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(LiquidityTier.DEFAULT, tokenAmount, 0, _emptyTaxCfg());

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        uint256 creatorBalance = RealmToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // quote is tight: deployer doesn't materially overpay
    }

    /// @dev At `maxBuyOnDeploy` the deploy buy reaches the graduation threshold: createToken succeeds
    ///      (no MaxEthReservesExceeded) and the token graduates in the same tx.
    function test_maxBuyOnDeploy_reachesGraduation() public {
        uint256 maxTokens = factoryV2.maxBuyOnDeploy(LiquidityTier.DEFAULT, 0);
        uint256 totalEthNeeded = factoryV2.quoteBuyOnDeploy(LiquidityTier.DEFAULT, maxTokens, 0, _emptyTaxCfg());

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmToken));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_emptyTaxCfg()),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
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
        uint256 totalEthNeeded =
            factoryV2.quoteBuyOnDeploy(LiquidityTier.DEFAULT, tokenAmount, 0, _taxCfg(400, 0, uint32(14 days), false));

        bytes32 salt = _nextValidSalt(address(factoryV2), address(realmTaxTokenV2));

        vm.prank(creator);
        address token = factoryV2.createToken{value: totalEthNeeded}(
            _setupTiered("TestToken", "TEST", salt, _fs(creator)),
            _noAlloc(_taxCfg(400, 0, uint32(14 days), false)),
            _ss(creator),
            _emptyAntiSniperCfg(),
            _noVaults(),
            address(0)
        );

        uint256 creatorBalance = RealmToken(token).balanceOf(creator);
        assertGe(creatorBalance, tokenAmount);
        assertApproxEqRel(creatorBalance, tokenAmount, 0.005e18); // within 0.5% of the quote
    }
}
