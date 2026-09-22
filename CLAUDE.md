## formatting
run `forge fmt` after any modification to .sol files

## tests
`just fast-test` runs the storage-layout check first (`just check-dividend-layout`), so the two always go together. If you run `forge test` directly instead of `just fast-test`, run `just check-dividend-layout` alongside it.

Every suite forks Robinhood mainnet, the project's main chain, so `fast-test` first retargets the token impls at it (`just chain-rh`) and runs everything on the `[profile.robinhood]` build: the unit suites, then the Robinhood fork integration suites (`test/integration/fork/robinhood/`, real xStock dividends) via `just test-rh-fork`. The impls bake one chain's addresses and refuse a mismatched chain id, so a bare `forge test` on a tree retargeted elsewhere fails in `setUp()` with a call to a non-contract address. `fast-test` leaves the tree retargeted at Robinhood mainnet; the committed default is Robinhood testnet, so run `just chain-rh-testnet` before committing if you do not want the retarget in the diff.

The check compares the storage layout of each taxable token against its dividend extension (`RealmTaxableTokenUniV2` vs `RealmDividendLogicUniV2`, and the V4 pair). The extension is `delegatecall`ed with the token's storage, so a layout that drifts would have it writing the wrong slots on live, non-upgradeable clones — and no Solidity test can assert this about itself. Never skip it after touching the token hierarchy (`src/tokens/`), and never "fix" a failure by editing the check.

## docs
Any time a change is made to the contracts in `src/` that affects events, we should update the `docs/events-per-entry-point.md` document. Example changes that should trigger this update:
- event name/signature changes
- event order changes
- new events added or events removed (new functions added / removed) 
