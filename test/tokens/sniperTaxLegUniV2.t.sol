// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {AntiSniperConfigs} from "src/tokens/SniperProtection.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice The sniper caps run for the whole window, graduation included, and a V2 taxable token
///         collects its tax by transferring it to ITSELF inside the same swap. That leg is the token's
///         own plumbing and must never be capped: it is not a buyer.
contract SniperTaxLegUniV2Tests is V2SwapHelpers, LaunchpadBaseTestsWithUniv2Graduator {
    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev Caps at their minimum (0.1%), 5% buy tax from graduation. `buyer` is whitelisted so it can
    ///      graduate the curve and then buy a large bag: its own leg bypasses the caps, and the 5% tax
    ///      leg into the token (~1% of supply) is what must not trip them.
    function test_taxLegIntoTheTokenIsNotCappedInsideTheWindow() public {
        address[] memory whitelist = new address[](1);
        whitelist[0] = buyer;
        AntiSniperConfigs memory caps = AntiSniperConfigs({
            maxBuyPerTxBps: 10, maxWalletBps: 10, protectionWindowSeconds: 1 days, whitelist: whitelist
        });
        vm.prank(creator);
        testToken = factoryV2Unified.createToken(
            _setupTiered(
                "Taxed", "TAX", _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)), _fs(creator)
            ),
            _noAlloc(_taxCfg(500, 500, 14 days)),
            _noSs(),
            caps,
            _noVaults(),
            address(0)
        );
        _graduateToken();

        vm.deal(buyer, 1 ether);
        _swapBuyV2(buyer, testToken, 1 ether, 0, true);

        assertGt(IERC20(testToken).balanceOf(testToken), IERC20(testToken).totalSupply() / 1000, "tax over the cap");
    }
}
