// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {RobinhoodForkBase} from "test/integration/fork/robinhood/RobinhoodForkBase.t.sol";
import {DeploymentAddressesRobinhoodMainnet as Robinhood} from "src/config/DeploymentAddresses.sol";
import {RealmTaxableTokenUniV4} from "src/tokens/RealmTaxableTokenUniV4.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {Hop} from "src/interfaces/IRealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {installDividendSwapRegistry, setDividendRoute} from "test/helpers/DividendRegistryHelpers.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev A block with today's xStock liquidity (the old suites' 58M predates most of it).
uint256 constant ROUTES_BLOCK = 74_900_000;

address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
/// @dev Hook on the dynamic-fee ETH/USDG V4 pool.
address constant USDG_POOL_HOOK = 0x06a889870C8f83640D6816319f72e2aA579b6080;

function spcxV4Direct() pure returns (bytes memory) {
    Hop[] memory hops = new Hop[](1);
    hops[0] = Hop({currency: SPCX, fee: 3_000, tickSpacing: 30, hooks: address(0)});
    return DividendRouteLib.encodeV4(hops);
}

function spcxV4ViaUsdg() pure returns (bytes memory) {
    Hop[] memory hops = new Hop[](2);
    hops[0] = Hop({currency: USDG, fee: 0x800000, tickSpacing: 10, hooks: USDG_POOL_HOOK});
    hops[1] = Hop({currency: SPCX, fee: 10_000, tickSpacing: 200, hooks: address(0)});
    return DividendRouteLib.encodeV4(hops);
}

function spcxV3() pure returns (bytes memory) {
    return DividendRouteLib.encodeV3(abi.encodePacked(Robinhood.WETH, uint24(500), SPCX));
}

/// @notice Every venue the registry speaks, converting a FULL conversion (`MAX_EARNINGS_PER_PROCESS`)
///         into real Robinhood mainnet liquidity: the proof that a thick pool on V2, V3 or V4 (hooked,
///         multi-hop) is reachable. The test contract stands in for a token.
contract RobinhoodDividendRoutesAtMaxSizeTests is Test {
    uint256 internal constant MAX_SPEND = Robinhood.MAX_EARNINGS_PER_PROCESS;
    RealmDividendSwapRegistry internal registry;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), ROUTES_BLOCK);
        registry = installDividendSwapRegistry(makeAddr("owner"));
    }

    /// @dev Sets `buyer`'s route for `asset` and buys `amount` with it as `buyer`; 0 if the swap reverts.
    function _buy(address buyer, address asset, bytes memory route, uint256 amount) internal returns (uint256 out) {
        vm.prank(registry.owner());
        registry.setRoute(buyer, asset, route);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        try registry.swapNativeToAsset{value: amount}(asset, 1, buyer) returns (uint256 o) {
            out = o;
        } catch {}
    }

    function _assertFullConversion(address asset, bytes memory route) internal {
        uint256 out = _buy(address(this), asset, route, MAX_SPEND);
        assertGt(out, 0, "a full conversion went through");
        assertEq(IERC20(asset).balanceOf(address(this)), out, "and was delivered");
    }

    function test_v4SingleHop_convertsAFullConversion() public {
        _assertFullConversion(SPCX, spcxV4Direct());
    }

    function test_v4MultiHopThroughAHookedPool_convertsAFullConversion() public {
        _assertFullConversion(SPCX, spcxV4ViaUsdg());
    }

    function test_v3_convertsAFullConversion() public {
        _assertFullConversion(SPCX, spcxV3());
    }

    function test_v2_convertsAFullConversion() public {
        _assertFullConversion(USDG, DividendRouteLib.encodeV2());
    }

    /// @dev Health check of the listed routes: each at a full conversion, logging its price impact
    ///      against a 0.001 ETH buy, or, for a route that cannot fill, the largest spend it can. ~6 min
    ///      of RPC, so opt-in: `CHECK_DIVIDEND_CATALOGUE=true`. Reads the `PickDividendRoutes` output.
    function test_catalogue_everyRouteConvertsAtMaxSize() public {
        vm.skip(!vm.envOr("CHECK_DIVIDEND_CATALOGUE", false));
        string memory json = vm.readFile("script/operations/dividend-routes/catalogue.robinhood.mainnet.json");
        string[] memory keys = vm.parseJsonKeys(json, "$");
        uint256 failed;
        for (uint256 i; i < keys.length; ++i) {
            address asset = vm.parseAddress(keys[i]);
            bytes memory route = vm.parseJsonBytes(json, string.concat(".", keys[i]));
            string memory sym = IERC20Metadata(asset).symbol();

            uint256 snap = vm.snapshotState();
            uint256 small = _buy(makeAddr("small"), asset, route, 0.001 ether);
            uint256 big = _buy(makeAddr("big"), asset, route, MAX_SPEND);
            vm.revertToState(snap);

            if (big == 0 || small == 0) {
                ++failed;
                console.log("FAIL %s %s max spend (milli-ETH): %d", sym, asset, _maxSpend(asset, route) / 1e15);
                continue;
            }
            uint256 ratio = (big * 10_000 * 0.001 ether) / (small * MAX_SPEND);
            console.log("IMPACT %s %s", sym, ratio >= 10_000 ? 0 : 10_000 - ratio);
        }
        assertEq(failed, 0, "every listed route converts at max size");
    }

    /// @dev Largest spend in [0, MAX_SPEND) `route` still converts, to ~0.4% of the cap.
    function _maxSpend(address asset, bytes memory route) internal returns (uint256 lo) {
        uint256 hi = MAX_SPEND;
        for (uint256 k; k < 8; ++k) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _buy(makeAddr("search"), asset, route, mid) != 0;
            vm.revertToState(snap);
            if (ok) lo = mid;
            else hi = mid;
        }
    }
}

/// @notice A real factory-created token paying SPCX, end to end: the creator's route converts, route
///         problems are fixed by an admin on the registry and reach the existing token, and the keeper
///         sizes conversions for thin pools.
contract RobinhoodDividendRoutesTokenE2ETests is RobinhoodForkBase {
    function _forkInfra() internal view override returns (ForkInfra memory infra) {
        infra = super._forkInfra();
        infra.blockNumber = ROUTES_BLOCK;
    }

    /// @dev A graduated SPCX-paying token with a buffer past the per-conversion cap, created with the
    ///      creator's `route` (empty: none — any ERC20 is accepted).
    function _spcxToken(bytes memory route) internal returns (RealmTaxableTokenUniV4 token) {
        bytes[] memory routes = new bytes[](1);
        routes[0] = route;
        token = _graduatedXStockToken(_createXStockToken(_sole(SPCX), _w(10_000), routes));
        token.accrueFees{value: 2 ether}();
        assertGt(token.pendingNative(), token.MAX_DIVIDEND_PER_CONVERSION(), "precondition: past the cap");
    }

    function _convertsAtMaxSize(bytes memory route) internal {
        RealmTaxableTokenUniV4 token = _spcxToken(route);
        uint256 buffered = token.pendingNative();

        token.processDividends(0, true, 0, 1, _noHolders());
        assertGt(IERC20(SPCX).balanceOf(address(token)), 0, "converted into SPCX");
        assertEq(token.pendingNative(), buffered - token.MAX_DIVIDEND_PER_CONVERSION(), "spent exactly the cap");

        vm.roll(block.number + 1);
        token.processDividends(0, false, 0, 0, _holders(buyer));
        assertGt(IERC20(SPCX).balanceOf(buyer), 0, "and the holder was paid in SPCX");
    }

    function test_v4Direct_convertsAtMaxSizeAndPays() public {
        _convertsAtMaxSize(spcxV4Direct());
    }

    function test_v4ViaUsdg_convertsAtMaxSizeAndPays() public {
        _convertsAtMaxSize(spcxV4ViaUsdg());
    }

    function test_v3_convertsAtMaxSizeAndPays() public {
        _convertsAtMaxSize(spcxV3());
    }

    /// @dev THE SCENARIO THE ADMIN SETTER EXISTS FOR: a token created with a wrong route keeps its buffer
    ///      intact, and an admin repointing THAT token's route on the registry fixes it.
    function test_aWrongRouteIsFixedByAnAdminForAnExistingToken() public {
        Hop[] memory wrong = new Hop[](1);
        wrong[0] = Hop({currency: SPCX, fee: 500, tickSpacing: 10, hooks: address(0)}); // never initialized
        RealmTaxableTokenUniV4 token = _spcxToken(DividendRouteLib.encodeV4(wrong));
        uint256 buffered = token.pendingNative();

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        token.processDividends(0, true, 0, 1, _noHolders());
        assertEq(token.pendingNative(), buffered, "nothing was lost to the failure");

        vm.prank(dividendSwapRegistry.owner());
        dividendSwapRegistry.setRoute(address(token), SPCX, spcxV3());
        token.processDividends(0, true, 0, 1, _noHolders());
        assertGt(IERC20(SPCX).balanceOf(address(token)), 0, "the repointed route converts for this token");
    }

    /// @dev A token created with no route waits, whole, until the per-asset override gives it one.
    function test_anUnroutedTokenConvertsOnceTheAssetOverrideIsSet() public {
        RealmTaxableTokenUniV4 token = _spcxToken("");
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        token.processDividends(0, true, 0, 1, _noHolders());

        setDividendRoute(dividendSwapRegistry, SPCX, spcxV4Direct());
        token.processDividends(0, true, 0, 1, _noHolders());
        assertGt(IERC20(SPCX).balanceOf(address(token)), 0, "the override converts for this token");
    }

    /// @dev The keeper sizes a conversion below the cap for a pool too thin to take all of it at once.
    function test_theKeeperCanConvertASliceSmallerThanTheCap() public {
        RealmTaxableTokenUniV4 token = _spcxToken(spcxV4Direct());
        uint256 buffered = token.pendingNative();

        token.processDividends(0, true, 0.3 ether, 1, _noHolders());
        assertEq(token.pendingNative(), buffered - 0.3 ether, "spent exactly the requested slice");
    }
}
