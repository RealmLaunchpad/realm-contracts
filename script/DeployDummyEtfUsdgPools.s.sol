// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "lib/forge-std/src/console.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {ChainConfig} from "script/ChainConfig.sol";
import {DeployDummyUsdgPair} from "script/DeployDummyUsdgPair.s.sol";

/// @notice Gives every native-quoted testnet dummy (the pairs file, `listings.robinhood.testnet.json`) a full-range
///         V4 pool against the dummy USDG, so ETFs can hold it: an ETF route must be a direct asset/USDG pool.
///         Each opens at the dummy's current ETH price over USDG's, so the two paths agree. Dummies that already
///         have the pool are skipped, so re-running only seeds the new ones.
/// @dev The broadcaster must hold the dummy USDG and the dummies (the `DeployDummyRStocks` deployer does).
///      Env: USDG_PER_POOL (default 20_000e18).
///
/// Usage: just deploy-dummy-etf-usdg-pools-rh-testnet, then `just discover-etf-assets-rh-testnet`.
contract DeployDummyEtfUsdgPools is DeployDummyUsdgPair {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external override {
        require(ChainConfig.isRobinhoodTestnet(), "Robinhood testnet only");
        IPoolManager manager = IPoolManager(ChainConfig.infra().univ4PoolManager);
        uint256 usdgPerPool = vm.envOr("USDG_PER_POOL", uint256(20_000e18));
        (address[] memory assets, string[] memory symbols, PoolKey[] memory keys) = _listedPools();

        uint256 usdgSqrtPrice;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == USDG) (usdgSqrtPrice,,,) = manager.getSlot0(keys[i].toId());
        }
        require(usdgSqrtPrice != 0, "the pairs file has no native USDG pool");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        for (uint256 i; i < assets.length; ++i) {
            // Native-quoted dummies only: USDG itself and USDG-quoted ones (pHOOD3x) need nothing.
            if (assets[i] == USDG || Currency.unwrap(keys[i].currency0) != address(0)) continue;
            if (_hasUsdgPool(manager, assets[i])) {
                console.log("%s: USDG pool exists - skipped", symbols[i]);
                continue;
            }
            // Native sorts first, so both pools price units per native: dummy/USDG = (sqrtD / sqrtU)^2.
            (uint256 sqrtD,,,) = manager.getSlot0(keys[i].toId());
            uint256 tokensPerUsdg = Math.mulDiv(Math.mulDiv(sqrtD, 1e18, usdgSqrtPrice), sqrtD, usdgSqrtPrice);
            uint128 liquidity = _seedPool(assets[i], deployer, tokensPerUsdg, usdgPerPool);
            console.log("%s: USDG pool seeded, %d per USDG (1e18), liquidity %d", symbols[i], tokensPerUsdg, liquidity);
        }
        vm.stopBroadcast();
    }

    /// @dev The (USDG, token) pool `_seedPool` creates.
    function _hasUsdgPool(IPoolManager manager, address token) internal view returns (bool) {
        (address c0, address c1) = USDG < token ? (USDG, token) : (token, USDG);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, TICK_SPACING, IHooks(address(0)));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        return sqrtPriceX96 != 0;
    }

    /// @dev Every pairs-file entry with the pool that prices it.
    function _listedPools()
        internal
        view
        returns (address[] memory assets, string[] memory symbols, PoolKey[] memory keys)
    {
        string memory json = vm.readFile("script/operations/assets-whitelist/listings.robinhood.testnet.json");
        assets = vm.parseJsonAddressArray(json, ".assets");
        symbols = vm.parseJsonStringArray(json, ".symbols");
        address[] memory currency0 = vm.parseJsonAddressArray(json, ".currency0");
        address[] memory currency1 = vm.parseJsonAddressArray(json, ".currency1");
        uint256[] memory fees = vm.parseJsonUintArray(json, ".fees");
        int256[] memory tickSpacings = vm.parseJsonIntArray(json, ".tickSpacings");
        address[] memory hooks = vm.parseJsonAddressArray(json, ".hooks");
        keys = new PoolKey[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            keys[i] = PoolKey(
                Currency.wrap(currency0[i]),
                Currency.wrap(currency1[i]),
                uint24(fees[i]),
                int24(tickSpacings[i]),
                IHooks(hooks[i])
            );
        }
    }
}
