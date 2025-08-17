// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {Script} from "lib/forge-std/src/Script.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract BuySellSimulations is Script {
    // SEPOLIA
    LivoLaunchpad launchpad = LivoLaunchpad(0x8a80112BCdd79f7b2635DDB4775ca50b56A940B2);

    function run() public {
        _purchaseTokens();
    }

    function _purchaseTokens() internal {
        address TOKEN1 = 0x530Cd72Cf87c483cA14aF62A8241Bc6101929cD2;
        address TOKEN2 = 0xf12c6cf1580411065Ed87D4042Dc50bb522A0780;

        uint256 deadline = block.timestamp + 300 days;

        vm.startBroadcast();
        IERC20(TOKEN1).approve(address(launchpad), type(uint256).max);
        IERC20(TOKEN2).approve(address(launchpad), type(uint256).max);

        // TOKEN 1
        launchpad.buyToken{value: 0.0000005 ether}(TOKEN1, 0, deadline);
        launchpad.buyToken{value: 0.00000051 ether}(TOKEN1, 0, deadline);
        launchpad.sellToken(TOKEN1, 0.0000008 ether, 0, deadline);
        launchpad.sellToken(TOKEN1, 0.000025 ether, 0, deadline);

        // TOKEN 2
        launchpad.buyToken{value: 0.000033 ether}(TOKEN2, 0, deadline);
        launchpad.sellToken(TOKEN2, 0.0000444 ether, 0, deadline);
        launchpad.buyToken{value: 0.000015 ether}(TOKEN2, 0, deadline);

        vm.stopBroadcast();
    }
}
