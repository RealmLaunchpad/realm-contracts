// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TaxTokenUniV4BaseTests} from "test/graduators/taxToken.base.t.sol";
import {LivoTaxableTokenUniV4} from "src/tokens/LivoTaxableTokenUniV4.sol";
import {LivoFactoryUniV4Unified} from "src/factories/LivoFactoryUniV4Unified.sol";
import {ILivoFactory} from "src/interfaces/ILivoFactory.sol";
import {LiquidityTier} from "src/types/LiquidityTier.sol";
import {TaxConfigsWithAllocation, EarningsAllocationConfig} from "src/interfaces/ILivoTaxableToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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

    /// @dev Fund-only: the single entry point does whichever of conversion / funding / pushing there is
    ///      anything to do, so a call with no holders exercises the conversion path on its own.
    function process() public {
        try TOKEN.processDividends(0, new address[](0)) {} catch {}
    }

    function distribute(uint256 seed) public {
        address[] memory batch = new address[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            batch[i] = holders[(i + seed) % holders.length];
        }
        try TOKEN.processDividends(0, batch) {} catch {}
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
        TaxConfigsWithAllocation memory cfg = TaxConfigsWithAllocation({
            buyTaxBps: 0,
            sellTaxBps: 400,
            taxDurationSeconds: uint32(365 days),
            startTaxFromLaunch: true,
            buyTaxDecayStartBps: 0,
            sellTaxDecayStartBps: 0,
            taxDecayDuration: 0,
            earningsAllocation: EarningsAllocationConfig({
                burnBps: 2_000, dividendsBps: 4_000, liquidityBps: 1_000, dividendToken: address(0)
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
        uint256 committed = divToken.burnPendingEth() + divToken.liquidityPendingEth() + divToken.pendingNative()
            + divToken.committedDividends(address(0));
        assertGe(address(divToken).balance, committed, "native balance must cover every committed bucket");
    }

    /// @dev Over-distribution is impossible by construction: the accumulator truncates in the holders'
    ///      favour at every step, so what has been promised can never exceed what was funded. If this
    ///      ever trips, that argument has been broken.
    function invariant_promisedNeverExceedsFunded() public view {
        uint256 promised =
            divToken.previewDividend(buyer) + divToken.previewDividend(holderA) + divToken.previewDividend(holderB);
        assertLe(promised, divToken.dividendsOwed(), "more promised to holders than was ever funded");
    }

    /// @dev The stream can never run past its own end, so the accumulator's clock is always clamped to
    ///      `dividendPeriodFinish`. A `lastDividendUpdate` beyond it would double-count the tail.
    function invariant_accumulatorClockNeverOutrunsTheStream() public view {
        assertLe(divToken.lastDividendUpdate(), divToken.dividendPeriodFinish(), "clock outran the stream");
    }
}
