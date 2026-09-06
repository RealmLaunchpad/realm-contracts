// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithMultiAllocation, EarningsAllocationMultiConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {divRate, divLastUpdate} from "test/helpers/DividendViewHelpers.sol";

/// @notice Drives every path that can move a dividend-paying token's native balance: fresh earnings, the
///         permissionless stray-ETH sweep, the distribution, the payout push, and ordinary transfers
///         between holders. Every call is wrapped in `try` so a legitimately-reverting call (threshold not
///         reached, cooldown) does not end the run — the point is to reach as
///         many interleavings as possible, not to assert on any single one.
contract DividendSolvencyHandler is Test {
    LivoTaxableTokenUniV4 public immutable TOKEN;
    address[] public holders;

    constructor(LivoTaxableTokenUniV4 token_, address[] memory holders_) {
        TOKEN = token_;
        holders = holders_;
    }

    receive() external payable {}

    /// @dev Fresh post-graduation earnings, the way the swap hook and the LP-fee router deliver them.
    function accrue(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 0.001 ether, 5 ether);
        vm.deal(address(this), amount);
        TOKEN.accrueFees{value: amount}();
    }

    /// @dev Stray ETH nobody accounted for. The sweep must be able to take this and nothing else.
    function donate(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 0.001 ether, 2 ether);
        vm.deal(address(TOKEN), address(TOKEN).balance + amount);
    }

    function sweepStray() public {
        try TOKEN.sweepStrayEth() {} catch {}
    }

    /// @dev Fund-only, on one of the configured assets: the single entry point does whichever of
    ///      conversion / funding / pushing there is anything to do, so a call with no holders exercises
    ///      the conversion path on its own. `seed` picks the asset so the run interleaves the legs
    ///      instead of always draining the same one.
    function process(uint256 seed) public {
        uint8 index = uint8(seed % TOKEN.dividendAssetCount());
        try TOKEN.processDividends(index, 0, new address[](0)) {} catch {}
    }

    function distribute(uint256 seed) public {
        address[] memory batch = new address[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            batch[i] = holders[(i + seed) % holders.length];
        }
        uint8 index = uint8(seed % TOKEN.dividendAssetCount());
        try TOKEN.processDividends(index, 0, batch) {} catch {}
    }

    /// @dev The holder's own route, which pays every asset in one call. Included so the run interleaves
    ///      self-serve claims with keeper pushes on the same accruals.
    function claim(uint256 seed) public {
        address holder = holders[seed % holders.length];
        vm.prank(holder);
        try TOKEN.claimDividends() {} catch {}
    }

    function transferBetweenHolders(uint256 seed, uint96 raw) public {
        address from = holders[seed % holders.length];
        address to = holders[(seed + 1) % holders.length];
        uint256 balance = IERC20(address(TOKEN)).balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(uint256(raw), 1, balance);
        vm.prank(from);
        IERC20(address(TOKEN)).transfer(to, amount);
    }

    function advanceTime(uint32 raw) public {
        skip(bound(uint256(raw), 1 hours, 4 days));
        vm.roll(block.number + 1);
    }
}

/// @notice The committed-funds invariant from the dividends design: undistributed dividend money sits in
///         the token's own balance next to the burn buffer, the liquidity buffer and genuinely stray
///         funds, and three paths would otherwise hand it to someone else. Those paths are now all routed
///         through `_sweepableNative` / `_sweepableAsset`; this suite is what stops a fourth bucket from
///         being added to one of them and forgotten in the others.
contract DividendSolvencyInvariants is TaxTokenUniV4BaseTests {
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    LivoTaxableTokenUniV4 internal divToken;
    DividendSolvencyHandler internal handler;

    address internal holderA = makeAddr("holderA");
    address internal holderB = makeAddr("holderB");

    function setUp() public virtual override {
        super.setUp();

        ILivoFactory.TokenSetupTiered memory setup = ILivoFactory.TokenSetupTiered({
            name: "DivInv",
            symbol: "DINV",
            salt: _nextValidSalt(address(factoryTax), address(livoTaxToken)),
            feeShares: _fs(creator),
            liquidityTier: LiquidityTier.DEFAULT
        });
        // Every bucket non-zero on purpose: burn and liquidity share the same native balance as the
        // dividend buffers, which is exactly the confusion the accessors exist to prevent.
        // TWO payout assets, weighted unevenly: the legs then cross their thresholds at different times,
        // which is the interleaving only a multi-asset token can produce. One native (no conversion) and
        // one that really swaps, so the run covers both shapes of `_fundDividends` against the same
        // balance. Native twice is impossible — duplicates are rejected — and the self-token payout is
        // only legal on its own.
        address[] memory dividendTokens = new address[](2);
        dividendTokens[0] = address(0);
        dividendTokens[1] = DAI;
        uint16[] memory dividendWeights = new uint16[](2);
        dividendWeights[0] = 7_000;
        dividendWeights[1] = 3_000;

        TaxConfigsWithMultiAllocation memory cfg = TaxConfigsWithMultiAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(365 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationMultiConfig({
                burnBps: 2_000,
                dividendsBps: 4_000,
                liquidityBps: 1_000,
                dividendTokens: dividendTokens,
                dividendWeightsBps: dividendWeights
            })
        });
        vm.prank(creator);
        address token = factoryTax.createToken(
            setup,
            cfg,
            LivoFactoryUniV4Unified.UniV4Configs({renounceOwnership: false, lpFeeBps: 100}),
            _noSs(),
            _emptyAntiSniperCfg(),
            new ILivoFactory.CreatorVault[](0),
            address(0)
        );
        testToken = token;
        _launchpadBuy(token, 2 ether);
        _graduateToken();

        divToken = LivoTaxableTokenUniV4(payable(token));

        // Spread the float so transfers actually move minima and the denominator.
        uint256 float = IERC20(token).balanceOf(buyer);
        vm.startPrank(buyer);
        IERC20(token).transfer(holderA, float / 3);
        IERC20(token).transfer(holderB, float / 3);
        vm.stopPrank();

        address[] memory holders = new address[](3);
        holders[0] = buyer;
        holders[1] = holderA;
        holders[2] = holderB;

        handler = new DividendSolvencyHandler(divToken, holders);
        // `processDividends` is keeper-gated. The handler calls it inside a `try`, so without this the
        // funding leg would silently never run and the suite would pass while exercising nothing.
        vm.prank(admin);
        keepersRegistry.setKeeper(address(handler), true);
        targetContract(address(handler));
    }

    /// @dev Everything the token owes somebody must be backed by a real balance. A violation here is not
    ///      a lost balance — it is holders' money already handed to the creator's fee receivers.
    function invariant_nativeBalanceCoversEveryCommitment() public view {
        uint256 committed =
            divToken.burnPendingEth() + divToken.liquidityPendingEth() + divToken.committedDividends(address(0));
        // EVERY asset's buffer, not just asset 0's: each holds native waiting for its own conversion, and
        // a buffer this sum forgot is one `sweepStrayEth` away from the creator's fee receivers.
        uint256 n = divToken.dividendAssetCount();
        for (uint256 i; i < n; ++i) {
            (,,,,,,,, uint88 buffered,) = divToken.dividendAssets(i);
            committed += buffered;
        }
        assertGe(address(divToken).balance, committed, "native balance must cover every committed bucket");
    }

    /// @dev Over-distribution is impossible by construction: the accumulator truncates in the holders'
    ///      favour at every step, so what has been promised can never exceed what was funded. If this
    ///      ever trips, that argument has been broken.
    function invariant_promisedNeverExceedsFunded() public view {
        // Per asset: the two legs are denominated in different units and must never be added together.
        uint256 n = divToken.dividendAssetCount();
        for (uint256 i; i < n; ++i) {
            uint256 promised = divToken.previewDividend(buyer, i) + divToken.previewDividend(holderA, i)
                + divToken.previewDividend(holderB, i);
            (,,,,,,, uint128 owed,,) = divToken.dividendAssets(i);
            assertLe(promised, owed, "more promised to holders than was ever funded");
        }
    }

    /// @dev The stream can never run past its own end, so the accumulator's clock is always clamped to
    ///      `dividendPeriodFinish`. A `lastDividendUpdate` beyond it would double-count the tail.
    function invariant_accumulatorClockNeverOutrunsTheStream() public view {
        uint256 n = divToken.dividendAssetCount();
        for (uint256 i; i < n; ++i) {
            (, uint40 finish, uint40 lastUpdate,,,,,,,) = divToken.dividendAssets(i);
            assertLe(lastUpdate, finish, "clock outran the stream");
        }
    }
}
