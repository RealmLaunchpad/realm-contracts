// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendInitLogic} from "src/tokens/DividendInitLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {DeploymentAddressesRobinhoodMainnet as DeploymentAddresses} from "src/config/DeploymentAddresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {DividendRouteLib} from "src/libraries/DividendRouteLib.sol";
import {installDividendSwapRegistry, setDividendRoute} from "test/helpers/DividendRegistryHelpers.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";
import {KeeperGated} from "src/tokens/KeeperGated.sol";
import {RealmKeepersRegistry} from "src/access/RealmKeepersRegistry.sol";

/// @notice A bare `DividendDistributionLogic` with the token's hooks stubbed out. It exists so the
///         third-asset payout shape — the only one that actually performs a swap — can be exercised
///         against real Uniswap pools without dragging a launchpad, a graduator and a pool through
///         the test. Balances are set directly instead of being moved by transfers.
contract DividendHarness is DividendDistributionLogic, DividendInitLogic {
    mapping(address => uint256) public balances;
    uint256 public eligibleSupply;

    /// @dev A one-asset payout set taking the whole dividends slice.
    function _soleAssetSet(address asset) internal pure returns (address[] memory assets, uint16[] memory weights) {
        assets = new address[](1);
        assets[0] = asset;
        weights = new uint16[](1);
        weights[0] = 10_000;
    }

    function configure(address asset) external {
        (address[] memory assets, uint16[] memory weights) = _soleAssetSet(asset);
        assetCount = _initializeDividends(assets, weights);
    }

    /// @dev How many payout assets the harness was configured with. The production token keeps this in
    ///      its `pair` slot; here it is plain storage.
    uint8 public assetCount;

    function _dividendAssetCount() internal view override returns (uint256) {
        return assetCount;
    }

    /// @notice Configure a multi-asset payout set, as `initializeEarningsAllocation`'s array overload does.
    function configureMulti(address[] calldata assets, uint16[] calldata weights) external {
        assetCount = _initializeDividends(assets, weights);
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

    /// @dev Single-asset conveniences the production token dropped to stay inside EIP-170. A harness is
    ///      not size-bound, so the tests keep reading them by name.
    function dividendPrecisionExp() external view returns (uint8) {
        return dividendAssets[0].precisionExp;
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

/// @notice A payout asset whose `transfer` never returns. Any ERC20 can be configured, so a token like
///         this can pass creation and then meet a keeper batch.
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
///         through the route `RealmDividendSwapRegistry` holds for it, and pushed to holders in that
///         asset. Any ERC20 can be configured; one without a route just does not convert.
contract DividendsThirdAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 58_000_000;
    address internal constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    /// @dev The chain's 6-decimal reference asset, and the one V2 pair here that is genuinely deep
    ///      (~235 ETH a side), so it needs no depth-floor relief.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    DividendHarness internal harness;
    RealmDividendSwapRegistry internal registry;

    address internal holder = makeAddr("holder");
    address internal registryOwner = makeAddr("registryOwner");

    /// @dev `addLiquidityETH` refunds the unused ETH side to the caller.
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(registryOwner);
        // Every asset this suite converts goes through its V2 pair with WETH.
        setDividendRoute(registry, MSFT, DividendRouteLib.encodeV2());
        setDividendRoute(registry, AAPL, DividendRouteLib.encodeV2());
        setDividendRoute(registry, USDG, DividendRouteLib.encodeV2());
        installKeepersRegistry(registryOwner, address(this));
        harness = _harness(MSFT);
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

    /// @dev Tops the buffer up to more than two conversion caps, so two consecutive conversions both
    ///      take a full slice. Returns the new buffer.
    function _topUpPastTwoCaps(DividendHarness h) internal returns (uint256 funded) {
        funded = 2 * h.MAX_DIVIDEND_PER_CONVERSION() + 1 ether;
        uint256 extra = funded - h.pendingNative();
        vm.deal(address(this), extra);
        h.accrue{value: extra}();
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = holder;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    //////////////////////// the payout shape //////////////////////

    function test_thirdAsset_boughtOnFundingAndCreditedToHolders() public {
        _fundAndActivate(harness);
        assertEq(harness.pendingNative(), 1 ether, "native buffered for the MSFT payout");

        harness.processDividends(0, _noHolders());

        uint256 pot = harness.dividendsOwed();
        assertGt(pot, 0, "native converted into MSFT");
        // A swapping payout converts at most `MAX_DIVIDEND_PER_CONVERSION` at a time; the rest stays
        // buffered.
        assertEq(harness.pendingNative(), 1 ether - harness.MAX_DIVIDEND_PER_CONVERSION(), "only the cap was converted");
        assertEq(IERC20(MSFT).balanceOf(address(harness)), pot, "the distribution is a real MSFT balance");
        // What every sweep path subtracts: an undelivered third-asset payout is COMMITTED, not stray, so
        // `rescueTokens` cannot hand holders' money to the owner while it is still owed.
        assertEq(harness.committedDividends(MSFT), pot, "the whole of it is owed to holders");
        assertApproxEqRel(harness.previewDividend(holder), pot, 1e12, "and credited to the sole holder at once");

        // Same block, so the funding leg is on cooldown and this call only pays.
        harness.processDividends(0, _holders());

        assertApproxEqRel(IERC20(MSFT).balanceOf(holder), pot, 1e12, "sole holder paid the whole distribution, in MSFT");
        assertEq(harness.committedDividends(MSFT), harness.dividendsOwed(), "what is still owed is what is committed");
        assertLt(harness.dividendsOwed(), pot / 1e6, "nothing meaningful left owed");
    }

    /// @dev The per-conversion cap bounds one sandwich, it does not cap what a token can ever pay:
    ///      whatever it leaves behind stays buffered and converts on a later call, so nothing strands.
    function test_thirdAsset_cappedConversionLeavesTheRemainderBuffered() public {
        _fundAndActivate(harness);
        uint256 cap = harness.MAX_DIVIDEND_PER_CONVERSION();
        uint256 funded = _topUpPastTwoCaps(harness);

        harness.processDividends(0, _holders());
        assertEq(harness.pendingNative(), funded - cap, "the first conversion took exactly the cap");

        vm.roll(block.number + 1); // the funding leg is once per block
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), funded - 2 * cap, "and the next one takes the next slice");
    }

    //////////////////////// the liquidity proof //////////////////////

    /// @dev ANY ERC20 is configurable, routed or not: nothing about the asset is checked at creation.
    function test_anyErc20IsConfigurable() public {
        assertEq(_harness(MSFT).dividendToken(), MSFT, "MSFT");
        assertEq(_harness(address(new GhostToken())).dividendToken() != address(0), true, "a token with no pool");
    }

    /// @dev An asset without a route converts nothing and loses nothing: the buffer waits for a route.
    function test_anAssetWithoutARouteKeepsItsBufferUntilItGetsOne() public {
        GhostToken ghost = new GhostToken();
        DividendHarness h = _harness(address(ghost));
        _fundAndActivate(h);

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        h.processDividends(0, _noHolders());
        assertEq(h.pendingNative(), 1 ether, "the buffer is intact");

        // A market appears and an admin lists it: the SAME token converts.
        IUniswapV2Router router = IUniswapV2Router(DeploymentAddresses.UNIV2_ROUTER);
        vm.deal(address(this), 10 ether);
        ghost.approve(address(router), type(uint256).max);
        router.addLiquidityETH{value: 10 ether}(address(ghost), 500_000e18, 0, 0, address(this), block.timestamp);
        setDividendRoute(registry, address(ghost), DividendRouteLib.encodeV2());
        h.processDividends(0, _noHolders());
        assertGt(h.dividendsOwed(), 0, "converts once routed");
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

    /// @dev The one admin veto is clearing the route, and it reaches tokens that ALREADY exist: the
    ///      buffer waits, whole, until a route is set again.
    function test_clearingARouteHoldsTheBufferUntilItIsRestored() public {
        _fundAndActivate(harness);
        setDividendRoute(registry, MSFT, "");

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether, "the whole buffer waits");

        setDividendRoute(registry, MSFT, DividendRouteLib.encodeV2());
        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "and it converts once the route is back");
    }

    /// @dev The registry is a swap venue, not a vault: it forwards everything it buys inside the same
    ///      call and is empty before and after.
    function test_theRegistryHoldsNothing() public {
        _fundAndActivate(harness);
        // A DELTA, not zero: the registry constant is `address(0)` until the proxy is deployed, and on a
        // mainnet fork that address already holds every ETH ever burned to it.
        uint256 registryBalanceBefore = address(registry).balance;
        uint256 registryDaiBefore = IERC20(MSFT).balanceOf(address(registry));
        harness.processDividends(0, _noHolders());

        assertEq(address(registry).balance, registryBalanceBefore, "no native retained");
        assertEq(IERC20(MSFT).balanceOf(address(registry)), registryDaiBefore, "no asset retained");
        assertEq(IERC20(MSFT).balanceOf(address(harness)), harness.dividendsOwed(), "it all reached the token");
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
        assertEq(harness.dividendsOwed(), 0, "and nothing was distributed");

        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "the same buffer converts once the floor is reachable");
    }

    /// @dev A raw `call` to an address with no code SUCCEEDS and keeps the value. If the registry constant
    ///      is ever wrong — or the registry is deployed after the token implementations — the conversion
    ///      must fail closed rather than hand the buffer to a codeless address on every call.
    function test_aCodelessRegistryFailsClosedInsteadOfBurningTheBuffer() public {
        _fundAndActivate(harness);
        vm.etch(DeploymentAddresses.DIVIDEND_SWAP_REGISTRY, hex"");

        // A call CARRYING holders never reverts for a broken swap, so nothing rolls the transfer back:
        // this is the shape in which a codeless registry would silently pocket the buffer, every call.
        uint256 registryBalanceBefore = DeploymentAddresses.DIVIDEND_SWAP_REGISTRY.balance;
        harness.processDividends(0, _holders());

        assertEq(
            DeploymentAddresses.DIVIDEND_SWAP_REGISTRY.balance,
            registryBalanceBefore,
            "the codeless address got nothing"
        );
        assertEq(harness.pendingNative(), 1 ether, "the buffer is intact");
        assertEq(harness.dividendsOwed(), 0, "nothing was distributed");
    }

    /// @dev A token that has earned NOTHING yet reports the OTHER error: the keeper is told to wait, not
    ///      sent looking for a broken pool. With no size floor left, that is the only thing
    ///      `BelowDividendThreshold` means.
    function test_anEmptyBufferReportsBelowDividendThreshold() public {
        harness.setBalance(holder, 1_000e18);
        harness.activate();

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        harness.processDividends(0, _noHolders());
    }

    /// @dev The floor is gone all the way down: ONE WEI converts and credits. Whether that is worth the
    ///      gas is the keeper's call, not the contract's — and the keeper is the only one who can make
    ///      it, which is what keeps this from becoming a dust stream anyone can drive.
    function test_aOneWeiBufferConverts() public {
        harness.setBalance(holder, 1_000e18);
        harness.activate();
        vm.deal(address(this), 1 wei);
        harness.accrue{value: 1 wei}();

        harness.processDividends(0, _noHolders());

        assertGt(harness.dividendsOwed(), 0, "a one-wei buffer bought and credited some payout asset");
        assertEq(harness.pendingNative(), 0, "buffer drained");
    }

    /// @dev A payout asset that returns a non-boolean word from `transfer` must be TOLERATED, not
    ///      decoded strictly. `abi.decode(_, (bool))` reverts on any word above 1, which is legal for a
    ///      non-standard ERC20 — and a revert inside `_payDividend` is precisely what the skip-don't-revert
    ///      contract exists to prevent: it would take down the whole `processDividends` batch and
    ///      `claimDividends` for everyone.
    function test_aNonBooleanTransferReturnDoesNotBrickTheBatch() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders()); // buy MSFT, distribute

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder has accrued the distribution");
        vm.mockCall(MSFT, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(uint256(2)));

        vm.expectEmit(true, true, true, true, address(harness));
        emit DividendDistribution.DividendPaid(holder, MSFT, owed);
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
        uint256 funded = _topUpPastTwoCaps(harness);

        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), funded - cap, "the first conversion went through");

        vm.expectRevert(DividendDistribution.DividendProcessCooldown.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), funded - cap, "and a second one in the same block converts nothing");

        vm.roll(block.number + 1);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), funded - 2 * cap, "the next block converts again");
    }

    /// @dev The gate is on FUNDING alone. A keeper splitting a large holder set across several
    ///      transactions in one block is ordinary, and those calls read a buffer the first already
    ///      resolved — rate-limiting them would rate-limit paying people.
    function test_theCooldownDoesNotBlockPayouts() public {
        _fundAndActivate(harness);
        harness.processDividends(0, _noHolders());

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder accrued the distribution");

        // Same block as the funding call above: it must pay, not revert.
        harness.processDividends(0, _holders());
        assertEq(IERC20(MSFT).balanceOf(holder), owed, "paid in full despite the funding cooldown");
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
        harness.processDividends(0, _noHolders()); // buy MSFT, distribute

        uint256 owed = harness.previewDividend(holder);
        assertGt(owed, 0, "the holder accrued the distribution");

        // Etched AFTER the conversion, and called in the SAME block as it, so the funding leg is under
        // its own cooldown and never touches the bomb — only the payout leg does.
        vm.etch(MSFT, type(GasBombToken).runtimeCode);

        uint256 before = gasleft();
        harness.processDividends(0, _holders());
        uint256 used = before - gasleft();

        assertLt(used, 2 * harness.ASSET_PAYOUT_GAS(), "the bomb was capped, not handed the whole batch");
        assertEq(harness.previewDividend(holder), owed, "and the unpaid holder keeps every unit accrued");
    }

    //////////////////////// weird payout assets //////////////////////

    /// @dev The accumulator's scale comes from the PAYOUT ASSET's decimals, not from a fixed 1e18. With
    ///      1e18 against a 1e27 supply, one accumulator step was worth 1e9 asset units — 1000 USDG — so
    ///      every increment of a realistic distribution truncated to zero and a 6-decimal payout credited
    ///      NOTHING while `dividendsOwed` kept counting it. USDG is a first-class payout asset here.
    function test_aSixDecimalPayoutAssetCreditsTheWholeDistribution() public {
        DividendHarness h = _harness(USDG);
        assertEq(h.dividendPrecisionExp(), 30, "36 - 6, so one step is 1e-18 of a whole USDG");

        // A realistic graduated token: 1e27 supply, most of it outside the pair, and one holder.
        h.setBalance(holder, 8e26);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        h.processDividends(0, _noHolders());

        uint256 distributed = h.dividendsOwed();
        assertGt(distributed, 0, "the conversion bought USDG");

        h.processDividends(0, _holders());
        // Not exact: the accumulator truncates towards the protocol at every step, which is what keeps
        // it solvent. What matters is that the loss is dust rather than the whole distribution.
        assertApproxEqRel(IERC20(USDG).balanceOf(holder), distributed, 0.0001e18, "the sole holder got it all");
    }

    /// @dev `MSFT` is unchanged by the same rule — an 18-decimal asset keeps the scale it always had, so
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
        DividendHarness h = _harness(MSFT);
        h.setBalance(holder, 1_000e18);
        h.activate();
        vm.deal(address(this), 1 ether);
        h.accrue{value: 1 ether}();
        h.processDividends(0, _noHolders());

        vm.etch(MSFT, address(new ReturnBombToken()).code);
        assertGt(h.previewDividend(holder), 0, "the holder has accrued");

        uint256 accrued = h.previewDividend(holder);
        vm.prank(holder);
        h.claimDividends{gas: 5_000_000}(); // must not revert
        assertEq(h.previewDividend(holder), accrued, "unpaid, but the accrual is intact for a later try");
    }

    /// @dev A dead pool strands nothing: every failed conversion leaves the buffer exactly where it was,
    ///      however long it lasts, and a revived (or repointed) venue converts it.
    function test_aDeadPoolLeavesTheBufferWhole() public {
        _fundAndActivate(harness);
        _killTheV2Router();

        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());
        skip(365 days);
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        harness.processDividends(0, _noHolders());
        assertEq(harness.pendingNative(), 1 ether, "the buffer is exactly where it was");

        _reviveTheV2Router();
        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "and converts once the venue works");
    }

    /// @dev The keeper sizes a conversion below the cap, for a pool too thin to take all of it at once.
    function test_theKeeperCanConvertASliceSmallerThanTheCap() public {
        _fundAndActivate(harness);
        harness.processDividends(0, true, 0.2 ether, 0, _noHolders());
        assertEq(harness.pendingNative(), 0.8 ether, "spent exactly the requested slice");
        assertGt(harness.dividendsOwed(), 0, "and credited it");
    }

    /// @dev A requested amount above the cap is clipped to it; 0 means "up to the cap".
    function test_anAmountAboveTheCapIsClipped() public {
        _fundAndActivate(harness);
        _topUpPastTwoCaps(harness);
        uint256 buffered = harness.pendingNative();
        harness.processDividends(0, true, type(uint256).max, 0, _noHolders());
        assertEq(harness.pendingNative(), buffered - harness.MAX_DIVIDEND_PER_CONVERSION(), "clipped to the cap");
    }

    /// @dev With the keepers registry's global switch on, anyone may fund.
    function test_theGlobalSwitchOpensFundingToAnyone() public {
        _fundAndActivate(harness);
        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vm.expectRevert(KeeperGated.NotAKeeper.selector);
        harness.processDividends(0, _noHolders());

        vm.prank(registryOwner);
        RealmKeepersRegistry(DeploymentAddresses.REALM_KEEPERS_REGISTRY).setPermissionless(true);
        vm.prank(randomCaller);
        harness.processDividends(0, _noHolders());
        assertGt(harness.dividendsOwed(), 0, "anyone converted");
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
