## formatting
run `forge fmt` after any modification to .sol files

## tests
Every suite forks Robinhood mainnet, the project's main chain, so `fast-test` first retargets the token impls at it (`just chain-rh`) and runs everything on the `[profile.robinhood]` build: the unit suites, then the Robinhood fork integration suites (`test/integration/fork/robinhood/`, real xStock dividends) via `just test-rh-fork`. The impls bake one chain's addresses and refuse a mismatched chain id, so a bare `forge test` on a tree retargeted elsewhere fails in `setUp()` with a call to a non-contract address. `fast-test` leaves the tree retargeted at Robinhood mainnet; the committed default is Robinhood testnet, so run `just chain-rh-testnet` before committing if you do not want the retarget in the diff.

`foundry.toml` sets `code_size_limit` to Robinhood's 96 KB: the taxable tokens exceed EIP-170's 24 KB, so they deploy on Robinhood only, never on Ethereum mainnet.

## docs
Any time a change is made to the contracts in `src/` that affects events, we should update the `docs/events-per-entry-point.md` document. Example changes that should trigger this update:
- event name/signature changes
- event order changes
- new events added or events removed (new functions added / removed) 
