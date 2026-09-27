# Implementation review notes

These are builder notes and test evidence for the independent reviewer. They are not
an independent review or a security audit. Release review must also inspect the final
`launch.json` produced by the manifest assignment.

| Attack / boundary | Local evidence |
| --- | --- |
| Mint, privileged token calls, fee or allowance accounting | `test/LaunchToken.t.sol`: fixed supply, exact transfers, failed spend rollback, zero addresses, finite/unlimited allowances, missing admin selectors |
| Depositor races beneficiary at lapse | `test/DeadMansSwitch.t.sol`: ping at `D-1` resets deadline and prevents old-deadline claim; maintenance at `D` fails and claim succeeds |
| Recovery race | Same file: recovery at `R-1` fails; at `R` either party can close first and the second transaction fails |
| Outsider extends timer or drains ETH | All depositor mutations tested from beneficiary and outsider; claim/reclaim authority tested before/after relevant boundaries; invalid calls preserve clock |
| Recipient rejects payout | Withdrawal restores clock/balance; claim and reclaim restore open state; alternate recipients and subsequent independent payouts succeed, including zero balances |
| Reentrant payout or cross-switch mutation | `test/DeadMansSwitchReentrancy.t.sol`: all payout paths, same and different switches, every mutation attempted in a withdrawal callback; callbacks observe already-applied effects |
| Cross-switch balance leakage | Per-id excess withdrawal fails despite other deposits; settlement leaves other balances intact; stateful invariant compares each balance to independently tracked inflows/outflows |
| Event discovery and closed state | Indexed creation/change events, payouts and maintenance logs checked; all seven per-id mutations fail after either settlement; historical views remain available |
| Factory context and deployment floor | `test/Deployment.t.sol`: empty-argument CREATE2 deployment, all tokens stay at factory, app has no token dependency or factory privilege, nonpayable constructors, runtime size and opcode scan |

`test/DeadMansSwitchInvariant.t.sol` limits generated switch count to 24 and uses four
accounts. Random operations include time advancement, creation, deposits, withdrawals,
settings, keep-alive, settlements and unauthorized calls. It checks:

- Contract ETH equals the sum of open switch balances and total accepted inflows less outflows.
- Every switch balance matches its own tracked flows; closed switches have zero liability.
- Recipients receive exactly the recorded amounts, without fees or pooled balance leakage.
- Every remaining balance can be recovered after the final timeout.

Ineligible generated actions are skipped, while unexpected reverts fail the invariant
run. Unit tests separately assert rejection on invalid inputs and at exact boundaries.
The forced-surplus unit test is deliberately outside the equality invariant: the EVM can
credit ETH without a contract call. There is no administrative surplus recovery function.

Solidity/Foundry may issue generic timestamp and ETH-call lint warnings. Timestamp
comparisons implement the requested deadline semantics. ETH destinations are either the
authenticated depositor or selected by the authenticated beneficiary/depositor. Balance,
clock and closure effects precede the call; the shared guard remains locked throughout
the call and unlocks afterward. The callback tests exercise these paths explicitly.

Residual assumptions include transaction inclusion timing, valid party keys, contract
wallets capable of invoking actions, recipients able to accept payment, trustworthy
frontend RPC responses, and deployment only to Sepolia. There is no oracle, randomness,
automation dependency, token hook, external library call, delegatecall, proxy, upgrade,
or privileged rescue path. Tests do not certify the future deployment service, policy,
factory implementation, frontend, or manifest. Review those artifacts separately.
