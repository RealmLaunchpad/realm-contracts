// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {RealmAnyPairsDividendTrackerBasket} from "src/RealmAnyPairsDividendTrackerBasket.sol";

/// @notice Robinhood Chain mainnet fork: a reward basket leg paid in a REAL tokenized stock through a REAL V4 pool.
/// Every live NVDAx3L/USDG market on the chain sits behind a custom hook, so it cannot be discovered on-chain -- this
/// proves the round-107 supplied-route path end to end, and measures what a leg costs against LEG_GAS_CAP.
/// Run with: FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*" -vv
contract Round107RobinhoodForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDAX3L = 0xF51fb54DE60f6e16252E852A5Ed0E60B8307606A;
    address constant HOOK_1 = 0xeecA4C76149A73d8C4C8305Acb23EE336A4dC044;
    address constant HOOK_2 = 0x5dBeE30909fB681C9fE326Ac23a9037B7662C5c7;

    address alice = makeAddr("alice");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _key(address hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(NVDAX3L), 0, 1, IHooks(hook));
    }

    function _liveKey() internal view returns (PoolKey memory key, bool ok) {
        address[2] memory hooks = [HOOK_1, HOOK_2];
        uint128 bestLiq;
        for (uint256 i; i < 2; ++i) {
            PoolKey memory k = _key(hooks[i]);
            (uint160 sqrtP,,,) = PM.getSlot0(k.toId());
            if (sqrtP == 0) continue;
            uint128 liq = PM.getLiquidity(k.toId());
            if (liq > bestLiq) {
                bestLiq = liq;
                key = k;
                ok = true;
            }
        }
    }

    function _tracker() internal returns (RealmAnyPairsDividendTrackerBasket t) {
        RealmAnyPairsDividendTrackerBasket.Leg[] memory legs = new RealmAnyPairsDividendTrackerBasket.Leg[](1);
        legs[0] = RealmAnyPairsDividendTrackerBasket.Leg(NVDAX3L, 10_000);
        t = new RealmAnyPairsDividendTrackerBasket(
            RealmAnyPairsDividendTrackerBasket.Config({
                token: address(this),
                feeder: address(this),
                quote: USDG,
                swapRouter: address(0),
                v3Factory: address(0),
                poolManager: address(PM),
                minEligible: 1,
                excluded: new address[](0),
                basket: legs
            })
        );
        t.setBalance(alice, 1e18);
        deal(USDG, address(t), 10e6); // 10 USDG (6 decimals)
        t.feedToken(0);
    }

    function test_fork_hookedStockMarketIsNotDiscoverable() public {
        if (!forked) return;
        RealmAnyPairsDividendTrackerBasket t = _tracker();
        (,, bytes memory route) = t.basketLeg(0);
        assertEq(route.length, 0, "no hookless NVDAx3L/USDG pool: discovery finds nothing");
    }

    function test_fork_suppliedRouteDeliversTheStock() public {
        if (!forked) return;
        (PoolKey memory key, bool ok) = _liveKey();
        if (!ok) {
            console.log("no live NVDAx3L/USDG pool at this block; skipping");
            return;
        }
        RealmAnyPairsDividendTrackerBasket t = _tracker();
        uint256[] memory mins = new uint256[](1);
        mins[0] = 1; // non-zero: a failed leg reverts instead of quietly paying USDG
        bytes[] memory routes = new bytes[](1);
        routes[0] = abi.encode(key);

        uint256 before = IERC20(NVDAX3L).balanceOf(alice);
        uint256 g0 = gasleft();
        vm.prank(alice);
        t.claimWithRoutes(mins, routes);
        uint256 used = g0 - gasleft();
        uint256 got = IERC20(NVDAX3L).balanceOf(alice) - before;

        console.log("hook:", address(key.hooks));
        console.log("NVDAx3L received (raw):", got);
        console.log("claim gas used:", used);
        assertGt(got, 0, "the holder was paid in the stock");
        assertEq(IERC20(USDG).balanceOf(alice), 0, "and not in USDG");
    }
}
