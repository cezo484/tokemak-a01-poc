# Tokemak A-01 PoC — Division by zero in `totalAssetsTimeChecked` freezes the vault

After a solver fully exits a destination, that destination keeps
`ownedShares == 0` while staying in the debt reporting queue. Once its
report goes stale (more than 1 day old), every call to
`AutopoolDebt.totalAssetsTimeChecked` reverts with a division-by-zero
panic (0x12). All user flows for the Autopool stop: deposit, mint,
withdraw, redeem, previews, and max functions. Only the team can
recover it, by calling `updateDebtReporting`.

## Run

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
forge install foundry-rs/forge-std
forge test --match-contract TokemakA01Test -vv
```

The test forks Ethereum mainnet at block 26433223 through a public RPC
(no API key needed). Expected result: the single test passes, proving
all 9 user flows revert with panic 0x12 while the vault is frozen, and
that `updateDebtReporting(10)` recovers it and the user fully redeems.

## Note on the setup

`lastReport` is backdated with `vm.store` instead of warping time,
because warping freezes the Chainlink feeds (2h pricing timeout) and
the oracle reverts first, masking the bug.
