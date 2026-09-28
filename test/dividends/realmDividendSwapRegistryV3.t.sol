// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {installDividendSwapRegistry} from "test/helpers/DividendRegistryHelpers.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

/// @notice The curated Uniswap V3 venue, exercised against the real Ondo Global Markets pools — the
///         assets this venue exists for, and the only tokenized equities on Ethereum with usable depth.
///
/// @dev PINNED LATER THAN THE REST OF THE SUITE, on purpose. These pools did not exist at the block the
///      other dividend fork tests use, so this file carries its own.
///
/// @dev The most important test here is `test_aPoolHoldingAlmostNoQuoteTokenIsStillUsable`. A V3
///      position that currently holds only the ASSET and none of the quote token is what a healthy
///      sell-side market maker looks like, and it is exactly the shape a buyer wants — so any gate that
///      judged depth by reading the pool's quote-side balance would reject precisely the pools this
///      venue was added to reach. That test is the regression guard for ever reintroducing one.
interface IWETH9 {
    function deposit() external payable;
}

interface IUniswapV3FactoryMin {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface IUniswapV3PoolMin {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256, uint256);
}

/// @notice Stand-in for the universal router on a PARTIAL V3 fill. `WRAP_ETH` wraps the whole input up
///         front but the swap consumes only what the pool's liquidity could take, so the unspent WETH
///         stays with the router — unrefunded, sweepable by anyone — while the caller has already
///         debited the full spend.
contract PartialFillV3RouterStub {
    address internal constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant SINK = 0x000000000000000000000000000000000000dEaD;

    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        IWETH9(WETH9).deposit{value: msg.value}();
        IERC20(WETH9).transfer(SINK, msg.value / 2); // the half the pool actually took
        IERC20(AAPL).transfer(msg.sender, 1e18);
    }
}

contract RealmDividendSwapRegistryV3Tests is Test {
    uint256 internal constant BLOCKNUMBER = 58_000_000;

    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    /// @dev Robinhood xStocks, the chain's tokenized equities. Single-hop WETH V3 pools.
    address internal constant AAPLon = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant HOODon = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    /// @dev Reachable only through USDG — its WETH V3 pool is empty at the pinned block, which is
    ///      the reason two-hop routes are supported at all.
    address internal constant SPYon = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    uint24 internal constant FEE_005 = 500;
    uint24 internal constant FEE_030 = 3000;
    uint24 internal constant FEE_001 = 100;
    uint24 internal constant FEE_100 = 10_000;

    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    /// @dev AAPLon's real, liquid WETH pool.
    address internal constant AAPL_WETH_005 = 0x8bb3514e2204E1cDF3Ac149EFEe7Ff04D91B719f;

    RealmDividendSwapRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(owner);

        vm.prank(owner);
        registry.setAdmin(admin, true);
    }

    /// @dev `token | fee | token`, Uniswap V3's own encoding.
    function _path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function _path(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }

    /// @dev Lists `asset`'s route as an admin. This test contract then converts exactly as a token does.
    function _route(address asset, bytes memory path) internal {
        vm.prank(admin);
        registry.setRoute(asset, DividendRouteLib.encodeV3(path));
    }

    function _expectMalformed() internal {
        vm.expectRevert(RealmDividendSwapRegistry.MalformedRoute.selector);
    }

    /// @dev A fresh 1% AAPLon/WETH pool opened at the live 0.05% pool's price, holding one AAPLon-only
    ///      position just below it: a WETH-in swap walks straight into it, and the pool holds ~no WETH.
    function _oneSidedAaplPool() internal returns (address pool) {
        pool = IUniswapV3FactoryMin(V3_FACTORY).createPool(WETH, AAPLon, FEE_100);
        (, int24 tick,,,,,) = IUniswapV3PoolMin(AAPL_WETH_005).slot0();
        // WETH sorts first, so price is AAPLon per WETH and buying AAPLon moves the tick DOWN.
        int24 upper = (tick / 200) * 200;
        IUniswapV3PoolMin(pool).initialize(TickMath.getSqrtPriceAtTick(upper) - 1);
        deal(AAPLon, address(this), 1e24);
        IUniswapV3PoolMin(pool).mint(address(this), upper - 20_000, upper, 1e20, "");
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        if (owed0 > 0) deal(WETH, msg.sender, IERC20(WETH).balanceOf(msg.sender) + owed0);
        if (owed1 > 0) IERC20(AAPLon).transfer(msg.sender, owed1);
    }

    //////////////////////// admission //////////////////////

    /// @dev ⚠️ THE REGRESSION GUARD. An AAPLon/WETH pool holding essentially no WETH — its liquidity is
    ///      single-sided in the asset, which is what a sell-side maker looks like and what a buyer
    ///      wants. Any depth gate that read the quote-side balance would reject it. It converts fine.
    ///      Robinhood has no such pool at `BLOCKNUMBER`, so it is built: see `_oneSidedAaplPool()`.
    function test_aPoolHoldingAlmostNoQuoteTokenIsStillUsable() public {
        address pool = _oneSidedAaplPool();
        assertLt(IERC20(WETH).balanceOf(pool), 0.01 ether, "pool holds ~no WETH");

        _route(AAPLon, _path(WETH, FEE_100, AAPLon));

        vm.deal(address(this), 0.005 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1, recipient);
        assertGt(out, 0, "and yet it converts");
        assertEq(IERC20(AAPLon).balanceOf(recipient), out, "delivered in full");
    }

    //////////////////////// execution //////////////////////

    function test_singleHopConvertsAndTheRegistryKeepsNothing() public {
        _route(HOODon, _path(WETH, FEE_030, HOODon));

        vm.deal(address(this), 0.01 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.01 ether}(HOODon, 1, recipient);

        assertGt(out, 0, "bought something");
        assertEq(IERC20(HOODon).balanceOf(recipient), out, "recipient got exactly what was reported");
        assertEq(IERC20(HOODon).balanceOf(address(registry)), 0, "no asset retained");
        assertEq(address(registry).balance, 0, "no native retained");
    }

    /// @dev The two-hop case, and the whole reason multi-hop is supported: SPYon has no direct WETH
    ///      pool and is only reachable through USDG.
    function test_twoHopConvertsThroughTheIntermediate() public {
        _route(SPYon, _path(WETH, FEE_001, USDG, FEE_030, SPYon));

        vm.deal(address(this), 0.005 ether);
        uint256 out = registry.swapNativeToAsset{value: 0.005 ether}(SPYon, 1, recipient);

        assertGt(out, 0, "reached through USDG");
        assertEq(IERC20(SPYon).balanceOf(recipient), out, "delivered in full");
        assertEq(IERC20(USDG).balanceOf(address(registry)), 0, "the intermediate is not retained either");
    }

    /// @dev A floor the pool cannot meet reverts, so a dividend freeze keeps its buffer.
    function test_aMissedFloorRevertsAndSpendsNothing() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.deal(address(this), 0.005 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert();
        registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1_000_000e18, recipient);
        assertEq(address(this).balance, balanceBefore, "native never left");
    }

    /// @dev The V3 twin of the V4 partial-fill guard, and it needs its own check because the leftover is
    ///      WETH rather than native: `WRAP_ETH` funds the router in WETH before the swap, so whatever the
    ///      pool did not take stays there in wrapped form. Refuse the fill rather than book a full spend
    ///      against a half-spent swap. The real-pool tests above are the full-fill control.
    function test_aPartialV3FillIsRefusedInsteadOfStrandingTheRest() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        address router = registry.UNIV4_UNIVERSAL_ROUTER();
        vm.etch(router, address(new PartialFillV3RouterStub()).code);
        deal(AAPLon, router, 1000e18);

        vm.deal(address(this), 0.01 ether);
        uint256 balanceBefore = address(this).balance;
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.01 ether}(AAPLon, 1, recipient);

        assertEq(address(this).balance, balanceBefore, "the native never left the caller");
        assertEq(IERC20(AAPLon).balanceOf(recipient), 0, "and nothing was delivered on a half-spent swap");
    }

    /// @dev A route set on the wrong fee tier names a pool that does not exist. Nothing on-chain refuses
    ///      it at write time — the fork probe before listing is for that — but the swap fails loudly and
    ///      the route can be repointed.
    function test_aRouteOnTheWrongFeeTierFailsAtSwapTime() public {
        // AAPLon's WETH pool is on 0.05%; there is none on 0.3%.
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));

        vm.deal(address(this), 0.005 ether);
        vm.expectRevert(RealmDividendSwapRegistry.SwapFailed.selector);
        registry.swapNativeToAsset{value: 0.005 ether}(AAPLon, 1, recipient);
    }

    //////////////////////// isolation //////////////////////

    /// @dev Setting a route for one asset must not give any other asset one.
    function test_aRouteDoesNotDisturbAnotherAsset() public {
        _route(AAPLon, _path(WETH, FEE_030, AAPLon));
        assertEq(registry.routeOf(MSFT).length, 0, "MSFT has no route of its own");
    }

    //////////////////////// path validation //////////////////////

    function test_aPathThatDoesNotStartAtTheQuoteIsRejected() public {
        _expectMalformed();
        _route(AAPLon, _path(MSFT, FEE_030, AAPLon));
    }

    function test_aPathThatDoesNotEndAtTheAssetIsRejected() public {
        _expectMalformed();
        _route(AAPLon, _path(WETH, FEE_030, HOODon));
    }

    function test_aMalformedPathIsRejected() public {
        _expectMalformed();
        _route(AAPLon, abi.encodePacked(WETH, FEE_030)); // no destination
        _expectMalformed();
        _route(AAPLon, abi.encodePacked(WETH, FEE_030, AAPLon, hex"00")); // a trailing byte
    }

    /// @dev Three hops is refused: each extra hop is another pool that can drain, and the safety of a
    ///      two-hop route rests on its first leg being a major pool that will not.
    function test_aRouteLongerThanTwoHopsIsRejected() public {
        _expectMalformed();
        _route(SPYon, abi.encodePacked(WETH, FEE_001, USDG, FEE_005, MSFT, FEE_030, SPYon));
    }

    //////////////////////// discoverability + access //////////////////////

    /// @dev An indexer learns which pools an asset's conversions cross by replaying this event.
    function test_everyRouteChangeIsAnnounced() public {
        bytes memory route = DividendRouteLib.encodeV3(_path(WETH, FEE_030, AAPLon));

        vm.expectEmit(true, false, false, true, address(registry));
        emit RealmDividendSwapRegistry.DividendRouteSet(AAPLon, route);
        vm.prank(admin);
        registry.setRoute(AAPLon, route);
    }

    function test_aStrangerCannotSetARoute() public {
        vm.prank(stranger);
        vm.expectRevert(RealmDividendSwapRegistry.NotAdmin.selector);
        registry.setRoute(AAPLon, DividendRouteLib.encodeV3(_path(WETH, FEE_030, AAPLon)));
    }

    receive() external payable {}
}
