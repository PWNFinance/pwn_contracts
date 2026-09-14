# PR #85 validation and gas measurements

## Test scope

The final source was tested with Solidity 0.8.16, optimizer enabled (200 runs), the repository's Prague EVM configuration, and Foundry 1.7.1-dev.

- Vault unit suite: **97 passed**, including both independent rational accounting models at **1,000 randomized runs each**, with 96 mixed receipt/claim/transfer actions per run followed by repayment or default and complete exits.
- Mainnet vault fork suite: **23 passed**, covering real core-held repayment recovery, Aave unavailability after funding, repayment/default settlement, and more than fifteen years of monthly repayments under a twenty-year term.
- Full repository suite: **611 passed**, including the existing stable-product fork tests. An inherited USDT/ARB fixture needed its collateral funding derived from current oracle prices; its expected collateral assertion and protocol behavior are unchanged.

The tests explicitly retain the protected virtual reserve while checking that earned cash remains available to zero-share owners. Deposit-rounding regressions cover zero-share deposits, both positive-share donation examples identified in review, and accepted one-base-unit differences above the rounded mint quote.

## Gas comparison

Identical local real-token fixtures compare this implementation with `aeb5654` (`v1.5-deployment-changes`). The fixture starts with Alice 25,000 / Bob 75,000 USDC units, lends80,000, and uses the same loan-lock/debt/token-movement model for both versions. Baseline cash collection uses `withdraw`; the updated version uses `claimRepayments`. Final exit compares baseline `redeem` with updated `claimAndRedeem`.

These are measured call execution gas values, **before transaction-wide refunds**, excluding transaction intrinsic/calldata costs, Base L1 data fees, and Aave pooling execution. The fixture uses a loan model, not a deployed mainnet loan, and earlier operations can warm storage. Treat the figures as a reproducible comparison of these scenarios, not exact transaction fees or USD estimates. In particular, the later-claim row should not be used as a cold-transaction estimate.

| Scenario | v1.5 base | Updated | Difference |
| --- | ---: | ---: | ---: |
| First cash claim | 56,869 | 124,174 | +67,305 |
| Later claim after another repayment | 23,356 | 22,742 | -614 |
| First running transfer to an existing holder | 13,331 | 193,547 | +180,216 |
| Borrower repayment | 30,185 | 30,205 | +20 |
| Final cash claim and full share exit | 76,040 | 141,765 | +65,725 |
| Pooling deposit | 34,858 | 42,563 | +7,705 |
| Pooling withdrawal | 64,143 | 69,101 | +4,958 |
| Loan funding | 259,788 | 311,612 | +51,824 |

The biggest increase is the first running share transfer: it records both holders' past cash rights and fractional checkpoints. Subsequent costs depend on whether those storage slots already exist. Borrower repayments still use the pure hook and have essentially unchanged modeled execution. The new claim/checkpoint implementation avoids writing a newly earned whole cash balance only to clear it immediately.

## Standards review

No material documented-standard violation or consequential design smell was found. The grouped allocation state, shared remainder arithmetic, and separate cash/settlement helpers keep the responsibilities clear. The final checkpoint optimization and collateral-ratio simplification were reviewed separately.

## Spec and security review

No additional confirmed regression remained in the final independent source review. The reviewed behavior includes retained seller entitlements, zero-share claims, terminal views, core fallback recovery, shared final-exit helpers, and reentrancy/loan-context guards.

The review additionally identified an inherited donation/default attack through deposit conversion losses. The new deposit guard blocks the material examples, including ones that mint positive shares. It allows at most one unit above the rounded-up mint quote, so exact conversion losses can still approach two credit-token base units per deposit. Exact-share mint rounding and collateral rounding are separate. This is a bounded rounding policy, not a claim that every deposit has zero loss.

An inherited collateral-preview observation remains: during a callback from a nonstandard collateral token's outgoing transfer, shares may already be burned while the token's balance has not yet decreased. External consumers must not treat such transient collateral views as a settled price. No new exploit of this PR was demonstrated; supported assets are ordinary ERC20s, and the claim view explicitly suppresses transient cash quotes.

This review and testing are evidence for the implemented scenarios, not a formal proof or an independent external audit.
