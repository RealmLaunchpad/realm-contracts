// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DividendDistributionLogic} from "src/tokens/DividendDistributionLogic.sol";
import {DividendDistribution} from "src/tokens/DividendDistribution.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {RealmDividendSwapRegistry} from "src/dividends/RealmDividendSwapRegistry.sol";
import {installDividendSwapRegistry} from "test/helpers/DividendRegistryHelpers.sol";
import {installKeepersRegistry} from "test/helpers/KeepersRegistryHelpers.sol";

/// @notice A bare `DividendDistributionLogic` with the token's hooks stubbed out, configured with a SET
///         of payout assets rather than one. Balances are set directly; what is under test is the
///         per-asset machinery, not the transfer hook (`dividendAccounting.t.sol` owns that).
contract MultiAssetHarness is DividendDistributionLogic {
    mapping(address account => uint256 balance) public balances;
    uint256 public eligibleSupply;
    uint8 public assetCount;

    function configure(address[] calldata assets, uint16[] calldata weights) external {
        assetCount = _initializeDividends(assets, weights, new bytes[](0));
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

    function bufferOf(uint256 i) external view returns (uint88) {
        return dividendAssets[i].pendingNative;
    }

    function owedOf(uint256 i) external view returns (uint128) {
        return dividendAssets[i].owed;
    }

    function tokenOf(uint256 i) external view returns (address) {
        return dividendAssets[i].token;
    }

    function _dividendAssetCount() internal view override returns (uint256) {
        return assetCount;
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

/// @notice An ERC20 with no pool anywhere. Used for the set-shape rejections, which must fire BEFORE the
///         registry is ever asked — the point of those tests is the shape, not the liquidity.
contract NoPoolToken is ERC20 {
    constructor() ERC20("NoPool", "NOPOOL") {
        _mint(msg.sender, 1e24);
    }
}

/// @notice Holder dividends paid in SEVERAL assets at once. The single-asset shape is the N=1 case of
///         everything here, and is covered in depth by `dividendAccounting` / `dividendsThirdAsset`;
///         these tests are about what only a SET can get wrong.
///
/// @dev THE PROPERTY UNDER TEST, throughout: the assets are independent. One asset crossing its
///      threshold, converting, streaming, failing or going stale must have no effect on any other — the
///      only things they share are the eligible supply, the activation instant and the reentrancy lock.
contract DividendsMultiAssetTests is Test {
    uint256 internal constant BLOCKNUMBER = 23327777;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant NATIVE = address(0);

    /// @dev 20% APPLE / 80% SPY, the product's own example, mapped onto two assets with real pools.
    uint16 internal constant W_SMALL = 2_000;
    uint16 internal constant W_BIG = 8_000;

    MultiAssetHarness internal h;
    RealmDividendSwapRegistry internal registry;

    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal registryOwner = makeAddr("registryOwner");

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), BLOCKNUMBER);
        registry = installDividendSwapRegistry(registryOwner);
        installKeepersRegistry(registryOwner, address(this));
        h = _harness(_assets(NATIVE, DAI), _weights(W_SMALL, W_BIG));
    }

    //////////////////////// helpers //////////////////////

    function _harness(address[] memory assets, uint16[] memory weights) internal returns (MultiAssetHarness harness) {
        harness = new MultiAssetHarness();
        harness.configure(assets, weights);
    }

    /// @dev The rejection has to be asserted against `configure`, not against the deploy: `expectRevert`
    ///      applies to the NEXT call, and `new MultiAssetHarness()` is a call.
    function _expectConfigureRevert(bytes4 selector, address[] memory assets, uint16[] memory weights) internal {
        MultiAssetHarness harness = new MultiAssetHarness();
        vm.expectRevert(selector);
        harness.configure(assets, weights);
    }

    function _assets(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _assets(address a, address b, address c) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function _weights(uint16 a, uint16 b) internal pure returns (uint16[] memory list) {
        list = new uint16[](2);
        list[0] = a;
        list[1] = b;
    }

    function _weights(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory list) {
        list = new uint16[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = holder;
    }

    function _noHolders() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _activateWith(uint256 balance) internal {
        h.setBalance(holder, balance);
        h.activate();
    }

    function _accrue(uint256 amount) internal {
        vm.deal(address(this), amount);
        h.accrue{value: amount}();
    }

    //////////////////////// the split //////////////////////

    function test_multiAsset_earningsSplitByWeight() public {
        _activateWith(1_000e18);
        _accrue(10 ether);

        assertEq(h.bufferOf(0), 2 ether, "20% of the dividends slice buffered for asset 0");
        assertEq(h.bufferOf(1), 8 ether, "80% for asset 1");
    }

    /// @dev The LAST asset takes the remainder rather than its own bps product, so integer division can
    ///      neither strand a wei in no bucket nor hand the same wei to two buckets. Fuzzed because the
    ///      failure is a rounding one and shows up on awkward amounts, not round ones.
    function testFuzz_multiAsset_splitIsExactToTheWei(uint96 amount) public {
        amount = uint96(bound(amount, 1, 1_000 ether));
        _activateWith(1_000e18);
        _accrue(amount);

        assertEq(
            uint256(h.bufferOf(0)) + h.bufferOf(1),
            amount,
            "every wei of the dividends slice landed in exactly one buffer"
        );
    }

    function test_multiAsset_threeWaySplitIsExact() public {
        h = _harness(_assets(NATIVE, DAI, USDC), _weights(3_333, 3_333, 3_334));
        _activateWith(1_000e18);
        _accrue(1 ether + 1 wei);

        assertEq(
            uint256(h.bufferOf(0)) + h.bufferOf(1) + h.bufferOf(2), 1 ether + 1 wei, "no wei stranded across three"
        );
    }

    //////////////////////// independence //////////////////////

    /// @dev THE HEADLINE PROPERTY. With a 20/80 split the small asset reaches `DIVIDEND_THRESHOLD` four
    ///      times more slowly, so there is a window in which one asset is fundable and the other is not.
    ///      Each must answer for itself.
    function test_multiAsset_thresholdIsCrossedPerAsset() public {
        _activateWith(1_000e18);
        // Sized so the 80% leg clears the threshold and the 20% leg does not.
        _accrue(h.DIVIDEND_THRESHOLD() * 2);

        assertLt(h.bufferOf(0), h.DIVIDEND_THRESHOLD(), "precondition: the small leg is short");
        assertGe(h.bufferOf(1), h.DIVIDEND_THRESHOLD(), "precondition: the big leg qualifies");

        vm.expectRevert(DividendDistribution.BelowDividendThreshold.selector);
        h.processDividends(0, 0, _noHolders());

        h.processDividends(1, 0, _noHolders());
        assertGt(h.owedOf(1), 0, "the big leg distributed");
        assertEq(h.owedOf(0), 0, "the small leg is untouched");
    }

    /// @dev The per-block funding cooldown is per asset because the manipulation it bounds is of ONE
    ///      asset's pool and buys nothing in another's. A keeper must be able to service the whole set in
    ///      one block.
    function test_multiAsset_fundingCooldownIsPerAsset() public {
        _activateWith(1_000e18);
        _accrue(10 ether);

        h.processDividends(0, 0, _noHolders());
        // Same block, different asset: allowed.
        h.processDividends(1, 0, _noHolders());
        assertGt(h.owedOf(0), 0, "asset 0 funded");
        assertGt(h.owedOf(1), 0, "asset 1 funded");

        // Same block, same asset: refused.
        vm.expectRevert(DividendDistribution.DividendProcessCooldown.selector);
        h.processDividends(1, 0, _noHolders());
    }

    /// @dev Each asset accrues against its OWN accumulator, so a holder's two claims are independent
    ///      amounts in independent units.
    function test_multiAsset_assetsAccrueIndependently() public {
        _activateWith(1_000e18);
        _accrue(10 ether);

        h.processDividends(0, 0, _noHolders()); // native leg: no conversion

        assertGt(h.previewDividend(holder, 0), 0, "the native leg credited the holder");
        assertEq(h.previewDividend(holder, 1), 0, "the DAI leg never distributed");

        h.processDividends(1, 0, _noHolders()); // DAI leg: converts
        assertGt(h.previewDividend(holder, 1), 0, "and now it has");
    }

    /// @dev A conversion failure on one asset must not touch another's buffer, ledger or accumulator.
    function test_multiAsset_conversionFailureIsContained() public {
        _activateWith(1_000e18);
        _accrue(10 ether);
        h.processDividends(0, 0, _noHolders());
        uint256 owedNative = h.owedOf(0);

        // An unreachable floor on the DAI leg. The buffer stays put and nothing else moves.
        vm.expectRevert(DividendDistribution.DividendConversionFailed.selector);
        h.processDividends(1, type(uint256).max, _noHolders());

        assertEq(h.bufferOf(1), 8 ether, "the failed leg's buffer is untouched");
        assertEq(h.owedOf(0), owedNative, "the healthy leg's ledger is untouched");
    }

    //////////////////////// payouts //////////////////////

    /// @dev `claimDividends()` is the holder's one call for the whole set: it settles and pays every
    ///      configured asset, so a holder never has to know how many there are.
    function test_multiAsset_claimPaysEveryAsset() public {
        _activateWith(1_000e18);
        _accrue(10 ether);
        h.processDividends(0, 0, _noHolders());
        h.processDividends(1, 0, _noHolders());

        uint256 ethBefore = holder.balance;
        vm.prank(holder);
        h.claimDividends();

        assertGt(holder.balance, ethBefore, "paid in native");
        assertGt(IERC20(DAI).balanceOf(holder), 0, "and in DAI");
        assertEq(h.previewDividend(holder, 0), 0, "native accrual cleared");
        assertEq(h.previewDividend(holder, 1), 0, "DAI accrual cleared");
    }

    /// @dev A keeper batch is per asset, and pushing one asset must not zero another's accrual.
    function test_multiAsset_keeperBatchPaysOnlyItsOwnAsset() public {
        _activateWith(1_000e18);
        _accrue(10 ether);
        h.processDividends(0, 0, _noHolders());
        h.processDividends(1, 0, _noHolders());

        uint256 daiPending = h.previewDividend(holder, 1);
        h.processDividends(0, 0, _holders());

        assertEq(h.previewDividend(holder, 0), 0, "the pushed asset is paid");
        assertEq(h.previewDividend(holder, 1), daiPending, "the other asset is untouched");
    }

    /// @dev `committedDividends` is what keeps `rescueTokens` and `sweepStrayEth` off holders' money. It
    ///      has to answer for the asset asked about, whichever slot it occupies.
    function test_multiAsset_committedDividendsAnswersPerAsset() public {
        _activateWith(1_000e18);
        _accrue(10 ether);
        h.processDividends(1, 0, _noHolders());

        assertEq(h.committedDividends(DAI), h.owedOf(1), "the DAI debt is reported against DAI");
        assertEq(h.committedDividends(NATIVE), 0, "and not against the native leg");
        assertEq(h.committedDividends(USDC), 0, "nor against an asset this token does not pay in");
    }

    function test_multiAsset_indexPastTheSetIsRejected() public {
        _activateWith(1_000e18);
        vm.expectRevert(DividendDistribution.DividendAssetOutOfRange.selector);
        h.processDividends(2, 0, _noHolders());
    }

    //////////////////////// the set's shape //////////////////////

    /// @dev THE ONE MISCONFIGURATION THAT LEAKS VALUE. `committedDividends` sums per asset; the same
    ///      asset in two slots would have it under-report the debt, and `rescueTokens` would hand the
    ///      difference to the owner out of holders' pot.
    function test_multiAsset_duplicateAssetIsRejected() public {
        _expectConfigureRevert(
            DividendDistribution.InvalidDividendAssetSet.selector, _assets(DAI, DAI), _weights(W_SMALL, W_BIG)
        );
    }

    function test_multiAsset_weightsMustSumToBpsTotal() public {
        _expectConfigureRevert(
            DividendDistribution.InvalidDividendAssetSet.selector, _assets(NATIVE, DAI), _weights(2_000, 7_000)
        );
    }

    /// @dev A zero-weight asset can never be funded but is still settled on every transfer: pure cost.
    function test_multiAsset_zeroWeightIsRejected() public {
        _expectConfigureRevert(
            DividendDistribution.InvalidDividendAssetSet.selector, _assets(NATIVE, DAI), _weights(10_000, 0)
        );
    }

    function test_multiAsset_emptySetIsRejected() public {
        _expectConfigureRevert(DividendDistribution.InvalidDividendAssetSet.selector, new address[](0), new uint16[](0));
    }

    function test_multiAsset_mismatchedArrayLengthsAreRejected() public {
        _expectConfigureRevert(
            DividendDistribution.InvalidDividendAssetSet.selector, _assets(NATIVE, DAI), _weights(10_000)
        );
    }

    function test_multiAsset_moreThanTheMaximumIsRejected() public {
        address[] memory four = new address[](4);
        four[0] = NATIVE;
        four[1] = DAI;
        four[2] = USDC;
        four[3] = address(new NoPoolToken());
        uint16[] memory weights = new uint16[](4);
        weights[0] = 2_500;
        weights[1] = 2_500;
        weights[2] = 2_500;
        weights[3] = 2_500;

        _expectConfigureRevert(DividendDistribution.InvalidDividendAssetSet.selector, four, weights);
    }

    /// @dev The self-token payout is carved in TOKEN space on Uniswap V2 and removes itself from the ETH
    ///      split's denominator — a whole-slice operation with no per-asset fraction. Rejected in any
    ///      larger set, on both venues, so the rule reads the same wherever a creator finds it.
    function test_multiAsset_selfTokenMustBeSole() public {
        address[] memory set = _assets(DAI, h.DIVIDEND_SELF_TOKEN());
        _expectConfigureRevert(DividendDistribution.SelfTokenDividendMustBeSole.selector, set, _weights(W_BIG, W_SMALL));
    }

    /// @dev And alone it is still fine — the rule is about the set, not about the sentinel.
    function test_multiAsset_selfTokenAloneIsAccepted() public {
        address[] memory one = new address[](1);
        one[0] = h.DIVIDEND_SELF_TOKEN();
        MultiAssetHarness sole = _harness(one, _weights(10_000));
        assertEq(sole.tokenOf(0), address(sole), "the sentinel resolved to the token itself");
        assertEq(sole.assetCount(), 1, "one asset");
    }

    /// @dev Every member of the set is put to the registry, not just the first — an asset the token could
    ///      never convert into must fail at CREATION, which is the only moment a clone can still be fixed.
    function test_multiAsset_everyAssetIsCheckedAgainstTheRegistry() public {
        address ghost = address(new NoPoolToken());
        address[] memory set = _assets(DAI, ghost);
        uint16[] memory weights = _weights(W_BIG, W_SMALL);
        MultiAssetHarness harness = new MultiAssetHarness();
        vm.expectRevert();
        harness.configure(set, weights);
    }

    function _weights(uint16 a) internal pure returns (uint16[] memory list) {
        list = new uint16[](1);
        list[0] = a;
    }
}
