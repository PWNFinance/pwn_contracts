# Crowdsource vault repayment claims (PR #85)

This vault version separates earned credit-token proceeds from ownership of the remaining loan. Collecting repayments does not burn shares. Shares carry future proceeds and proportional default collateral; previously earned cash stays with its owner when shares move.

This is a new-vault interface. Existing v1.5 vault deployments are immutable and retain their old withdrawal behavior. Integrations must select the interface by deployed vault version. Do not infer availability from a cached stage or use old `withdraw` calls for this version's repayments.

## Operations

| Operation | Pooling | Running loan | Repaid/defaulted loan |
| --- | --- | --- | --- |
| `deposit` / `mint` | ERC4626 pricing, bounded deposit rounding, and Aave supply | Disabled | Disabled |
| `withdraw` | Withdraw credit and burn shares | Disabled | Disabled |
| `redeem(shares, receiver, owner)` | Withdraw credit and burn shares | Disabled | Settle if needed, accrue owner's cash, burn shares, transfer proportional collateral; returns zero credit |
| `claimableRepayments(owner)` | Zero | Earned unclaimed credit | Earned unclaimed credit, including for former holders |
| `claimRepayments(receiver)` | Disabled | Claim all caller's earned credit without burning | Same; no liquidation required |
| `claimAndRedeem(receiver)` | Disabled | Disabled | Settle, claim caller's credit, redeem all caller's shares; returns `(repayments, collateral)` |

Zero cash claims are no-ops. The combined exit also works for a former holder with cash but no shares. ERC20 share allowances authorize share transfers and terminal collateral redemption, but never another address's earned cash. Cash is always claimed by its owner, who may select a receiver.

`RepaymentsClaimed(owner, receiver, assets)` records cash distributions. Terminal burns emit the existing `Withdraw` event with zero credit assets and, when collateral is paid, `WithdrawCollateral`. Claiming cash never emits a share burn.

`maxWithdraw` is zero after funding. `maxRedeem` is zero during a running loan and exposes the full share balance once the loan has ended, even before the first settlement transaction. `previewRedeem` returns zero credit at termination; use `previewCollateralRedeem` for collateral and `claimableRepayments` for credit. Before termination, conversion/preview functions can quote the debt value of locked shares; a positive preview does not permit redemption.

Deposits additionally require positive shares for positive assets and at most one smallest credit-token unit of difference between the deposit amount and `previewMint(mintedShares)`. Large donation-induced rounding therefore reverts before moving funds. Because the mint quote itself rounds upward, the exact conversion loss can still approach two base units; this is not a zero-rounding guarantee. If an amount is not representable at the current share price, use exact-share `mint`. `previewDeposit` remains a conversion quote and does not apply this execution limit.

This guard also addresses an inherited pooling/default issue: a colluding borrower could exploit a victim's large deposit-to-share rounding loss and recover their own actual-share fraction of collateral on default. Banning only zero-share deposits would not cover positive-share rounding attacks. The new guard bounds this conversion difference while retaining the existing pricing formula and collateral distribution policy.

## Accounting

Physical cash includes unutilized funding capital, borrower repayments, and direct credit-token donations. A cumulative index assigns each new receipt once. Each address stores its last index, whole claimable credit, and a fractional remainder. The index also carries its division remainder between receipts. Claims and transfers take constant work with respect to the number of holders and past repayments.

Before a transfer, cash is checkpointed for both parties using their old balances. Both the seller's whole cash entitlement and fractional remainder stay with the seller. Before a terminal burn, the owner's earned cash is checkpointed. Burning the last share never removes previously earned cash or makes it depend on share value.

While pooling, `totalAssets` includes cash and Aave assets. After funding it reports only the remaining running loan debt; it becomes zero upon repayment/default. Credit cash is already a separate distribution entitlement, so collecting it does not change the remaining share value. Repaying principal reduces that value without changing share count. Interest accrual increases debt value. These are debt-value views using the existing ERC4626 virtual conversion convention, not a combined valuation of credit and collateral.

For example, Alice owns 25% and Bob 75%. After a 20 USDC repayment, approximately 5 and 15 USDC are independently claimable, subject to integer rounding and the virtual reserve below. Alice collecting her 5 does not change either holder's percentage. On default, they still receive 25% and 75% of collateral, and Bob can independently collect his earlier 15.

## Virtual reserve and rounding

The existing OpenZeppelin pooling formula uses one virtual asset and one virtual share (both in smallest units). The repayment index credits that one virtual asset exactly once at funding and retains the virtual share in its denominator. With unchanged ownership/supply, the exact reference entitlement is:

`holderShares * (cumulativeCreditReceived + 1) / (fundingShares + 1)`

The implementation uses a 1e27 fixed-point index and full-precision quotient/remainder arithmetic. Fractions are retained across claims and checkpoints; transfers can shift sub-unit index rounding between owners. Tests compare the resulting balances to an independent receipt-by-receipt rational model.

No final-exit method distributes all remaining credit indiscriminately. Remaining cash may consist of other holders' earned entitlements, fractional claim rounding, or the protected virtual reserve. There is no PWN reserve beneficiary or administrative sweep. Default collateral uses actual share supply and has no virtual collateral reserve; the last real shareholder receives the remaining collateral.

The virtual reserve is normally tiny for normal share supplies, but it is **not universally dust**. For one smallest share unit and 100 USDC of credit proceeds, approximately 50 USDC remains protected after exit. The tests deliberately retain this behavior and ensure that repayment claims cannot refund the pooling donation reserve. This policy is distinct from the former 2,368.42 USDC allocation bug: earned whole cash is never blocked because its owner has insufficient shares.

New credit donations after partial terminal exits accrue only to remaining shares, without reallocating old cash. After total supply reaches zero, unsolicited new cash has no shareholder beneficiary; prior entitlements remain claimable, and the donation remains unallocated.

## Settlement and dependencies

Aave is used only during pooling. Funding withdraws the entire Aave balance; principal then leaves under the PWN loan lock. Cash is first allocated after that lock is released. The repayment hook only accepts repayments and does not call Aave or mutate distribution accounting.

If the core loan holds a fallback repayment, the vault recovers it before checkpointing a claim, ownership transfer, or terminal burn. Claim views include recoverable core-held credit. Recovery and later allocation cannot count the same receipt twice. A failed recovery reverts the attempted checkpoint, preserving ownership and existing accounting.

Standalone cash claims do not liquidate default collateral. A failed liquidation therefore does not, by itself, prevent collecting existing credit. Terminal redemption and the combined exit liquidate once and distribute the resulting collateral. All state-changing paths use reentrancy protection; loan-context locks prevent funding or repayment callbacks from observing allocatable transient balances. `claimableRepayments` returns zero during vault operations and loan callbacks rather than quoting transient cash.

Supported credit and collateral are ordinary ERC20 assets without rebasing or transfer fees. New vaults require distinct credit/collateral tokens. Zero-address or vault-self receivers are rejected to avoid stranding cash or shares.

## Validation

The unit tests cover separate claim rights, transfer history, zero-share owners, terminal views and burns, fallback repayments, callback/reentrancy failures, and virtual reserve protection. Stateful randomized tests compare cash rights against a rational model for 6- and 18-decimal assets and verify cash conservation and backed claims throughout.

Mainnet fork tests exercise real PWN loan/installment contracts and Aave pooling, including Aave failure after funding, default collateral distribution, and a twenty-year loan term with more than fifteen years of monthly repayments and different lender claim frequencies.

See [validation and gas measurements](crowdsource-repayments-validation.md) for the test coverage, review results, and benchmark limits.
