// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "lib/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RealmAssetsWhitelist} from "src/access/RealmAssetsWhitelist.sol";
import {DeploymentAddressesEthereumMainnet as Mainnet} from "src/config/DeploymentAddresses.sol";

contract Coin is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Coin", "C") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @notice The assets whitelist on a mainnet fork: the owner appoints approvers and nothing else,
///         approvers list assets with a V4 price pool, and the rate is derived from that pool.
/// @dev Test pools open at tick 0 (one raw unit per raw unit), so every expected rate is exact.
contract RealmAssetsWhitelistTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant BLOCKNUMBER = 23327777;

    RealmAssetsWhitelist internal whitelist;
    IPoolManager internal manager = IPoolManager(Mainnet.UNIV4_POOL_MANAGER);
    PoolModifyLiquidityTest internal lp;

    address internal owner = makeAddr("owner");
    address internal approver = makeAddr("approver");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        whitelist = new RealmAssetsWhitelist(owner, address(manager));
        lp = new PoolModifyLiquidityTest(manager);
        vm.prank(owner);
        whitelist.setApprover(approver, true);
    }

    /// @dev Refunds of the native `_pool` overpays.
    receive() external payable {}

    /// @dev The real USDC/ETH 0.05% pool.
    function _usdcKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 500, 10, IHooks(address(0)));
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
    }

    /// @dev A pool of `a` and `b` opened at tick 0, with in-range liquidity when `funded`.
    function _pool(address a, address b, bool funded) internal returns (PoolKey memory key) {
        key = _key(a, b);
        manager.initialize(key, uint160(1 << 96));
        if (!funded) return key;
        for (uint256 i; i < 2; ++i) {
            address c = i == 0 ? a : b;
            if (c == address(0)) continue;
            deal(c, address(this), 1e30);
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

    function _list(address asset, PoolKey memory key) internal {
        vm.prank(approver);
        whitelist.setWhitelisted(asset, key);
    }

    function _expectListingReverts(address asset, PoolKey memory key) internal {
        vm.prank(approver);
        vm.expectRevert(RealmAssetsWhitelist.InvalidPricePool.selector);
        whitelist.setWhitelisted(asset, key);
    }

    /////////////////////////// access control ///////////////////////////

    function test_startsEmpty() public {
        RealmAssetsWhitelist fresh = new RealmAssetsWhitelist(owner, address(manager));
        assertEq(fresh.unitsPerNativeX18(USDC), 0, "nothing is whitelisted by default");
        assertFalse(fresh.isApprover(approver), "nobody is an approver by default");
        assertEq(fresh.owner(), owner, "owner set in the constructor");
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
        whitelist.setWhitelisted(USDC, _usdcKey());
    }

    function test_aStrangerCannotWhitelist() public {
        vm.prank(stranger);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(USDC, _usdcKey());
    }

    function test_aRevokedApproverCannotWhitelist() public {
        vm.prank(owner);
        whitelist.setApprover(approver, false);
        vm.prank(approver);
        vm.expectRevert(RealmAssetsWhitelist.NotApprover.selector);
        whitelist.setWhitelisted(USDC, _usdcKey());
    }

    /////////////////////////// pricing ///////////////////////////

    /// @dev Real USDC against real ETH liquidity: thousands of dollars per ETH, whatever USDC's 6 decimals.
    function test_listsRealUsdcAgainstNative() public {
        vm.expectEmit(false, true, false, false, address(whitelist));
        emit RealmAssetsWhitelist.WhitelistUpdated(USDC, 0, _usdcKey());
        _list(USDC, _usdcKey());

        uint256 rate = whitelist.unitsPerNativeX18(USDC);
        assertGt(rate, 1_000e18, "more than 1,000 USDC per ETH");
        assertLt(rate, 10_000e18, "less than 10,000 USDC per ETH");
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = whitelist.pricePool(USDC);
        assertEq(Currency.unwrap(c0), address(0), "full key stored: currency0");
        assertEq(Currency.unwrap(c1), USDC, "full key stored: currency1");
        assertEq(fee, 500, "full key stored: fee");
        assertEq(spacing, 10, "full key stored: tick spacing");
        assertEq(address(hooks), address(0), "full key stored: hooks");
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

    /// @dev Against a reference priced from native: one raw unit per raw USDC is USDC's own rate at 6
    ///      decimals, and 1e12 times fewer whole units at 18.
    function test_listsAgainstAReference() public {
        _list(USDC, _usdcKey());
        uint256 usdcRate = whitelist.unitsPerNativeX18(USDC);

        address coin6 = address(new Coin(6));
        address coin18 = address(new Coin(18));
        _list(coin6, _pool(coin6, USDC, true));
        _list(coin18, _pool(coin18, USDC, true));
        assertEq(whitelist.unitsPerNativeX18(coin6), usdcRate, "6 decimals: same whole units as USDC");
        assertEq(whitelist.unitsPerNativeX18(coin18), usdcRate / 1e12, "18 decimals: 1e12 raw per whole");
    }

    function test_rejectsAPoolWithoutTheAsset() public {
        _expectListingReverts(address(new Coin(18)), _usdcKey());
    }

    function test_rejectsAnUnlistedReference() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, USDC, true));
    }

    /// @dev One hop from native at most: a reference priced against another reference is refused.
    function test_rejectsAReferenceNotPricedAgainstNative() public {
        _list(USDC, _usdcKey());
        address ref = address(new Coin(18));
        _list(ref, _pool(ref, USDC, true));

        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, ref, true));
    }

    function test_rejectsAPoolThatDoesNotExist() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _key(coin, address(0)));
    }

    function test_rejectsAPoolWithoutLiquidity() public {
        address coin = address(new Coin(18));
        _expectListingReverts(coin, _pool(coin, address(0), false));
    }

    /// @dev An all-zero key removes the asset; the next listing brings it back.
    function test_anEmptyKeyDelists() public {
        _list(USDC, _usdcKey());
        PoolKey memory empty;
        _list(USDC, empty);
        assertEq(whitelist.unitsPerNativeX18(USDC), 0, "delisted");
        (, Currency c1,,,) = whitelist.pricePool(USDC);
        assertEq(Currency.unwrap(c1), address(0), "price pool cleared");

        _list(USDC, _usdcKey());
        assertGt(whitelist.unitsPerNativeX18(USDC), 0, "relisted");
    }
}
