# Heartbeat (BEAT) / DeadMansSwitch

**Sepolia test toy — not a custody or inheritance product. Use only Sepolia test ETH.**

This contribution implements the contracts and their tests for `lab-deadmans-switch`.
`LaunchToken` is the independent Heartbeat ERC-20 (BEAT). `DeadMansSwitch` manages
per-switch ETH balances and never calls or uses BEAT. There are no production
dependencies, owners, administrators, pause controls, upgrades, or initialization calls.

## Build and check

Install Foundry and Solidity **0.8.26** before entering an offline environment. The
compiler is pinned by version in `foundry.toml`; no compiler binary is part of the project.
All test dependencies are ordinary files under `lib/forge-std/`.

```sh
forge build
forge test
forge fmt --check
```

Tests require no RPC, wallet, environment variables, FFI, or filesystem cheatcodes.
They cover ERC-20 supply and allowances, authorization, exact lapse/recovery boundaries,
clock resets, failed payouts, zero balances, closure, cross-switch isolation, reentrancy,
and factory constructor context. The stateful invariant runs 128 sequences of up to
64 operations across multiple accounts, checks per-switch accounting and net ETH flow,
then proves all remaining balances can be reclaimed. It does not constitute an audit.

ABI exports are [LaunchToken.json](docs/abi/LaunchToken.json) and
[DeadMansSwitch.json](docs/abi/DeadMansSwitch.json). See the
[interface documentation](docs/INTERFACE.md) for methods, events, errors, and indexing.
Regenerate the exports after a source change:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/DeadMansSwitch.sol:DeadMansSwitch abi --json > docs/abi/DeadMansSwitch.json
```

## Switch lifecycle

1. A depositor calls `create(beneficiary, period)`, optionally with ETH. Ids start at 1.
   The beneficiary must be nonzero and distinct from the depositor. Periods are seconds,
   inclusive from 86,400 (1 day) to 31,536,000 (365 days). Creation starts the clock.
2. While `block.timestamp < lastPing + period`, only the depositor can ping, deposit,
   withdraw, change beneficiary, or change period. Every successful action resets
   `lastPing`, even if a setting is unchanged. Deposits and withdrawals must be positive;
   a withdrawal cannot exceed that switch's balance. A full withdrawal leaves it open.
3. At `block.timestamp >= lastPing + period`, depositor maintenance stops permanently.
   Only the current beneficiary may `claim(id, to)` for the full recorded balance.
4. At `block.timestamp >= lastPing + period + 365 days`, the depositor may also
   `reclaim(id, to)`. The beneficiary remains eligible: the first successful transaction
   closes the switch and wins. Recovery uses the latest successful ping and period.
5. Claim/reclaim close even an empty switch. Every subsequent mutation on that id reverts.
   Views remain readable for history; `timeLeft` is zero. A new switch needs a new id.

Withdrawals pay the depositor. Claim/reclaim permit any nonzero recipient so a smart
contract beneficiary can route payment elsewhere. Payouts use `call`, after accounting
effects; a shared reentrancy guard blocks all callback mutations, including other switches.
Failed calls revert the entire operation, including the clock, closure and event logs.
Even a zero-value claim calls the recipient. A failed recipient can be replaced on retry.

## Deployment parameters and responsibilities

| Parameter | Required value |
| --- | --- |
| Deployment network | Sepolia, chain id `11155111` |
| Project kind / site label | `evm_project` / `lab-deadmans-switch` |
| Token artifact | `src/LaunchToken.sol:LaunchToken` |
| Token constructor arguments / value | `[]` / `0` |
| Token metadata | `Heartbeat`, `BEAT`, 18 decimals |
| Fixed supply | `1000000000000000000000000000` minor units (`1,000,000,000 BEAT`) |
| Supply recipient | Constructor `msg.sender`, therefore the project factory |
| Application artifact | `src/DeadMansSwitch.sol:DeadMansSwitch` |
| Application identifier / constructor arguments / value | `DeadMansSwitch` / `[]` / `0` |
| Application dependencies / privileged constructor addresses | None / none |
| Compiler / EVM / optimizer | Solidity `0.8.26` / Cancun / enabled, 200 runs |
| Metadata bytecode hash | `none` |

Both constructors are nonpayable. No application token balance or funding is required
at deployment. The app is immediately usable, and switch creation is a user action
after deployment. Network selection is enforced by the deployment service and frontend;
the contracts have no chain-id gate. Do not deploy or advertise this toy on mainnet.

The separate manifest assignment writes `launch.json` from the accepted artifacts, naming
the token and the single application above. Policy selection, policy-bound ownership,
LP/reward allocation, opening price, and signed artifact linkage belong to services.
There is no privileged application wallet to substitute, no initialization transaction,
and no source-level conflict that can be resolved by changing policy linkage.

An independent contributor must review the accepted source **and** final manifest
before release, including lapse/recovery transaction ordering, all three payout callback
paths, third-party keep-alive attempts, and cross-switch accounting. This source
contribution supplies adversarial tests and [review notes](docs/SECURITY.md); it does not
claim that independent review has happened or that a manifest has been approved.

After review, services publish source, attest, admit and deploy through ProjectFactory.
The deployment service supplies the actual factory address, deployment block, deployed
addresses, and transaction/artifact references. No transactions or wallet operations are
part of this contribution. These later service outputs are not needed for local builds.

The later frontend assignment builds one static page against that live deployment,
exporting `dist/index.html`, enforcing Sepolia, and displaying the test-toy banner above.
It discovers switches from views and events only, with no backend/indexer; see the
interface notes. GitHub publication and IPFS hosting are later service responsibilities.

## Operational assumptions

Depositors are responsible for keeping keys and pinging well before expiry; there is
no automatic keeper. Beneficiaries must control a wallet capable of calling `claim`,
and recipients must accept ETH. The contract validates address shape, not key ownership
or a beneficiary contract's ability to transact. If both parties lose access, funds can
remain inaccessible. There is no administrator to restore access or rescue assets.

Time is the chain's block timestamp, not a promise about wall-clock inclusion. A ping
sent before a deadline can arrive too late. Pending transactions and reorgs can change
which claim/reclaim wins; the UI must wait for confirmations and refresh state.

Ordinary ETH transfers and unknown selectors revert. Only `create`/`deposit` credit a
switch. Under supported operations, the contract's ETH equals the sum of open balances.
The EVM can force ETH into any address without invoking its code (for example, another
contract's forced transfer). Such surplus is unallocated and cannot be swept; in that
case the balance is **at least** the sum of liabilities. Tests model this exception and
ensure it never increases a user's payout. Accidentally sent ERC-20 tokens, including
BEAT, are likewise unrecoverable. Never send tokens to the application.

BEAT is a plain fixed-supply ERC-20, with no fees, mint/burn path, owner, or token hooks.
Maximum allowance is treated as unlimited; finite `transferFrom` calls reduce allowance.
When changing an existing allowance, a holder should account for already pending spends
(for example by confirming revocation before granting a replacement).
