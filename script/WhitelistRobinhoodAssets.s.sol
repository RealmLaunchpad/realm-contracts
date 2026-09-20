// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {ChainConfig} from "script/ChainConfig.sol";

/// @title Whitelist Robinhood Chain's biggest coins as direct-venue quotes
/// @notice Lists the coins in `script/operations/assets-whitelist/listings.robinhood.<chain>.json`,
///         each with the Uniswap pool that prices it. That file is generated — and the pools re-picked
///         against live state — by `discover_whitelist_assets.py` beside it; the README there explains
///         what qualifies as a price pool and why most of CoinGecko's top 300 is not in it.
///
/// @notice Both Robinhood chains, one script: mainnet lists the top coins by market cap, the testnet
///         the three dummy xStocks the dividend feature is exercised against. The file is chosen by
///         chain id, and names its own chain so a mismatched one cannot be broadcast.
///
/// @dev RE-GENERATE THE FILE FIRST (`just discover-whitelist-assets`). A listing's rate is a snapshot
///      taken now, from the pool named in the file, and both the pool choice and the price in it age.
///
/// @dev The FIRST entry is the reference asset (USDG), listed against native, because every entry
///      quoted in it is priced through its rate and the contract refuses a reference that is not
///      itself listed against native. The file's order is the order they go on chain.
///
/// @dev Every listing is simulated first and the ones the contract would refuse — a pool drained since
///      the scan, a rate that no longer computes — are reported and skipped, so one dead pool costs
///      one coin instead of the whole broadcast.
///
/// Usage (dry run): forge script WhitelistRobinhoodAssets --rpc-url rh-mainnet --account realm.dev
/// Usage (list):    just whitelist-assets-rh   (or whitelist-assets-rh-testnet), which broadcasts and
///                  then reads the result back off the chain with `verify()` below.
contract WhitelistRobinhoodAssets is Script {
    function run() public {
        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        require(address(whitelist).code.length != 0, "no contract at the manifest ASSETS_WHITELIST on this chain");

        // NOT `msg.sender`: forge leaves that as its own DEFAULT_SENDER unless `--sender` is passed, so an
        // `--account realm.dev` run would gate — and dry-run — against an address that signs nothing.
        // `readCallers` reports the account that will actually sign, but only inside an open broadcast.
        vm.startBroadcast();
        (, address approver,) = vm.readCallers();
        vm.stopBroadcast();
        require(whitelist.isApprover(approver), "signer is not an approver: the owner must add it first");

        (string[] memory symbols, address[] memory assets, RealmAssetsWhitelist.PriceSource[] memory sources) =
            _listings();
        bool[] memory live = _dryRun(whitelist, approver, symbols, assets, sources);

        vm.startBroadcast();
        uint256 listed;
        for (uint256 i; i < assets.length; ++i) {
            if (!live[i]) continue;
            whitelist.setWhitelisted(assets[i], sources[i]);
            ++listed;
        }
        vm.stopBroadcast();

        console.log("=== Listed %d of %d ===", listed, assets.length);
        require(listed != 0, "not one listing survived the dry run: nothing was whitelisted");
    }

    /// @notice Reads back what the chain actually stores: every asset the file names either prices or is
    ///         printed as MISSING. Reverts if none of them price — the broadcast never landed.
    /// @dev A SEPARATE invocation on purpose. A script's own post-broadcast reads see the state its
    ///      simulation produced, not the chain's, so a run that was sent nowhere (a local fork, a stale
    ///      proxy address) still reports success from inside itself. Only a fresh read against the live
    ///      RPC can tell the difference. The `just whitelist-assets-rh*` recipes run this for you.
    ///
    /// Usage: forge script WhitelistRobinhoodAssets --rpc-url rh-mainnet --sig 'verify()'
    function verify() public view {
        RealmAssetsWhitelist whitelist = RealmAssetsWhitelist(ChainConfig.assetsWhitelist());
        require(address(whitelist).code.length != 0, "no contract at the manifest ASSETS_WHITELIST on this chain");

        (string[] memory symbols, address[] memory assets,) = _listings();
        uint256 live;
        for (uint256 i; i < assets.length; ++i) {
            if (whitelist.unitsPerNativeX18(assets[i]) != 0) ++live;
            else console.log("  MISSING %s (%s)", symbols[i], assets[i]);
        }

        console.log("=== Live on chain: %d of %d ===", live, assets.length);
        require(live != 0, "no listing is live on chain: the broadcast never reached it");
    }

    /// @dev Lists everything against forked state, in file order, then rolls back. In order because a
    ///      USDG-quoted listing only validates once USDG itself is listed, which is the first entry —
    ///      the same dependency the broadcast has.
    function _dryRun(
        RealmAssetsWhitelist whitelist,
        address approver,
        string[] memory symbols,
        address[] memory assets,
        RealmAssetsWhitelist.PriceSource[] memory sources
    ) internal returns (bool[] memory live) {
        live = new bool[](assets.length);
        uint256 snapshot = vm.snapshotState();

        vm.startPrank(approver);
        for (uint256 i; i < assets.length; ++i) {
            try whitelist.setWhitelisted(assets[i], sources[i]) {
                live[i] = whitelist.unitsPerNativeX18(assets[i]) != 0;
            } catch {
                console.log("  %s (%s): its pool no longer prices it - skipped", symbols[i], assets[i]);
            }
        }
        vm.stopPrank();

        vm.revertToState(snapshot);
    }

    function _listingsPath() internal view returns (string memory) {
        if (block.chainid == 4663) return "script/operations/assets-whitelist/listings.robinhood.mainnet.json";
        if (block.chainid == 46630) return "script/operations/assets-whitelist/listings.robinhood.testnet.json";
        revert("no listings file for this chain");
    }

    /// @dev The generated file, as the arguments `setWhitelisted` takes. Parallel arrays because
    ///      `vm.parseJson` decodes one JSON value per call, so an array of objects would have to be
    ///      read field by field, entry by entry.
    function _listings()
        internal
        view
        returns (string[] memory symbols, address[] memory assets, RealmAssetsWhitelist.PriceSource[] memory sources)
    {
        string memory json = vm.readFile(_listingsPath());
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "listings are for another chain");

        assets = vm.parseJsonAddressArray(json, ".assets");
        symbols = vm.parseJsonStringArray(json, ".symbols");
        uint256[] memory venues = vm.parseJsonUintArray(json, ".venues");
        address[] memory pools = vm.parseJsonAddressArray(json, ".pools");
        address[] memory currency0 = vm.parseJsonAddressArray(json, ".currency0");
        address[] memory currency1 = vm.parseJsonAddressArray(json, ".currency1");
        uint256[] memory fees = vm.parseJsonUintArray(json, ".fees");
        int256[] memory tickSpacings = vm.parseJsonIntArray(json, ".tickSpacings");
        address[] memory hooks = vm.parseJsonAddressArray(json, ".hooks");

        sources = new RealmAssetsWhitelist.PriceSource[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            sources[i] = RealmAssetsWhitelist.PriceSource({
                venue: RealmAssetsWhitelist.Venue(venues[i]),
                pool: pools[i],
                key: PoolKey({
                    currency0: Currency.wrap(currency0[i]),
                    currency1: Currency.wrap(currency1[i]),
                    fee: uint24(fees[i]),
                    tickSpacing: int24(tickSpacings[i]),
                    hooks: IHooks(hooks[i])
                })
            });
        }
    }
}
