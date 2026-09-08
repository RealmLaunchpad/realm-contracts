// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator} from "test/launchpad/base.t.sol";
import {V2SwapHelpers} from "test/e2e/base/V2SwapHelpers.t.sol";
import {RealmTaxableTokenUniV2} from "src/tokens/RealmTaxableTokenUniV2.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {IRealmFactory} from "src/interfaces/IRealmFactory.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/IRealmTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

/// @notice Integration tests for the V2 liquidity earnings-allocation leg: the liquidity slice is set
///         aside as tax TOKENS during the swap-back, then `processLiquidity` sells half for ETH and adds
///         a locked LP position (token-native zap).
contract LiquidityTaxTokenV2Tests is LaunchpadBaseTestsWithUniv2Graduator, V2SwapHelpers {
    using stdStorage for StdStorage;

    function setUp() public override(LaunchpadBaseTests, LaunchpadBaseTestsWithUniv2Graduator) {
        super.setUp();
    }

    /// @dev Creates an ownerless V2 tax token with a `liquidityBps` allocation via the allocation-aware
    ///      `createToken` overload. 4%-configurable sell tax, creation-anchored 14-day window.
    function _createLiquidityV2Token(uint16 sellTaxBps, uint16 liquidityBps) internal returns (address token) {
        IRealmFactory.TokenSetupTiered memory setup = IRealmFactory.TokenSetupTiered({
            name: "LiqV2",
            symbol: "LV2",
            salt: _nextValidSalt(address(factoryV2Unified), address(realmTaxTokenV2)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: sellTaxBps,
            taxDurationSeconds: uint32(14 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 0, dividendsBps: 0, liquidityBps: liquidityBps, dividendToken: address(0)
            })
        });
        vm.prank(creator);
        token = factoryV2Unified.createToken(
            setup, cfg, _noSs(), _emptyAntiSniperCfg(), new IRealmFactory.CreatorVault[](0), address(0)
        );
    }

    function test_liquidityBps_storedAtCreation() public {
        address token = _createLiquidityV2Token(400, 5000);
        assertEq(RealmTaxableTokenUniV2(payable(token)).liquidityBps(), 5000, "liquidityBps stored via new overload");
    }

    function test_v2Liquidity_swapBackBuffersThenProcessAddsLp() public {
        address token = _createLiquidityV2Token(400, 5000); // 4% sell tax; 50% of earnings → liquidity
        testToken = token;
        RealmTaxableTokenUniV2 liqToken = RealmTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        // A single sell accrues sell tax as tokens on the contract (no auto swap-back yet).
        uint256 sellAmount = IERC20(token).balanceOf(buyer) / 10;
        _swapSellV2(buyer, token, sellAmount, 0, true);

        // Manual swap-back: burns none, sets aside the liquidity slice as TOKENS, swaps the rest to ETH.
        uint256 taxBalance = IERC20(token).balanceOf(address(liqToken));
        vm.prank(admin);
        liqToken.swapBack(taxBalance, 0);

        uint256 pendingTokens = liqToken.liquidityPendingTokens();
        assertGt(pendingTokens, 0, "liquidity tokens should be set aside by the swap-back");
        // The set-aside tokens are held on the contract but excluded from the tradable/tax balance.
        assertGe(IERC20(token).balanceOf(address(liqToken)), pendingTokens, "buffer backed by real balance");

        address pair = liqToken.pair();
        uint256 deadLpBefore = IERC20(pair).balanceOf(DEAD_ADDRESS);

        vm.recordLogs();
        liqToken.processLiquidity(0);
        (, uint256 tokensAdded) = _liquidityAddedAmounts(vm.getRecordedLogs());

        // Per-call cap: at most 2*SWAP_THRESHOLD processed; the remainder stays buffered (this buffer
        // exceeds the cap) and a same-block retry hits the cooldown. Only what LEFT the bucket is
        // debited: the half sold for the ETH side, plus the tokens the add actually deposited. The
        // token side the router refunds at the pool's live ratio stays earmarked for liquidity.
        uint256 cap = 2 * liqToken.SWAP_THRESHOLD();
        assertEq(liqToken.liquidityPendingTokens(), pendingTokens - cap / 2 - tokensAdded, "remainder stays buffered");
        assertGt(IERC20(pair).balanceOf(DEAD_ADDRESS), deadLpBefore, "LP minted and locked at the dead address");

        vm.expectRevert(RealmTaxableTokenUniV2.ProcessCooldown.selector);
        liqToken.processLiquidity(0);

        vm.roll(block.number + 1);
        uint256 buffered = liqToken.liquidityPendingTokens();
        vm.recordLogs();
        liqToken.processLiquidity(0);
        (, uint256 tokensAdded2) = _liquidityAddedAmounts(vm.getRecordedLogs());
        // Nothing left but that call's own ratio refund, which is still earmarked for the next one.
        assertEq(liqToken.liquidityPendingTokens(), buffered - buffered / 2 - tokensAdded2, "only the refund stays");
    }

    /// @dev `LiquidityAdded` must report the router's ACTUAL amounts, not the requested ones. The
    ///      half-sell moves the price, so the retained tokens + sale proceeds never match the pool ratio
    ///      and the router refunds the excess side — reporting the requested amounts would over-state
    ///      the added depth to the indexer.
    function test_v2ProcessLiquidity_eventReportsAmountsThatReachedThePair() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        RealmTaxableTokenUniV2 liqToken = RealmTaxableTokenUniV2(payable(token));

        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        _swapSellV2(buyer, token, IERC20(token).balanceOf(buyer) / 10, 0, true);
        uint256 taxBalance = IERC20(token).balanceOf(address(liqToken));
        vm.prank(admin);
        liqToken.swapBack(taxBalance, 0);

        uint256 pendingTokens = liqToken.liquidityPendingTokens();
        uint256 cap = 2 * liqToken.SWAP_THRESHOLD();
        uint256 processed = pendingTokens > cap ? cap : pendingTokens; // per-call cap
        uint256 tokensRequested = processed - processed / 2; // the half retained for the LP side

        vm.recordLogs();
        liqToken.processLiquidity(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Ground truth: the pair's own `Mint`, i.e. what the add actually deposited. Reserve deltas
        // can't serve here — the half-sell also pushes tokens into the pair within the same call.
        (uint256 mintTokens, uint256 mintEth) = _pairMintAmounts(logs, token < liqToken.WETH());
        (uint256 ethAdded, uint256 tokensAdded) = _liquidityAddedAmounts(logs);

        assertEq(tokensAdded, mintTokens, "tokensAdded == tokens the pair minted against");
        assertEq(ethAdded, mintEth, "ethAdded == WETH the pair minted against");
        // Non-vacuous: the 0.3% swap fee makes ETH the scarce side, so the router consumes all of it and
        // refunds part of the requested token side. Emitting the requested amount would over-state depth.
        assertLt(tokensAdded, tokensRequested, "router refunded part of the requested token side");
    }

    /// @dev `UniswapV2Pair.Mint(address indexed sender, uint amount0, uint amount1)`, returned as
    ///      (token side, WETH side). `tokenIsToken0` orders the pair by address, as V2 does.
    function _pairMintAmounts(Vm.Log[] memory logs, bool tokenIsToken0)
        internal
        pure
        returns (uint256 tokenAmount, uint256 ethAmount)
    {
        bytes32 sig = keccak256("Mint(address,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i - 1].data, (uint256, uint256));
                return tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
            }
        }
        revert("pair Mint not emitted");
    }

    /// @dev Decodes the `ethIn`/`tokensAdded` fields of the last `LiquidityAdded` in `logs`.
    function _liquidityAddedAmounts(Vm.Log[] memory logs) internal pure returns (uint256 ethIn, uint256 tokensAdded) {
        bytes32 sig = keccak256("LiquidityAdded(uint256,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == sig) {
                (ethIn, tokensAdded,) = abi.decode(logs[i - 1].data, (uint256, uint256, uint256));
                return (ethIn, tokensAdded);
            }
        }
        revert("LiquidityAdded not emitted");
    }

    function test_v2ProcessLiquidity_revertsWhenNothingPending() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.expectRevert(RealmTaxableTokenUniV2.NothingToAdd.selector);
        RealmTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }

    /// @dev The caller supplies the floor for the half-sell, so a permissionless caller could set it to
    ///      zero around their own price manipulation and keep almost the whole sell. See
    ///      `RealmKeepersRegistry`.
    function test_v2ProcessLiquidity_refusesANonKeeper() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        RealmTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }

    function test_v2ProcessLiquidity_revertsBeforeGraduation() public {
        address token = _createLiquidityV2Token(400, 5000);
        vm.expectRevert(RealmTaxableTokenUniV2.NotGraduated.selector);
        RealmTaxableTokenUniV2(payable(token)).processLiquidity(0);
    }

    /// @dev A buffer so small the half-sell rounds to zero tokens yields no native, so no LP is added —
    ///      but `liquidityPendingTokens` was already debited by the full amount at the top of the call.
    ///      Without the re-credit the retained half stops being tracked as liquidity money and rejoins
    ///      the general tax pool, where the next swap-back re-splits it into the burn / dividend / fund
    ///      buckets: an allocation the creator earmarked for pool depth, quietly spent elsewhere.
    function test_v2ProcessLiquidity_reCreditsTheBufferWhenTheHalfSellYieldsNothing() public {
        address token = _createLiquidityV2Token(400, 5000);
        testToken = token;
        vm.deal(buyer, 5 ether);
        vm.prank(buyer);
        launchpad.buyTokensWithExactEth{value: 1 ether}(token, 0, DEADLINE);
        _graduateToken();

        // One wei of token: `tokensToSell = 1 / 2 = 0`, so nothing is sold and nothing can be paired.
        stdstore.target(token).sig("liquidityPendingTokens()").checked_write(uint256(1));

        RealmTaxableTokenUniV2(payable(token)).processLiquidity(0);

        assertEq(
            RealmTaxableTokenUniV2(payable(token)).liquidityPendingTokens(),
            1,
            "the unpaired token stays earmarked for liquidity instead of leaking into the tax pool"
        );
    }
}
