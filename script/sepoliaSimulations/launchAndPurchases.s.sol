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
        _launchTokens();
        // _purchaseTokens();
    }

    function _launchTokens() internal {
        // launch a couple of tokens
        vm.broadcast();
        launchpad.createToken("Linear Token", "LINEAR", "/url/to/metadata/", linearBondingCurve, linearGraduator);

        vm.broadcast();
        launchpad.createToken("Vertigo Token", "VERTIGO", "/url/to/metadata/", linearBondingCurve, linearGraduator);
    }

    function _purchaseTokens() internal {
        // purchase a couple of tokens
        vm.broadcast();
        launchpad.buyToken(address(launchpad), 0.000001 ether, block.timestamp + 1 hours);
    }
}
