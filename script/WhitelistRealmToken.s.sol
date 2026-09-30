// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {UniswapV4PoolConstants} from "src/libraries/UniswapV4PoolConstants.sol";
import {ChainConfig} from "script/ChainConfig.sol";

interface IGraduatedToken {
    function graduator() external view returns (address);
    function quoteCount() external view returns (uint8);
    function quotes(uint256 index) external view returns (address);
}

interface IHookFor {
    function hookFor(address quote) external view returns (address);
}

/// @title Whitelist the REALM token as a direct-venue quote
/// @notice Lists the manifest's `REALM_TOKEN` in `RealmAssetsWhitelist`, priced from one of its own V4
///         pools (the canonical Realm key, hook from its graduator): the native one if it is live, else
///         the first live pair against a quote listed directly against native (e.g. USDG). Touches no
///         other asset: USDG and the xStocks go through `WhitelistRobinhoodAssets` and its discovery
///         loop, which never sees REALM.
///
/// @dev ONCE per chain, right after REALM graduates (no pool before that). Keepers then keep its rate
///      fresh with `refreshRates`; re-running this is only needed to change its source.
///
/// Usage (dry run): forge script WhitelistRealmToken --rpc-url rh-mainnet --account realm.dev
/// Usage (list):    just whitelist-realm-rh   (or whitelist-realm-rh-testnet), which broadcasts and then
///                  reads the result back off the chain with `verify()`.
contract WhitelistRealmToken is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() public {
        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        require(address(whitelist).code.length != 0, "no contract at the manifest ASSETS_WHITELIST on this chain");

        // `readCallers` reports the signing account only inside an open broadcast (see WhitelistRobinhoodAssets).
        vm.startBroadcast();
        (, address approver,) = vm.readCallers();
        vm.stopBroadcast();
        require(whitelist.isApprover(approver), "signer is not an approver: the owner must add it first");

        (address realm, RealmAssetsWhitelist.PriceSource memory source) = _source(whitelist);
        vm.startBroadcast();
        whitelist.setWhitelisted(realm, source);
        vm.stopBroadcast();

        console.log("REALM %s listed at %d units per native (x1e18)", realm, whitelist.unitsPerNativeX18(realm));
    }

    /// @notice Reads the listing back off the live chain; a separate invocation for the reason
    ///         `WhitelistRobinhoodAssets.verify` gives.
    function verify() public view {
        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        address realm = ChainConfig.realmToken();
        uint256 rate = whitelist.unitsPerNativeX18(realm);
        require(rate != 0, "REALM is not listed on chain: the broadcast never reached it");
        console.log("REALM %s live at %d units per native (x1e18)", realm, rate);
    }

    /// @dev Quote index 0 is native on every token, so a live native pool always wins.
    function _source(RealmAssetsWhitelist whitelist)
        internal
        view
        returns (address realm, RealmAssetsWhitelist.PriceSource memory source)
    {
        realm = ChainConfig.realmToken();
        require(realm != address(0), "manifest: REALM_TOKEN missing");
        IGraduatedToken token = IGraduatedToken(realm);
        IHookFor graduator = IHookFor(token.graduator());
        IPoolManager manager = whitelist.POOL_MANAGER();

        for (uint256 i; i < token.quoteCount(); ++i) {
            address quote = token.quotes(i);
            // The whitelist prices against native or a quote itself listed against native, one hop.
            if (
                quote != address(0)
                    && (whitelist.unitsPerNativeX18(quote) == 0 || whitelist.referenceOf(quote) != address(0))
            ) {
                continue;
            }
            PoolKey memory key = UniswapV4PoolConstants.realmPoolKey(realm, quote, graduator.hookFor(quote));
            if (manager.getLiquidity(key.toId()) == 0) continue;
            source.venue = RealmAssetsWhitelist.Venue.V4;
            source.key = key;
            console.log("pricing REALM against quote %s", quote);
            return (realm, source);
        }
        revert("REALM has no live pool against native or a native-listed quote");
    }
}
