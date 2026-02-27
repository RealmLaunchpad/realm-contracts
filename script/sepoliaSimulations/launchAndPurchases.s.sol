// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {LivoFactoryBase} from "src/tokenFactories/LivoFactoryBase.sol";
import {LivoFactoryTaxToken} from "src/tokenFactories/LivoFactoryTaxToken.sol";
import {Script} from "lib/forge-std/src/Script.sol";

contract BuySellSimulations is Script {
    address LIVODEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;

    function run() public {
        address launchpadAddress = vm.envAddress("LIVOLAUNCHPAD");
        address factoryV2Address = vm.envAddress("FACTORY_V2");
        address factoryV4Address = vm.envAddress("FACTORY_V4");
        address factoryTaxAddress = vm.envAddress("FACTORY_TAX");

        LivoLaunchpad launchpad = LivoLaunchpad(launchpadAddress);
        LivoFactoryBase factoryV2 = LivoFactoryBase(factoryV2Address);
        LivoFactoryBase factoryV4 = LivoFactoryBase(factoryV4Address);
        LivoFactoryTaxToken factoryTax = LivoFactoryTaxToken(factoryTaxAddress);

        vm.startBroadcast();
        bytes32 salt = bytes32(uint256(0x123));

        address TOKEN1 = factoryV2.createToken("MEMEV2", "MAMIV2", LIVODEV, salt);
        address TOKEN2 = factoryV4.createToken("projecTV4", "PROJECTV4", LIVODEV, salt);
        address TOKEN3 = factoryTax.createToken("projecTaxTV4", "PROJECTAXV4", LIVODEV, salt, 500, uint32(14 days));

        uint256 deadline = block.timestamp + 300 days;

        // TOKEN1
        launchpad.buyTokensWithExactEth{value: 0.00005 ether}(TOKEN1, 0, deadline);
        launchpad.sellExactTokens(TOKEN1, 0.000008 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.0000051 ether}(TOKEN1, 0, deadline);
        launchpad.sellExactTokens(TOKEN1, 0.0000018 ether, 0, deadline);

        // TOKEN2
        launchpad.buyTokensWithExactEth{value: 0.000021 ether}(TOKEN2, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.000011 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000041 ether}(TOKEN2, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000031 ether}(TOKEN2, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.000025 ether, 0, deadline);

        // TOKEN 3
        launchpad.buyTokensWithExactEth{value: 0.000033 ether}(TOKEN3, 0, deadline);
        launchpad.sellExactTokens(TOKEN3, 0.000021 ether, 0, deadline);
        launchpad.sellExactTokens(TOKEN3, 0.000015 ether, 0, deadline);
        launchpad.sellExactTokens(TOKEN2, 0.0000444 ether, 0, deadline);
        launchpad.buyTokensWithExactEth{value: 0.000015 ether}(TOKEN3, 0, deadline);

        vm.stopBroadcast();
    }
}
