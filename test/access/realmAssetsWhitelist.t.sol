// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "lib/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {DeploymentAddressesRobinhoodMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";

contract Coin is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Coin", "C") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @dev Answers every V2 and V3 pool read like the real WETH/USDG pool, but no Uniswap factory knows it.
contract LookalikePool {
    address public constant token0 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant token1 = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24 public constant fee = 100;
    uint128 public constant liquidity = 1e18;

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (3e21, 1e13, 0);
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 0, 0, 0, true);
    }
}

/// @notice The assets whitelist on a Robinhood mainnet fork: the owner appoints approvers and upgrades, approvers
///         list assets with a V2, V3 or V4 price pool, and the rate is derived from that pool.
/// @dev Test pools open at tick 0 (one raw unit per raw unit), so their expected rates are exact.
contract RealmAssetsWhitelistTest is Test {
    /// @dev Global Dollar, a 6-decimal USD stablecoin.
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev The real WETH/USDG pools on V2 and on V3 (0.01%).
    address constant USDG_WETH_V2 = 0x8803c117ccae7B5146297876c2A25DF135141C4d;
    address constant USDG_WETH_V3 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    uint256 constant BLOCKNUMBER = 58_000_000;

    RealmAssetsWhitelist internal whitelist;
    IPoolManager internal manager = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    PoolModifyLiquidityTest internal lp;

    address internal owner = makeAddr("owner");
    address internal approver = makeAddr("approver");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        whitelist = _deploy(Mainnet.UNIV2_FACTORY, Mainnet.UNIV3_FACTORY);
        lp = new PoolModifyLiquidityTest(manager);
    }

    /// @dev Refunds of the native `_pool` overpays.
    receive() external payable {}

    function _impl(address v2Factory, address v3Factory) internal returns (address) {
        return address(new RealmAssetsWhitelist(address(manager), Mainnet.WETH, v2Factory, v3Factory));
    }

    /// @dev A proxied whitelist with `approver` appointed.
    function _deploy(address v2Factory, address v3Factory) internal returns (RealmAssetsWhitelist w) {
        w = RealmAssetsWhitelist(
            address(
                new ERC1967Proxy(_impl(v2Factory, v3Factory), abi.encodeCall(RealmAssetsWhitelist.initialize, (owner)))
            )
        );
        vm.prank(owner);
        w.setApprover(approver, true);
    }

    function _v2(address pair) internal pure returns (RealmAssetsWhitelist.PriceSource memory s) {
        s.venue = RealmAssetsWhitelist.Venue.V2;
        s.pool = pair;
    }

    function _v3(address pool) internal pure returns (RealmAssetsWhitelist.PriceSource memory s) {
        s.venue = RealmAssetsWhitelist.Venue.V3;
        s.pool = pool;
    }

    function _v4(PoolKey memory key) internal pure returns (RealmAssetsWhitelist.PriceSource memory s) {
        s.venue = RealmAssetsWhitelist.Venue.V4;
        s.key = key;
    }

    /// @dev The real USDG/ETH 0.05% V4 pool.
    function _usdgV4() internal pure returns (RealmAssetsWhitelist.PriceSource memory) {
        return _v4(PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 500, 10, IHooks(address(0))));
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
    }

    /// @dev A V4 pool of `a` and `b` opened at tick 0, with in-range liquidity when `funded`.
    function _pool(address a, address b, bool funded) internal returns (RealmAssetsWhitelist.PriceSource memory) {
        PoolKey memory key = _key(a, b);
        manager.initialize(key, uint160(1 << 96));
        if (funded) {
            for (uint256 i; i < 2; ++i) {
                address c = i == 0 ? a : b;
                if (c == address(0)) continue;
                deal(c, address(this), 1e18); // USDG balances are uint64
                ERC20(c).approve(address(lp), type(uint256).max);
            }
            vm.deal(address(this), 1 ether);
            uint256 value = Currency.unwrap(key.currency0) == address(0) ? 1 ether : 0;
            lp.modifyLiquidity{value: value}(
                key,
                IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}),
                ""
            );
        }
        return _v4(key);
    }

    function _list(address asset, RealmAssetsWhitelist.PriceSource memory source) internal {
        vm.prank(approver);
        whitelist.setWhitelisted(asset, source);
    }

    function _expectListingReverts(address asset, RealmAssetsWhitelist.PriceSource memory source) internal {
        vm.prank(approver);
        vm.expectRevert(RealmAssetsWhitelist.InvalidPriceSource.selector);
        whitelist.setWhitelisted(asset, source);
    }

    /////////////////////////// access control ///////////////////////////

    function test_startsEmpty() public view {
        assertEq(whitelist.unitsPerNativeX18(USDG), 0, "nothing is whitelisted by default");
        assertFalse(whitelist.isApprover(stranger), "nobody else is an approver");
        assertEq(whitelist.owner(), owner, "owner set in the initializer");
    }

    function test_cannotBeInitializedTwiceNorThroughTheImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        whitelist.initialize(stranger);

        RealmAssetsWhitelist impl = RealmAssetsWhitelist(_impl(Mainnet.UNIV2_FACTORY, Mainnet.UNIV3_FACTORY));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(stranger);
    }

    function test_theOwnerAppointsApprovers() public {
        vm.expectEmit(address(whitelist));
        emit RealmAssetsWhitelist.ApproverSet(stranger, true);
        vm.prank(owner);
        whitelist.setApprover(stranger, true);
        assertTrue(whitelist.isApprover(stranger));
    }

    function test_anApproverCannotAppointApprovers() public {
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, approver));
        whitelist.setApprover(stranger, true);
    }

    /// @dev Unlike the keepers registry, the owner is NOT an approver implicitly.
    function test_theOwnerCannotWhitelist() public {
        vm.prank(owner);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(USDG, _usdgV4());
    }

    function test_aStrangerCannotWhitelist() public {
        vm.prank(stranger);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(USDG, _usdgV4());
    }

    function test_aRevokedApproverCannotWhitelist() public {
        vm.prank(owner);
        whitelist.setApprover(approver, false);
        vm.prank(approver);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(USDG, _usdgV4());
    }

    /////////////////////////// upgrades ///////////////////////////

    /// @dev Only the owner upgrades, and every listing survives it.
    function test_onlyTheOwnerUpgradesAndListingsSurvive() public {
        _list(USDG, _usdgV4());
        uint256 rate = whitelist.unitsPerNativeX18(USDG);
        address next = _impl(Mainnet.UNIV2_FACTORY, Mainnet.UNIV3_FACTORY);

        for (uint256 i; i < 2; ++i) {
            address caller = i == 0 ? approver : stranger;
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
            whitelist.upgradeToAndCall(next, "");
        }

        vm.prank(owner);
        whitelist.upgradeToAndCall(next, "");
        assertEq(whitelist.unitsPerNativeX18(USDG), rate, "rate survives");
        assertEq(uint8(whitelist.priceSource(USDG).venue), uint8(RealmAssetsWhitelist.Venue.V4), "source survives");
        assertTrue(whitelist.isApprover(approver), "approvers survive");
    }

    /////////////////////////// pricing ///////////////////////////

    /// @dev Real USDG on each venue: V4 against native, V2 and V3 against WETH, which prices as native.
    ///      The three spot prices agree within 1%, and the source is stored whole.
    function test_listsRealUsdgOnEveryVenue() public {
        vm.expectEmit(false, true, false, false, address(whitelist));
        emit RealmAssetsWhitelist.WhitelistUpdated(USDG, 0, _usdgV4());
        _list(USDG, _usdgV4());
        uint256 v4Rate = whitelist.unitsPerNativeX18(USDG);
        assertGt(v4Rate, 1_000e18, "more than 1,000 USDG per ETH");
        assertLt(v4Rate, 10_000e18, "less than 10,000 USDG per ETH");
        RealmAssetsWhitelist.PriceSource memory stored = whitelist.priceSource(USDG);
        assertEq(Currency.unwrap(stored.key.currency1), USDG, "full V4 key stored");
        assertEq(stored.key.fee, 500);
        assertEq(stored.key.tickSpacing, 10);

        _list(USDG, _v3(USDG_WETH_V3));
        assertApproxEqRel(whitelist.unitsPerNativeX18(USDG), v4Rate, 0.01e18, "V3 agrees with V4");
        assertEq(whitelist.priceSource(USDG).pool, USDG_WETH_V3, "V3 pool stored");
        assertEq(whitelist.referenceOf(USDG), address(0), "WETH prices as native");

        _list(USDG, _v2(USDG_WETH_V2));
        assertApproxEqRel(whitelist.unitsPerNativeX18(USDG), v4Rate, 0.01e18, "V2 agrees with V4");
        assertEq(uint8(whitelist.priceSource(USDG).venue), uint8(RealmAssetsWhitelist.Venue.V2), "venue stored");
    }

    /// @dev One raw unit per raw native: 1 per ETH at 18 decimals, 1e12 per ETH at 6. Decimals come from
    ///      the token, never from the approver.
    function test_rateIsInWholeUnitsAgainstNative() public {
        address coin18 = address(new Coin(18));
        address coin6 = address(new Coin(6));
        _list(coin18, _pool(coin18, address(0), true));
        _list(coin6, _pool(coin6, address(0), true));
        assertEq(whitelist.unitsPerNativeX18(coin18), 1e18);
        assertEq(whitelist.unitsPerNativeX18(coin6), 1e30);
    }

    /// @dev Against a reference priced from native (here through V3 and WETH): one raw unit per raw USDG
    ///      is USDG's own rate at 6 decimals, and 1e12 times fewer whole units at 18.
    function test_listsAgainstAReference() public {
        _list(USDG, _v3(USDG_WETH_V3));
        uint256 usdgRate = whitelist.unitsPerNativeX18(USDG);

        address coin6 = address(new Coin(6));
        address coin18 = address(new Coin(18));
        _list(coin6, _pool(coin6, USDG, true));
        _list(coin18, _pool(coin18, USDG, true));
        assertEq(whitelist.unitsPerNativeX18(coin6), usdgRate, "6 decimals: same whole units as USDG");
        assertEq(whitelist.unitsPerNativeX18(coin18), usdgRate / 1e12, "18 decimals: 1e12 raw per whole");
        assertEq(whitelist.referenceOf(coin6), USDG, "reference recorded");
    }

    /// @dev A contract answering like the real pool, which neither Uniswap factory knows.
    function test_rejectsALookalikePool() public {
        address fake = address(new LookalikePool());
        _expectListingReverts(USDG, _v2(fake));
        _expectListingReverts(USDG, _v3(fake));
    }

    /// @dev A chain without V2 or V3 refuses those sources, even for real pools.
    function test_rejectsAVenueNotDeployedHere() public {
        whitelist = _deploy(address(0), address(0));
        _expectListingReverts(USDG, _v2(USDG_WETH_V2));
        _expectListingReverts(USDG, _v3(USDG_WETH_V3));
        _list(USDG, _usdgV4());
        assertGt(whitelist.unitsPerNativeX18(USDG), 0, "V4 still lists");
    }

    function test_rejectsAPoolWithoutTheAsset() public {
        _expectListingReverts(address(new Coin(18)), _usdgV4());
        _expectListingReverts(address(new Coin(18)), _v3(USDG_WETH_V3));
        _expectListingReverts(address(new Coin(18)), _v2(USDG_WETH_V2));
    }

    function test_rejectsAnUnlistedReference() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, USDG, true));
    }

    /// @dev One hop from native at most: a reference priced against another reference is refused.
    function test_rejectsAReferenceNotPricedAgainstNative() public {
        _list(USDG, _usdgV4());
        address ref = address(new Coin(18));
        _list(ref, _pool(ref, USDG, true));

        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, ref, true));
    }

    function test_rejectsAPoolThatDoesNotExist() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _v4(_key(coin, address(0))));
    }

    function test_rejectsAPoolWithoutLiquidity() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, address(0), false));
    }

    /// @dev A `NONE` source removes the asset; the next listing brings it back.
    function test_aNoneSourceDelists() public {
        _list(USDG, _v3(USDG_WETH_V3));
        RealmAssetsWhitelist.PriceSource memory none;
        _list(USDG, none);
        assertEq(whitelist.unitsPerNativeX18(USDG), 0, "delisted");
        assertEq(whitelist.priceSource(USDG).pool, address(0), "price source cleared");

        _list(USDG, _usdgV4());
        assertGt(whitelist.unitsPerNativeX18(USDG), 0, "relisted");
    }
}
