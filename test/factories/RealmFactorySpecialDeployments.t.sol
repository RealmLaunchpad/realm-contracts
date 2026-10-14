// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTestsWithDirectV4} from "test/launchpad/base.t.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {RealmFactoryUniV4Direct} from "src/factories/RealmFactoryUniV4Direct.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {TaxConfigs} from "src/interfaces/IRealmTaxableToken.sol";

/// @notice Owner-granted special deployments on the direct factory: looser launch-tax decay caps, spent
///         only by launches that need them.
contract RealmFactorySpecialDeploymentsTest is LaunchpadBaseTestsWithDirectV4 {
    event SpecialDeploymentsBudgetSet(address indexed deployer, uint256 budget);

    address internal special = makeAddr("special");

    /// @dev 19%/19% for 3h: fits the special caps (and, with the 100-bps LP fee, the hook's 20%), not the normal ones.
    function _specialCfg() internal pure returns (TaxConfigs memory) {
        return _decayCfg(1900, 1900, 3 hours, true);
    }

    function _create(address deployer, TaxConfigs memory tax) internal returns (address) {
        return _createDirectTokenAs(deployer, "Special", "SPC", _fs(deployer), false, tax);
    }

    function _preview(address deployer, TaxConfigs memory tax) internal returns (address) {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("Special", "SPC", true);
        vm.prank(deployer);
        return directFactory.previewTokenImplementation(
            setup, _nativePair(), _noDirectAlloc(tax), _emptyAntiSniperCfg(), _noVaults(), _noDevBuy(), address(0)
        );
    }

    function _grant(address deployer, uint256 budget) internal {
        vm.prank(directFactory.owner());
        directFactory.setSpecialDeploymentsBudget(deployer, budget);
    }

    function test_setBudget_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        directFactory.setSpecialDeploymentsBudget(special, 1);
    }

    function test_setBudget_storesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(directFactory));
        emit SpecialDeploymentsBudgetSet(special, 3);
        _grant(special, 3);
        assertEq(directFactory.specialDeploymentsBudget(special), 3);
    }

    function test_setBudget_belowUsed_reverts() public {
        _grant(special, 2);
        _create(special, _specialCfg());
        vm.prank(directFactory.owner());
        vm.expectRevert(RealmFactoryUniV4Direct.BudgetBelowUsed.selector);
        directFactory.setSpecialDeploymentsBudget(special, 0);
        _grant(special, 1); // equal to used: revokes the remainder
        assertEq(directFactory.getDeploymentLimits(special).maxTaxDecayDurationSeconds, 20 minutes);
    }

    function test_getDeploymentLimits_normalSpecialExhausted() public {
        RealmFactoryUniV4Direct.DeploymentLimits memory l = directFactory.getDeploymentLimits(special);
        assertEq(l.maxTaxDecayStartCombinedBps, 2_000, "normal combined");
        assertEq(l.maxTaxDecayDurationSeconds, 20 minutes, "normal duration");
        assertEq(l.maxOverallFeeBps, 2_000, "hook cap");

        _grant(special, 1);
        l = directFactory.getDeploymentLimits(special);
        assertEq(l.maxTaxDecayStartCombinedBps, 4_000, "special combined");
        assertEq(l.maxTaxDecayDurationSeconds, 3 hours, "special duration");
        assertEq(l.maxOverallFeeBps, 2_000, "hook cap unchanged");

        _create(special, _specialCfg());
        l = directFactory.getDeploymentLimits(special);
        assertEq(l.maxTaxDecayStartCombinedBps, 2_000, "exhausted: normal combined");
        assertEq(l.maxTaxDecayDurationSeconds, 20 minutes, "exhausted: normal duration");
    }

    function test_specialLaunch_succeedsAndConsumes_thenExhausts() public {
        _grant(special, 1);
        address token = _create(special, _specialCfg());

        RealmTaxableTokenUniV4 t = RealmTaxableTokenUniV4(payable(token));
        assertEq(uint256(t.buyTaxDecayStartBps()), 1900, "buy decay start");
        assertEq(uint256(t.sellTaxDecayStartBps()), 1900, "sell decay start");
        assertEq(uint256(t.taxDecayDuration()), 3 hours, "decay duration");
        assertEq(directFactory.specialDeploymentsUsed(special), 1, "one consumed");

        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: "Special2",
            symbol: "SP2",
            salt: _nextValidSalt(address(directFactory), address(realmTaxToken), special),
            feeShares: _fs(special),
            renounceOwnership: false,
            lpFeeBps: 100
        });
        vm.prank(special);
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        directFactory.createToken(
            setup,
            _nativePair(),
            _noDirectAlloc(_specialCfg()),
            _emptyAntiSniperCfg(),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );
    }

    function test_specialDeployer_normalLaunch_doesNotConsume() public {
        _grant(special, 1);
        _create(special, _decayCfg(1000, 1000, 20 minutes, true));
        assertEq(directFactory.specialDeploymentsUsed(special), 0, "normal launch is free");
    }

    function test_nonSpecialDeployer_specialCfg_reverts() public {
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = _directSetup("Special", "SPC", true);
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        directFactory.createToken(
            setup,
            _nativePair(),
            _noDirectAlloc(_specialCfg()),
            _emptyAntiSniperCfg(),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );

        // Within the normal duration, the combined cap still binds.
        setup = _directSetup("Special", "SPC", true);
        vm.prank(creator);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        directFactory.createToken(
            setup,
            _nativePair(),
            _noDirectAlloc(_decayCfg(1900, 1900, 20 minutes, true)),
            _emptyAntiSniperCfg(),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );
    }

    function test_special_hookPerDirectionCapStillEnforced() public {
        _grant(special, 1);
        RealmFactoryUniV4Direct.DirectTokenSetup memory setup = RealmFactoryUniV4Direct.DirectTokenSetup({
            name: "Special",
            symbol: "SPC",
            salt: _nextValidSalt(address(directFactory), address(realmTaxToken), special),
            feeShares: _fs(special),
            renounceOwnership: false,
            lpFeeBps: 100
        });
        vm.prank(special);
        vm.expectRevert(IRealmFactory.InvalidTaxBps.selector);
        directFactory.createToken(
            setup,
            _nativePair(),
            _noDirectAlloc(_decayCfg(1950, 0, 3 hours, true)), // + 100 bps LP fee = 2050
            _emptyAntiSniperCfg(),
            _noVaults(),
            _noDevBuy(),
            address(0)
        );
        assertEq(directFactory.specialDeploymentsUsed(special), 0, "revert consumes nothing");
    }

    function test_preview_followsCallerLimits_withoutConsuming() public {
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        this.previewAs(special, _specialCfg());

        _grant(special, 1);
        assertEq(_preview(special, _specialCfg()), address(realmTaxToken), "special preview ok");
        assertEq(_preview(special, _specialCfg()), address(realmTaxToken), "still ok: not consumed");
        assertEq(directFactory.specialDeploymentsUsed(special), 0, "preview consumes nothing");

        // Another caller still gets the normal limits.
        vm.expectRevert(IRealmFactory.InvalidTaxDuration.selector);
        this.previewAs(creator, _specialCfg());
    }

    /// @dev External wrapper so `expectRevert` targets the preview call, not the salt mining before it.
    function previewAs(address deployer, TaxConfigs memory tax) external returns (address) {
        return _preview(deployer, tax);
    }
}
