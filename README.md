# Morpheus D-1 PoC — direct-payment debit/credit asymmetry

Foundry proof-of-concept for a bug-bounty report against the Morpheus
LumerinDiamond (`0x6aBE1d282f72B474E54527D93b979A4f64d3030a` on Base).

**Finding (summary):** in `closeSession`, `_rewardUserAfterClose` debits the
user the FULL uncapped provider reward, while `_rewardProviderAfterClose` →
`_claimForProvider` credits the provider only up to
`(stake - limitPeriodEarned)`. The spread is permanently bricked in the
diamond: never returned to the user, never paid to the provider.

## Run

Requires [Foundry](https://book.getfoundry.sh/). From a clean clone, one command:

```shell
forge test
```

The test forks Base mainnet at pinned block **51840354** (see `foundry.toml`)
and uses only the public `https://mainnet.base.org` RPC endpoint — no API keys.

## Expected result

```
[PASS] test_directPayment_debitCreditMismatch()
```

The test opens a direct-payment session (1000 MOR user stake, 2-day session,
minimum-stake provider), closes it, and asserts:

- provider reward earned: **1.728 MOR**
- provider actually received: **0.2 MOR** (capped at `stake - limitPeriodEarned`)
- bricked spread: **1.528 MOR**
- user permanent shortfall: **1.728 MOR**, unrecoverable via `withdrawUserStakes`

No privileged accounts are used anywhere in the test.

## Layout

- `test/DirectPaymentMismatch.t.sol` — the PoC test
- `foundry.toml` — fork config (Base, pinned block 51840354)
- `lib/forge-std` — vendored dependency
