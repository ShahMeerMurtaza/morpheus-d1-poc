# D-1: Direct payment debit and credit mismatch in LumerinDiamond closeSession

## Summary

When a direct payment session is closed, closeSession debits the user the full
uncapped provider reward, while the provider is credited only up to stake minus
limitPeriodEarned. The difference stays locked in the diamond contract. It is
not returned to the user and it is not paid to the provider.

## Impact

Demonstrated on a Base mainnet fork at block 51840354.

- Provider reward earned: 1.728 MOR
- Provider credited: 0.2 MOR, capped at stake minus limitPeriodEarned
- Value locked in the diamond: 1.528 MOR
- User permanent shortfall: 1.728 MOR, not recoverable through withdrawUserStakes

## Affected contract

- LumerinDiamond on Base: 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
- MOR token on Base: 0x7431aDa8a591C955a994a21710752EF9b882b8e3

## Reproduction

Run: forge test

The test forks Base mainnet at pinned block 51840354 through the public Base
RPC endpoint. No API key is needed. No privileged accounts are used.

Expected result: test_directPayment_debitCreditMismatch passes.

The test opens a direct payment session with a 1000 MOR user stake and a
minimum stake provider, closes the session after the session period, then
checks the provider payout, the locked spread, and the user shortfall stated
above.

## Files

- foundry.toml: fork configuration, Base mainnet, pinned block 51840354
- test directory: DirectPaymentMismatch.t.sol, the proof of concept test
- lib directory: vendored forge-std dependency
