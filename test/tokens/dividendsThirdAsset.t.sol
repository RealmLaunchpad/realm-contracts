// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {DeploymentAddressesEthereumMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {LivoDividendSwapRegistry} from "src/dividends/LivoDividendSwapRegistry.sol";
import {SwapRejection} from "src/interfaces/ILivoDividendSwapRegistry.sol";
import {installDividendSwapRegistry, DEFAULT_DIVIDEND_POOL_LIQUIDITY} from "test/helpers/DividendRegistryHelpers.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";

/// @notice A bare `DividendDistributionLogic` with the token's hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against real Uniswap pools without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistributionLogic {
    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    function configure(address asset) external {
        _initializeDividends(asset);
    }

    function activate() external {
        _activateDividends();
    }

    function accrue() external payable {
        _accrueDividends(msg.value);
    }

    function setBalance(address account, uint256 value) external {
        eligibleSupply = eligibleSupply + value - balances[account];
        balances[account] = value;
    }

    function _dividendBalanceOf(address account) internal view override returns (uint256) {
        return balances[account];
    }

    function _dividendExcluded(address) internal pure override returns (bool) {
        return false;
    }

    function _dividendEligibleSupply() internal view override returns (uint256) {
        return eligibleSupply;
    }

    receive() external payable {}
}

/// @notice A payout asset whose `transfer` never returns. The registry vets an asset's LIQUIDITY, never
///         its behaviour, so a token like this can pass creation and then meet a keeper batch.
contract GasBombToken {
    fallback() external {
        while (true) {}
    }
}

/// @notice A payout asset whose `transfer` succeeds but returns a huge buffer. The callee's memory
///         expansion is paid inside the stipend; the CALLER's `returndatacopy` is not, so a naive
///         `(bool, bytes memory)` call would make the payout unaffordable for the caller instead.
contract ReturnBombToken {
    fallback() external {
        assembly {
            let w := 0
            for {} 1 {} {
                w := add(w, 512)
                mstore(mul(w, 32), 0)
                if lt(gas(), 60000) { break }
            }
            return(0, mul(w, 32))
        }
    }
}

/// @notice An ERC20 with no pool anywhere, standing in for an asset a creator names without liquidity.
contract GhostToken is ERC20 {
    constructor() ERC20("Ghost", "GHOST") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice The third-token payout shape: an accrued native buffer is converted into an arbitrary ERC20
///         through `LivoDividendSwapRegistry`, and pushed to holders in that asset. Any ERC20 with a
///         deep enough Uniswap V2 pair qualifies — there is no asset whitelist and no per-asset
///         approval, only the liquidity the registry measures.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    DividendHarness internal harness;
    LivoDividendSwapRegistry internal registry;

    address internal holder = makeAddr("holder");
    address internal registryOwner = makeAddr("registryOwner");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(registryOwner);
        installKeepersRegistry(registryOwner, address(this));
        harness = _harness(DAI);
    }

    /// @dev A harness paying `asset`, configured and ready to be activated.
    function _harness(address asset) internal returns (DividendHarness h) {
        h = new DividendHarness();
        h.configure(asset);
    }

    function _fundAndActivate(DividendHarness h) internal {
        h.setBalance(holder, 1_000e18);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
    }

    /// @dev Lets a funded stream run all the way out, so the sole holder has accrued the whole of it.
    function _drain(DividendHarness h) internal {
        skip(h.DIVIDEND_DRIP_DURATION());
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = holder;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    /// @dev Ages the token past `STALE_DIVIDEND_WINDOW`, the gate the treasury sweep sits behind. Only a
    ///      token that has been UNABLE to distribute for that long reaches it — every successful
    ///      distribution pushes `dividendPeriodFinish` forward — which is what makes the sweep condition
    ///      persistent rather than a snapshot anyone can manufacture inside one transaction.
    function _goStale(DividendHarness h) internal {
        skip(h.STALE_DIVIDEND_WINDOW() + 1);
    }

    /// @dev The treasury sweep needs the zero-floor failure on record from an EARLIER block, so the first
    ///      call only records it and still reports `DividendConversionFailed`. This makes that call and
    ///      moves to the next block, leaving the harness one call away from sweeping.
    function _recordFailedConversion(DividendHarness h) internal {
        // Returns quietly rather than reverting: the call WROTE the marker, and `DividendConversionFailed`
        // would have rolled it straight back.
        h.processDividends(0, _noHolders());
        assertEq(h.failedConversionBlock(), block.number, "the failure is on record");
        vm.roll(block.number + 1);
    }

    //////////////////////// the payout shape //////////////////////

    function test_thirdAsset_boughtOnFundingAndStreamedToHolders() public {
        _fundAndActivate(harness);
        assertEq(harness.pendingNative(), 1 ether, "native buffered for the DAI payout");

        harness.processDividends(0, _noHolders());

        uint256 pot = harness.dividendsOwed();
        assertGt(pot, 0, "native converted into DAI");
        // A swapping payout converts at most `MAX_DIVIDEND_PER_CONVERSION` at a time; the rest stays
        // buffered.
        assertEq(harness.pendingNative(), 1 ether - harness.MAX_DIVIDEND_PER_CONVERSION(), "only the cap was converted");
        assertEq(IERC20(DAI).balanceOf(address(harness)), pot, "the distribution is a real DAI balance");
        // What every sweep path subtracts: an undelivered third-asset payout is COMMITTED, not stray, so
        // `rescueTokens` cannot hand holders' money to the owner while it is still owed.
        assertEq(harness.committedDividends(DAI), pot, "the whole of it is owed to holders");

        // It arrives as a SLOPE, not a drop: nothing is claimable at the instant of funding. (This call
        // converts the next capped slice too, which is why the total owed is re-read below.)
        harness.processDividends(0, _holders());
        assertEq(IERC20(DAI).balanceOf(holder), 0, "nothing accrues in zero seconds");

        _drain(harness);
        uint256 owed = harness.dividendsOwed();
        harness.processDividends(0, _holders());

        assertApproxEqRel(IERC20(DAI).balanceOf(holder), owed, 1e12, "sole holder paid the whole stream, in DAI");
        // What is still owed is the slice this very call converted, not an undelivered remainder of the
        // one that just drained: a payout call funds the next stream on its way through.
        assertApproxEqRel(
            harness.committedDividends(DAI), harness.dividendsOwed(), 1e12, "only the freshly-funded slice is owed"
        );
    }

    /// @dev The per-conversion cap bounds one sandwich, it does not cap what a token can ever pay:
    ///      whatever it leaves behind stays buffered and converts on a later call, so nothing strands.
    function test_thirdAsset_cappedConversionLeavesTheRemainderBuffered() public {
        _fundAndActivate(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();

        harness.processDividends(0, _holders());
        assertEq(harness.pendingNative(), 1 ether - cap, "the first conversion took exactly the cap");

        vm.roll(block.number + 1); // the funding leg is once per block
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - 2 * cap, "and the next one takes the next slice");
    }

    //////////////////////// the liquidity proof //////////////////////

    /// @dev THE eligibility rule, and the only one. Any ERC20 is fair game as long as the pool the
    ///      creator names for it actually exists and is worth swapping against — no whitelist, no admin.
    function test_anyErc20WithADeepPoolIsConfigurable() public {
        assertEq(_harness(DAI).dividendToken(), DAI, "DAI");
        assertEq(_harness(USDC).dividendToken(), USDC, "USDC");
    }

    /// @dev An asset nobody has ever made a market for is refused at creation, not left to accrue into a
    ///      buffer that could never be converted — the failure mode a clone cannot be patched out of.
    function test_anAssetWithNoPoolAtAllIsRejected() public {
        address ghost = address(new GhostToken());

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.NoPair)
        );
        h.configure(ghost);
    }

    /// @dev A pool that EXISTS but is too thin is refused just the same. The floor is denominated in the
    ///      quote asset, so it means the same thing whatever the payout asset's own decimals are.
    function test_aPoolTooThinToSwapAgainstIsRejected() public {
        GhostToken thin = new GhostToken();
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);

        // A real pair on the real factory, seeded with less than the floor.
        uint256 seeded = DEFAULT_DIVIDEND_POOL_LIQUIDITY / 2;
        vm.deal(address(this), seeded);
        thin.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: seeded}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.InsufficientLiquidity
            )
        );
        h.configure(address(thin));

        // Top the same pair up over the floor and the very same asset becomes eligible. Nothing about
        // the ASSET changed — only its liquidity, which is the whole rule.
        vm.deal(address(this), seeded + 1);
        router.addLiquidityETH{value: seeded + 1}(address(thin), 500_000e18, 0, 0, address(this), block.timestamp);

        DividendHarness ok = new DividendHarness();
        ok.configure(address(thin));
        assertEq(ok.dividendToken(), address(thin), "eligible once the pool is deep enough");
    }

    /// @dev An asset whose only liquidity lives on V3 or V4 has no V2 pair, so it is refused — the
    ///      deliberate cost of a V2-only registry, and the reason the registry is upgradeable.
    function test_anAssetWithoutAV2PairIsRejectedEvenIfItTradesElsewhere() public {
        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.NoPair)
        );
        h.configure(makeAddr("v4OnlyToken"));
    }

    /// @dev Native and the token itself buy nothing, so they never touch the registry.
    function test_nativeAndSelfTokenNeedNoProof() public {
        DividendHarness nativeH = new DividendHarness();
        nativeH.configure(address(0));
        assertEq(nativeH.dividendToken(), address(0), "native configured");

        DividendHarness selfH = new DividendHarness();
        selfH.configure(selfH.DIVIDEND_SELF_TOKEN());
        assertEq(selfH.dividendToken(), address(selfH), "the sentinel resolved to the token itself");
    }

    //////////////////////// what the registry buys //////////////////////

    /// @dev The point of putting the rule behind a proxy: a threshold raised AFTER a token was created
    ///      still governs it. A creation-time check compiled into an unpatchable clone could not.
    function test_aRaisedThresholdRefusesAssetsThatUsedToQualify() public {
        assertTrue(registry.isSwapSupported(registry.nativeQuoteToken(), DAI), "DAI qualifies today");

        vm.prank(registryOwner);
        registry.setDefaultThreshold(type(uint128).max);

        DividendHarness h = new DividendHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                DividendDistribution.DividendAssetNotSupported.selector, SwapRejection.InsufficientLiquidity
            )
        );
        h.configure(DAI);
    }

    /// @dev The one admin veto, and it reaches tokens that ALREADY exist: an asset blacklisted after a
    ///      token was configured for it stops converting on the next distribution.
    /// @dev ⚠️ The veto is NOT a pause for the buffer. A blacklisted asset fails a zero-floor swap exactly
    ///      the way a dead pool does, so a keeper calling `processDividends(0, ...)` while the veto is up
    ///      sweeps a capped slice to the treasury each time. The sweep condition is deliberately the swap
    ///      itself, with no reason code consulted, so an admin lifting the veto later recovers only what
    ///      keepers have not already swept. Livo owns both ends of that, which is what makes it tolerable.
    function test_blacklistingAnAssetHoldsTheBufferUntilTheVetoLifts() public {
        _fundAndActivate(harness);

        // Read the constant BEFORE the prank: `vm.prank` applies to the next call, view calls included.
        uint8 blacklisted = registry.TRUST_BLACKLISTED();
        vm.prank(registryOwner);
        registry.setTrustStatus(DAI, blacklisted);

        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.DIVIDEND_TREASURY().balance, treasuryBefore, "a live veto sweeps nothing");
        assertEq(harness.pendingNative(), 1 ether, "the whole buffer waits for the veto to lift");

        uint8 unknown = registry.TRUST_UNKNOWN();
        vm.prank(registryOwner);
        registry.setTrustStatus(DAI, unknown);
        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "and it converts in full once the veto is lifted");
    }

    /// @dev The registry is a swap venue, not a vault: it forwards everything it buys inside the same
    ///      call and is empty before and after.
    function test_theRegistryHoldsNothing() public {
        _fundAndActivate(harness);
        // A DELTA, not zero: the registry constant is `address(0)` until the proxy is deployed, and on a
        // mainnet fork that address already holds every ETH ever burned to it.
        uint256 registryBalanceBefore = address(registry).balance;
        uint256 registryDaiBefore = IERC20(DAI).balanceOf(address(registry));
        harness.processDividends(0, _noHolders());

        assertEq(address(registry).balance, registryBalanceBefore, "no native retained");
        assertEq(IERC20(DAI).balanceOf(address(registry)), registryDaiBefore, "no asset retained");
        assertEq(IERC20(DAI).balanceOf(address(harness)), harness.dividendsOwed(), "it all reached the token");
    }

    //////////////////////// conversion failures //////////////////////

    /// @dev `minOut` is what bounds the swap. A floor the pool cannot meet leaves the buffer untouched —
    ///      and says so precisely: the money IS there, the swap is the problem, so the keeper is told to
    ///      retry rather than to wait for earnings it already has.
    function test_aMissedSlippageFloorLeavesTheBufferUntouched() public {
        _fundAndActivate(harness);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(1_000_000e18, _noHolders());

        assertEq(harness.pendingNative(), 1 ether, "nothing was spent");
        assertEq(harness.dividendsOwed(), 0, "and no stream was funded");

        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "the same buffer converts once the floor is reachable");
    }

    /// @dev A raw `call` to an address with no code SUCCEEDS and keeps the value. If the registry constant
    ///      is ever wrong — or the registry is deployed after the token implementations — the conversion
    ///      must fail closed rather than hand the buffer to a codeless address on every call.
    function test_aCodelessRegistryFailsClosedInsteadOfBurningTheBuffer() public {
        _fundAndActivate(harness);
        vm.etch(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY, hex"");
        _goStale(harness); // the sweep is gated on staleness; a codeless registry never lets a stream run

        // A call CARRYING holders never reverts for a broken swap, so nothing rolls the transfer back:
        // this is the shape in which a codeless registry would silently pocket the buffer, every call.
        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;
        uint256 registryBalanceBefore = DeploymentAddresses.DIVIDEND_SWAP_REGISTRY.balance;
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();
        // A call carrying holders reports nothing, so the first one only records the failure.
        harness.processDividends(0, _holders());
        vm.roll(block.number + 1);
        harness.processDividends(0, _holders());

        // The point of the guard: the native went to the treasury, which can hand it back, instead of to
        // a codeless address, which cannot. Without it the raw `call` would have succeeded and kept it.
        assertEq(
            DeploymentAddresses.DIVIDEND_SWAP_REGISTRY.balance,
            registryBalanceBefore,
            "the codeless address got nothing"
        );
        assertEq(harness.DIVIDEND_TREASURY().balance - treasuryBefore, cap, "the treasury caught it instead");
        assertEq(harness.pendingNative(), 1 ether - cap, "and only the attempted slice left the buffer");
        assertEq(harness.dividendsOwed(), 0, "no stream was funded");
    }

    /// @dev A token that simply has not earned enough yet reports the OTHER error: the keeper is told to
    ///      wait, not sent looking for a broken pool.
    function test_aBelowThresholdBufferReportsBelowDividendThreshold() public {
        harness.setBalance(holder, 1_000e18);
        harness.activate();
        vm.deal(address(this), 1 wei);
        harness.accrue{value: 1 wei}();

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        harness.processDividends(0, _noHolders());
    }

    /// @dev A payout asset that returns a non-boolean word from `transfer` must be TOLERATED, not
    ///      decoded strictly. `abi.decode(_, (bool))` reverts on any word above 1, which is legal for a
    ///      non-standard ERC20 — and a revert inside `_payDividend` is precisely what the skip-don't-revert
    ///      contract exists to prevent: it would take down the whole `processDividends` batch and
    ///      `claimDividends` for everyone.
    function test_aNonBooleanTransferReturnDoesNotBrickTheBatch() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // buy DAI, fund the stream
        _drain(harness);

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder has accrued the stream");
        vm.mockCall(DAI, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(uint256(2)));

        vm.expectEmit(true, true, true, true, address(harness));
        emit DividendDistribution.DividendPaid(holder, DAI, owed);
        harness.processDividends(0, _holders());

        assertEq(harness.previewDividend(holder), 0, "the payout was accepted, not skipped");
    }

    //////////////////////// the funding cooldown //////////////////////

    /// @dev The per-call cap only bounds a manipulated block if the block allows ONE conversion. Without
    ///      this gate a caller re-enters at the same distorted price until the buffer is gone, paying the
    ///      manipulation cost once instead of once per block — the same argument `processBurn` and
    ///      `processLiquidity` already make with their own cooldowns.
    function test_theFundingLegIsOncePerBlock() public {
        _fundAndActivate(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();

        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - cap, "the first conversion went through");

        vm.expectRevert(DividendDistribution.DividendProcessCooldown.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - cap, "and a second one in the same block converts nothing");

        vm.roll(block.number + 1);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether - 2 * cap, "the next block converts again");
    }

    /// @dev The gate is on FUNDING alone. A keeper splitting a large holder set across several
    ///      transactions in one block is ordinary, and those calls read a buffer the first already
    ///      resolved — rate-limiting them would rate-limit paying people.
    function test_theCooldownDoesNotBlockPayouts() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders());
        _drain(harness);

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder accrued the stream");

        // Same block as the funding call above: it must pay, not revert.
        harness.processDividends(0, _holders());
        assertEq(IERC20(DAI).balanceOf(holder), owed, "paid in full despite the funding cooldown");
    }

    /// @dev The block is claimed only when the buffer actually MOVED. A call whose swap failed spent
    ///      nothing, so it must not lock the block against an honest keeper with a better floor.
    function test_aFailedConversionDoesNotClaimTheBlock() public {
        _fundAndActivate(harness);

        // Carries holders, so a failed conversion reports rather than reverts — the shape that would
        // otherwise leave a marker behind.
        harness.processDividends(1_000_000e18, _holders());
        assertEq(harness.pendingNative(), 1 ether, "nothing was spent");

        harness.processDividends(0, _noHolders());
        assertEq(
            harness.pendingNative(),
            1 ether - harness.MAX_DIVIDEND_PER_CONVERSION(),
            "a reachable floor still converts in the same block"
        );
    }

    //////////////////////// the payout gas bound //////////////////////

    /// @dev Both payout shapes are gas-bounded, for the same reason and with different numbers. The
    ///      payout asset is the creator's choice and the registry only ever vetted its liquidity, so an
    ///      unbounded `transfer` would burn 63/64 of the batch's gas on ONE holder and starve the rest —
    ///      and `claimDividends` with it. Capped, it degrades into the ordinary skip: the holder is not
    ///      paid, keeps every unit accrued, and the batch carries on.
    function test_aGasBombPayoutAssetCannotStarveTheBatch() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // buy DAI, fund the stream
        _drain(harness);

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder accrued the stream");

        // Etched AFTER the conversion, and called in the SAME block as it, so the funding leg is under
        // its own cooldown and never touches the bomb — only the payout leg does.
        vm.etch(DAI, type(GasBombToken).runtimeCode);

        uint256 before = gasleft();
        harness.processDividends(0, _holders());
        uint256 used = before - gasleft();

        assertLt(used, 2 * harness.ASSET_PAYOUT_GAS(), "the bomb was capped, not handed the whole batch");
        assertEq(harness.previewDividend(holder), owed, "and the unpaid holder keeps every unit accrued");
    }

    //////////////////////// the dead-pool escape //////////////////////

    /// @dev Nobody can repair a dead pool, and a buffer that can never be converted must not sit owed to
    ///      holders forever. Once a zero-floor swap comes back empty — the proof that the pool cannot
    ///      produce a single wei at ANY price, on a token that has been unable to distribute for a whole
    ///      `STALE_DIVIDEND_WINDOW` — that slice goes to the treasury and the call reports success instead
    ///      of reverting.
    function test_aPermanentlyDeadPoolSweepsTheBufferToTheTreasury() public {
        _fundAndActivate(harness);
        _killTheV2Router();
        _goStale(harness);
        _recordFailedConversion(harness);

        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();

        vm.expectEmit(true, false, false, true, address(harness));
        emit DividendDistribution.DividendBufferSweptToTreasury(DAI, cap);
        harness.processDividends(0, _noHolders()); // must NOT revert

        assertEq(harness.DIVIDEND_TREASURY().balance - treasuryBefore, cap, "the treasury caught the slice");
        assertEq(harness.pendingNative(), 1 ether - cap, "and only the converted slice left the buffer");
    }

    /// @dev The sweep changes NOTHING that holders hold. It moves native that was still waiting to be
    ///      converted and therefore had never been streamed to anyone — the payout asset, the accumulator
    ///      and every unclaimed accrual survive it untouched. That is the whole reason it replaced a
    ///      downgrade, which had to write those accruals off to stay coherent.
    function test_theSweepDoesNotTouchWhatHoldersHaveAlreadyAccrued() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // a real DAI stream
        _drain(harness);

        uint256 daiOwed = harness.previewDividend(holder);
        uint256 owedBefore = harness.dividendsOwed();
        assertGt(daiOwed, 0, "the holder accrued DAI it never claimed");

        _killTheV2Router();
        _goStale(harness);
        vm.roll(block.number + 1); // the funding leg above already claimed this block
        vm.deal(address(this), 1 ether);
        harness.accrue{value: 1 ether}();
        _recordFailedConversion(harness);
        harness.processDividends(0, _noHolders());

        assertEq(harness.dividendToken(), DAI, "the payout asset is never repointed");
        assertEq(harness.previewDividend(holder), daiOwed, "the DAI claim survives the sweep");
        assertEq(harness.dividendsOwed(), owedBefore, "and so does what the token owes");
        assertEq(harness.committedDividends(DAI), owedBefore, "the DAI stays holders' money, not rescuable");

        // The holder can still take it: claiming never depended on the pool being alive.
        vm.roll(block.number + 1);
        harness.processDividends(0, _holders());
        assertEq(IERC20(DAI).balanceOf(holder), daiOwed, "paid in full, in the asset they accrued");
    }

    //////////////////////// weird payout assets //////////////////////

    /// @dev The accumulator's scale comes from the PAYOUT ASSET's decimals, not from a fixed 1e18. With
    ///      1e18 against a 1e27 supply, one accumulator step was worth 1e9 asset units — 1000 USDC — so
    ///      every increment of a realistic distribution truncated to zero and a 6-decimal payout streamed
    ///      NOTHING while `dividendsOwed` kept counting it. USDC is a first-class payout asset here.
    function test_aSixDecimalPayoutAssetStreamsTheWholeDistribution() public {
        DividendHarness h = _harness(USDC);
        assertEq(h.dividendPrecisionExp(), 30, "36 - 6, so one step is 1e-18 of a whole USDC");

        // A realistic graduated token: 1e27 supply, most of it outside the pair, and one holder.
        h.setBalance(holder, 8e26);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        h.processDividends(0, _noHolders());

        uint256 streamed = h.dividendsOwed();
        assertGt(streamed, 0, "the conversion bought USDC");

        _drain(h);
        h.processDividends(0, _holders());
        // Not exact: the accumulator truncates towards the protocol at every step, which is what keeps
        // the stream solvent. What matters is that the loss is dust rather than the whole distribution.
        assertApproxEqRel(IERC20(USDC).balanceOf(holder), streamed, 0.0001e18, "the sole holder got it all");
    }

    /// @dev `DAI` is unchanged by the same rule — an 18-decimal asset keeps the scale it always had, so
    ///      nothing about the existing shape moved.
    function test_anEighteenDecimalPayoutAssetKeepsTheOriginalScale() public {
        assertEq(harness.dividendPrecisionExp(), 18, "36 - 18");
        assertEq(_harness(address(0)).dividendPrecisionExp(), 18, "native is 18-decimal too");
    }

    /// @dev `claimDividends` forwards `gasleft()`, and under EIP-150 the callee always receives 63/64 of
    ///      it — far more than the caller keeps. An asset that expands memory before returning would
    ///      therefore make the caller's returndata copy unaffordable and revert the claim whatever gas the
    ///      holder supplied, killing the one payout route that is supposed to always work. The payout call
    ///      copies at most one word, so the bomb costs the caller nothing and just reports failure.
    function test_aReturnBombingAssetCannotBrickTheSelfServeClaim() public {
        DividendHarness h = _harness(DAI);
        h.setBalance(holder, 1_000e18);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        h.processDividends(0, _noHolders());
        _drain(h);

        vm.etch(DAI, address(new ReturnBombToken()).code);
        assertGt(h.previewDividend(holder), 0, "the holder has accrued");

        uint256 accrued = h.previewDividend(holder);
        vm.prank(holder);
        h.claimDividends{gas: 5_000_000}(); // must not revert
        assertEq(h.previewDividend(holder), accrued, "unpaid, but the accrual is intact for a later try");
    }

    /// @dev A snapshot is not a proof. Anyone can empty a pool for the length of one transaction and put
    ///      it back after, so a single failed zero-floor swap must not hand the buffer over. Staleness
    ///      narrows it: every SUCCESSFUL distribution pushes `dividendPeriodFinish` forward, so an
    ///      actively distributing token never reaches the gate. It narrows rather than closes — a healthy
    ///      pool no keeper has called for a month is stale too — which is the accepted limit spelled out
    ///      at the gate itself.
    function test_aFreshTokenWithADeadPoolDoesNotSweep() public {
        _fundAndActivate(harness);
        _killTheV2Router();

        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());

        assertEq(harness.DIVIDEND_TREASURY().balance, treasuryBefore, "the treasury got nothing");
        assertEq(harness.pendingNative(), 1 ether, "and the buffer is exactly where it was");
    }

    /// @dev Staleness alone is not enough either. The registry refuses whenever the pair's quote depth
    ///      merely dips under its threshold, which one sell causes and one buy undoes — so a griefer on a
    ///      quiet-but-healthy token could otherwise manufacture the failure and sweep atomically. The
    ///      failure has to be on record from an EARLIER block, which costs them the same position held
    ///      across a block boundary, twice, per slice.
    function test_aSingleBlockFailureNeverSweepsHoweverStaleTheToken() public {
        _fundAndActivate(harness);
        _killTheV2Router();
        _goStale(harness);

        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;

        // First sighting: recorded, nothing swept. It returns quietly instead of reverting precisely
        // because it wrote the marker — a revert would undo it and the gate would never be reachable.
        harness.processDividends(0, _noHolders());
        assertEq(harness.failedConversionBlock(), block.number, "the failure is on record");
        assertEq(harness.DIVIDEND_TREASURY().balance, treasuryBefore, "nothing swept on the first sighting");

        // A second sighting in the SAME block proves nothing new, so it still cannot sweep.
        harness.processDividends(0, _noHolders());
        assertEq(harness.DIVIDEND_TREASURY().balance, treasuryBefore, "nor within the same block");
        assertEq(harness.pendingNative(), 1 ether, "and the buffer is exactly where it was");

        // Only once the failure has outlived a block does the slice move.
        vm.roll(block.number + 1);
        harness.processDividends(0, _noHolders());
        assertEq(
            harness.DIVIDEND_TREASURY().balance - treasuryBefore,
            harness.MAX_DIVIDEND_PER_CONVERSION(),
            "swept once the failure outlived a block"
        );
    }

    /// @dev The marker is evidence of a CURRENT failure, not a permanent unlock. A conversion that goes
    ///      through clears it, so a pool that recovers cannot be swept off a month-old sighting.
    function test_aSuccessfulConversionClearsTheFailureRecord() public {
        _fundAndActivate(harness);
        _killTheV2Router();
        _goStale(harness);
        _recordFailedConversion(harness);

        _reviveTheV2Router();
        harness.processDividends(0, _noHolders());
        assertEq(harness.failedConversionBlock(), 0, "the record is cleared by a working conversion");
        assertGt(harness.dividendsOwed(), 0, "and the stream funded normally");
    }

    /// @dev The sweep cannot be triggered by a caller's bad price. A floor the pool has merely moved past
    ///      is a `ConversionFailed` that leaves the buffer exactly where it was: only `minOut == 0` proves
    ///      the pool itself is gone rather than the caller's number.
    function test_aLivePoolCannotBeSweptByAnUnreachableFloor() public {
        _fundAndActivate(harness);
        uint256 treasuryBefore = harness.DIVIDEND_TREASURY().balance;

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(1_000_000e18, _noHolders());

        assertEq(harness.pendingNative(), 1 ether, "the buffer is untouched");
        assertEq(harness.DIVIDEND_TREASURY().balance, treasuryBefore, "and the treasury got nothing");

        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "the same buffer funds a DAI stream at a reachable floor");
    }

    /// @dev Makes every V2 swap revert, whatever the price — the on-chain shape of a pool that is gone.
    function _killTheV2Router() internal {
        vm.mockCallRevert(
            DeploymentAddresses.UNIV2_ROUTER,
            abi.encodeWithSelector(IUniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens.selector),
            ""
        );
    }

    function _reviveTheV2Router() internal {
        vm.clearMockedCalls();
    }
}
