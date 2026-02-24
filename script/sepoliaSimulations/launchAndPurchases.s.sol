// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LivoLaunchpad} from "src/LivoLaunchpad.sol";
import {Script} from "lib/forge-std/src/Script.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {DeploymentAddressesSepolia} from "src/config/DeploymentAddresses.sol";
import {ILivoTaxableTokenUniV4} from "src/interfaces/ILivoTaxableTokenUniV4.sol";

contract BuySellSimulations is Script {
    // sepolia addresses. todo update after each deployment
    address LIVOTOKEN = 0xA55FA059B9848490E1009EA6161e5c03c9fD69dB;
    address LIVOTAXTOKEN = 0x1760618972F2F9cad4a78ee464ca917737AAE2DA;
    address LIVOLAUNCHPAD = 0xd8861EBe9Ee353c4Dcaed86C7B90d354f064cc8D;
    address BONDINGCURVE = 0x9D305cd3A9C39d8f4A7D45DE30F420B1eBD38E52;
    address GRADUATORV2 = 0x913412A11a33ad2381B08Dc287be476878d4a5b7;
    address GRADUATORV4 = 0x035693207fb473358b41A81FF09445dB1f3889D1;
    address LIQUIDIYLOCK = 0x812Cc2479174d1BA07Bb8788A09C6fe6dCD20e33;
    address LIVHOOK = 0x5bc9F6260a93f6FE2c16cF536B6479fc188e00C4;

    address LIVODEV = 0xBa489180Ea6EEB25cA65f123a46F3115F388f181;

    // SEPOLIA
    LivoLaunchpad launchpad = LivoLaunchpad(LIVOLAUNCHPAD);

    function run() public {
        vm.startBroadcast();
        bytes32 salt = bytes32(uint256(0x123));

        address TOKEN1 =
            launchpad.createToken("MEMEV2", "MAMIV2", LIVOTOKEN, BONDINGCURVE, GRADUATORV2, salt, "");
        address TOKEN2 =
            launchpad.createToken("projecTV4", "PROJECTV4", LIVOTOKEN, BONDINGCURVE, GRADUATORV4, salt, "");

        bytes memory tokenCalldata = ILivoTaxableTokenUniV4(LIVOTAXTOKEN).encodeTokenCalldata(500, 14 days);

        address TOKEN3 = launchpad.createToken(
            "projecTaxTV4", "PROJECTAXV4", LIVOTAXTOKEN, BONDINGCURVE, GRADUATORV4, salt, tokenCalldata
        );

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
