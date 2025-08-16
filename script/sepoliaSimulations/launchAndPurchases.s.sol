// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {Script} from "lib/forge-std/src/Script.sol";

contract LaunchAndPurchasesSimulation is Script {
    // SEPOLIA
    LivoLaunchpad launchpad = LivoLaunchpad(0xfD550c5dC070Ea575A06A40f2e18304D85211663);

    address linearBondingCurve = 0x5176076dD27C12b5fF60eFbf97D2C6a0697CE0DF;
    address linearGraduator = 0xBa1a7Fe65E7aAb563630F5921080996030a80AA1;

    function run() public {
        // _launchTokens();
        _purchaseTokens();
    }

    function _launchTokens() internal {
        // launch a couple of tokens
        vm.broadcast();
        launchpad.createToken("Linear Token", "LINEAR", "/url/to/metadata/", linearBondingCurve, linearGraduator);

        vm.broadcast();
        launchpad.createToken("Vertigo Token", "VERTIGO", "/url/to/metadata/", linearBondingCurve, linearGraduator);
    }

    function _purchaseTokens() internal {
        address TOKEN1 = 0x7eAa71476375091Aed0BE6C65a3E87D00CC0332a;
        address TOKEN2 = 0x9bEa2B57DF0309417fB3816e1d9834b31204588B;
        address TOKEN3 = 0x3D603CDd592692d2E89beDAa172679a1D4255dd5;

        uint256 deadline = block.timestamp + 300 days;
        // purchase a couple of tokens
        vm.startBroadcast();
        launchpad.buyToken{value: 0.0000002 ether}(TOKEN1, 1, deadline);
        launchpad.buyToken{value: 0.00000021 ether}(TOKEN1, 1, deadline);
        launchpad.sellToken(TOKEN1, 0.1 ether, 0.0000000002 ether, deadline);
        launchpad.sellToken(TOKEN1, 0.12 ether, 0.0000000002 ether, deadline);

        launchpad.buyToken{value: 0.00000011 ether}(TOKEN2, 1, deadline);
        launchpad.sellToken(TOKEN2, 0.12 ether, 0.0000000002 ether, deadline);
        launchpad.buyToken{value: 0.00000015 ether}(TOKEN2, 1, deadline);

        launchpad.buyToken{value: 0.00000021 ether}(TOKEN3, 1, deadline);
        launchpad.sellToken(TOKEN3, 0.012 ether, 0.0000000002 ether, deadline);
        launchpad.buyToken{value: 0.00000041 ether}(TOKEN3, 1, deadline);
        vm.stopBroadcast();
    }
}
