// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RealmAnyPairsDividendTrackerAutoBasket as AB} from "src/RealmAnyPairsDividendTrackerAutoBasket.sol";
import {R108LockHarness} from "../Round108.t.sol";

/// @notice Robinhood Chain mainnet fork: rewards auto-converted into a REAL tokenized stock through its REAL hooked V4
/// pool, both out of swap and inside someone else's unlock, with the gas each takes and the gap between the fill and
/// the pool's spot price (what the slippage band has to absorb).
/// Run with: FORK_RPC_URL=<rpc> forge test --match-path "test/fork/Round108RobinhoodFork.t.sol" -vv
contract Round108RobinhoodForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NVDAX3L = 0xF51fb54DE60f6e16252E852A5Ed0E60B8307606A;
    address constant HOOK_1 = 0xeecA4C76149A73d8C4C8305Acb23EE336A4dC044;
    address constant HOOK_2 = 0x5dBeE30909fB681C9fE326Ac23a9037B7662C5c7;
    uint256 constant AMOUNT = 10e6; // 10 USDG

    address alice = makeAddr("alice");
    bool forked;

    function creatorOfCoin(address) external view returns (address) {
        return address(this);
    }

    function inSwapAllowed(address) external pure returns (uint256) {
        return 1;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _liveKey() internal view returns (PoolKey memory key, bool ok) {
        address[2] memory hooks = [HOOK_1, HOOK_2];
        uint128 bestLiq;
        for (uint256 i; i < 2; ++i) {
            PoolKey memory k = PoolKey(Currency.wrap(USDG), Currency.wrap(NVDAX3L), 0, 1, IHooks(hooks[i]));
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

    function _tracker(PoolKey memory key) internal returns (AB t) {
        t = _trackerFor(key, AMOUNT);
    }

    function _trackerFor(PoolKey memory key, uint256 amount) internal returns (AB t) {
        AB.Leg[] memory legs = new AB.Leg[](1);
        legs[0] = AB.Leg(NVDAX3L, 10_000);
        AB.InputBasket[] memory ins = new AB.InputBasket[](1);
        ins[0] = AB.InputBasket(USDG, legs);
        AB.Config memory c;
        c.token = address(this);
        c.feeder = address(this);
        c.poolManager = address(PM);
        c.minEligible = 1;
        c.excluded = new address[](0);
        c.inputs = ins;
        t = new AB(c);
        t.setBalance(alice, 1e18);
        t.setRoute(USDG, NVDAX3L, abi.encode(key));
        deal(USDG, address(t), amount);
        t.feedToken(0);
    }

    /// @dev The same spot math the tracker uses (USDG sorts below NVDAx3L, so USDG -> NVDAx3L is zeroForOne).
    function _spot(PoolKey memory key, uint256 amount) internal view returns (uint256 out) {
        (uint160 sqrtP,,, uint24 lpFee) = PM.getSlot0(key.toId());
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        out = FullMath.mulDiv(ratioX192, amount, 1 << 192);
        out = (out * (1_000_000 - lpFee)) / 1_000_000;
    }

    /// @dev Converts `amount` at the widest band and logs the fill as bps of spot: separates a hook fee (the same
    /// ratio at every size) from thin liquidity (a ratio that improves as the size shrinks).
    function _measure(PoolKey memory key, uint256 amount) internal returns (uint256 fillBps) {
        AB t = _trackerFor(key, amount);
        t.setSlippageBps(2_000);
        uint256 spot = _spot(key, amount);
        uint256 g0 = gasleft();
        t.convertStep();
        uint256 used = g0 - gasleft();
        uint256 got = t.claimableOf(alice, NVDAX3L);
        fillBps = spot == 0 ? 0 : (got * 10_000) / spot;
        console.log("USDG in (raw):", amount);
        console.log("  spot NVDAx3L:", spot);
        console.log("  converted NVDAx3L:", got);
        console.log("  fill, bps of spot:", fillBps);
        console.log("  convertStep gas, out of swap:", used);
    }

    function test_fork_defaultBandRefusesThisPool() public {
        if (!forked) return;
        (PoolKey memory key, bool ok) = _liveKey();
        if (!ok) return;
        AB t = _tracker(key);
        t.convertStep();
        assertEq(t.buffered(USDG), AMOUNT, "the fill is too far below spot for the default 3%");
        assertGt(t.failingSince(0), 0, "and the fallback clock started");
    }

    function test_fork_fillVsSpotAtTwoSizes() public {
        if (!forked) return;
        (PoolKey memory key, bool ok) = _liveKey();
        if (!ok) return;
        uint256 big = _measure(key, AMOUNT);
        uint256 small = _measure(key, AMOUNT / 100);
        assertGt(big, 0, "converted at 20%");
        assertGt(small, 0, "converted at 20%");
    }

    function test_fork_autoConvertsIntoTheStock_insideASwap() public {
        if (!forked) return;
        (PoolKey memory key, bool ok) = _liveKey();
        if (!ok) return;
        AB t = _tracker(key);
        t.setSlippageBps(2_000);
        R108LockHarness h = new R108LockHarness(PM);
        h.run(address(t), address(0), 650_000);
        console.log("convertStep gas, inside an unlock:", h.gasUsed());
        console.log("converted NVDAx3L:", t.claimableOf(alice, NVDAX3L));
        assertTrue(h.callOk());
        assertEq(t.buffered(USDG), 0, "converted inside someone else's unlock");
    }
}
