// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RealmE2EBase} from "test/e2e/base/RealmE2EBase.t.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice E2E happy paths that apply to every factory variant. Exercises the launchpad
///         pre-graduation buy/sell paths, the deployer-buy path through the real launchpad,
///         and the multi-recipient fee (>=2 fee receivers) end-to-end.
abstract contract E2EHappyPath is RealmE2EBase {
    /// @dev Modest pre-graduation buy that stays under any sniper variant's 3% per-tx cap.
    uint256 internal constant SMALL_BUY = 0.05 ether;

    function test_e2e_create_and_pregrad_buy() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        _launchpadBuy(token, SMALL_BUY);
        assertGt(IERC20(token).balanceOf(buyer), 0, "buyer should receive tokens");
    }

    function test_e2e_create_buy_then_sell_pregrad() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        address token = _createTestToken(salt);

        _launchpadBuy(token, SMALL_BUY);
        uint256 tokenBal = IERC20(token).balanceOf(buyer);
        assertGt(tokenBal, 0);

        uint256 sellAmount = tokenBal / 2;
        uint256 ethBefore = buyer.balance;

        vm.startPrank(buyer);
        IERC20(token).approve(address(launchpad), sellAmount);
        launchpad.sellExactTokens(token, sellAmount, 0, DEADLINE);
        vm.stopPrank();

        assertGt(buyer.balance, ethBefore, "seller should receive ETH");
    }

    function test_e2e_deployerBuy_distributesAcrossSupplyShares() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());

        IRealmFactory.SupplyShare[] memory ss = new IRealmFactory.SupplyShare[](2);
        ss[0] = IRealmFactory.SupplyShare({account: alice, shares: 7_000});
        ss[1] = IRealmFactory.SupplyShare({account: bob, shares: 3_000});

        // 0.1 ether keeps the deployer buy small (well below graduation).
        address token = _createTokenWithDeployerBuy(salt, 0.1 ether, ss);

        uint256 aliceAmt = IERC20(token).balanceOf(alice);
        uint256 bobAmt = IERC20(token).balanceOf(bob);

        assertGt(aliceAmt, 0, "alice should receive tokens from deployer buy");
        assertGt(bobAmt, 0, "bob should receive tokens from deployer buy");
        // 70/30 split with tolerance for last-recipient dust absorption
        assertApproxEqRel(aliceAmt * 3, bobAmt * 7, 1e15, "alice/bob ratio should be ~70/30");
    }

    function test_e2e_multiRecipient_isWiredToMasterHandler() public {
        bytes32 salt = _nextValidSalt(_factory(), _tokenImpl());
        IRealmFactory.FeeShare[] memory fees = _fsTwo(alice, bob);
        address token = _createTestTokenWithSplit(salt, fees);

        assertNotEq(token, address(0));

        (address[] memory recipients, uint256[] memory bps) = feeHandler.getRecipients(token);
        assertEq(recipients.length, 2);
        assertEq(recipients[0], alice);
        assertEq(recipients[1], bob);
        assertEq(bps[0], 6_000);
        assertEq(bps[1], 4_000);
    }
}
