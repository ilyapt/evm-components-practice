# evm-components-practice

Practice tasks for experienced EVM engineers: build the components that
wallets, account-abstraction stacks, relayers, and upgradeable systems are
made of, and understand them well enough to defend every design decision.

Typed-data signing, contract signatures, ERC-4337 accounts and paymasters,
EIP-7702 delegation, meta-transactions, proxies, and the off-chain
infrastructure around them — each task is one real component with a precise
set of requirements, a starter file, and tests that run against the real
EntryPoint, real signatures, and fuzzed inputs.

No tokens. ERC-20, ERC-721, permits, and DeFi math are out of scope: the
subject is accounts, signatures, delegation, and ownership.

This is not a CTF and not interview simulation. Tasks take from half an hour
to a few hours.

## Requirements

- [Foundry](https://getfoundry.sh) (forge 1.8+); solc 0.8.28 is downloaded
  automatically.
- Go 1.26+ for the off-chain track (tasks 070 and up).
- Optional: an AI coding agent (Claude Code, Codex, Cursor, ...) to act as a
  tutor and reviewer. Instructions for it are in [AGENTS.md](AGENTS.md).

## How to use

Fork the repository and solve tasks in place: your fork keeps your solutions
and your progress.

Pick a task from the [list below](#tasks), read `<task>/README.md`, answer the
"Before coding" questions for yourself, then implement `<task>/starter.sol`
(or `<task>/starter.go` on the off-chain track). It is the only file you need
to change. Run the tests with:

```bash
forge test --match-path "001-eip712-typed-data/*" -vv
```

and on the Go track:

```bash
go test -race -count=1 -timeout=60s ./070-nonce-manager/
```

To start a task over:

```bash
git checkout -- 001-eip712-typed-data/starter.sol
```

### With an AI tutor

Open the repository in your agent and say something like "start eip712".
The agent will walk you through clarification, invariants, implementation,
tests, and a review against the task's reviewer notes. In Claude Code you can
also use `/start <task>`, `/hint`, `/review`, and `/next`.

### Without an AI tutor

Everything works without an agent. `<task>/REVIEW.md` contains the
reviewer notes: which failures the tests catch and which they do not, the
choices the statement leaves open, and follow-up questions. It is a spoiler —
read it after your attempt.

## Tasks

Each task is a numbered directory in the repository root. Linked tasks are
available; the rest are planned and will appear under the same number.

Numbers group tasks by topic and order them within a topic, from simpler to
harder. Tasks 001–069 are on-chain (Solidity, Foundry); 070–099 are off-chain
(Go, against a fake chain). You do not have to go through all of them in
sequence:

1. **Start with "Signatures and typed data".** At least 001, 002, and 003:
   how a typed message is hashed, how a signature is checked without being
   fooled, and what stops a signed message from being replayed. Every account,
   paymaster, and forwarder builds on these.
2. **Then take topics in any order** — by interest, by what your work needs,
   or by what you find hardest. Within a topic, follow the numbers.
3. **Leave the capstones for last.** Each combines patterns from several
   topics.

A few tasks build on specific earlier ones; their statements say so (for
example, 027 builds on 011 and 026).

### Signatures and typed data

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 001 | [eip712-typed-data](001-eip712-typed-data/README.md) | EIP-712 domain separator, struct hashing, nested structs and arrays | medium |
| 002 | [signature-verification](002-signature-verification/README.md) | `ecrecover` without the footguns: malleability, `v` forms, EIP-2098 | easy |
| 003 | [replay-protection](003-replay-protection/README.md) | Signed actions bound to nonce, deadline, chain, and contract | medium |
| 004 | [eip1271-signatures](004-eip1271-signatures/README.md) | One checker for EOA and contract signatures (EIP-1271) | easy |
| 005 | [erc7739-rehashing](005-erc7739-rehashing/README.md) | EIP-712 inside EIP-1271 without cross-account replay (ERC-7739) | hard |
| 006 | erc6492-counterfactual | Verify signatures of accounts that are not deployed yet | medium |
| 007 | erc5267-domain-discovery | Let wallets discover the EIP-712 domain of a contract | easy |
| 008 | passkey-verification | P-256 / WebAuthn signatures with RIP-7212 and a fallback | hard |
| 009 | threshold-signatures | k-of-n owner signatures with ordering and dedup | medium |

### Account abstraction (ERC-4337)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 011 | [erc4337-account](011-erc4337-account/README.md) | Minimal account against the real EntryPoint: validation, prefund, execution | medium |
| 012 | parallel-nonce-keys | Sequential and parallel operation lanes with 2D nonces | medium |
| 013 | [verifying-paymaster](013-verifying-paymaster/README.md) | Sponsor signatures, validity windows, `postOp`, deposit and stake | medium |
| 014 | gas-policy-paymaster | Per-account and per-period gas budgets without tokens | hard |
| 015 | validation-rules | What `validateUserOp` may touch and why (ERC-7562) | hard |
| 016 | [session-keys](016-session-keys/README.md) | Scoped keys: targets, selectors, limits, expiry, revocation | hard |
| 017 | erc7579-modular-account | Validator, executor, hook, and fallback modules | hard |
| 018 | [batch-executor](018-batch-executor/README.md) | ERC-7821 batches with EIP-5792 atomicity semantics | medium |
| 019 | account-factory | CREATE2 factory, `initCode`, and counterfactual addresses | medium |
| 020 | signature-aggregator | Aggregated validation for many operations in one bundle | hard |

### EIP-7702

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 026 | [eoa-delegation](026-eoa-delegation/README.md) | Delegated EOA: initialization without a constructor, self-calls, revocation | medium |
| 027 | [eip7702-account](027-eip7702-account/README.md) | EOA as an ERC-4337 account through EntryPoint v0.8 | hard |
| 028 | delegate-migration | Switching delegates safely: ERC-7201 namespaced storage, migrations | medium |
| 029 | delegation-framework | Caveated delegations and permissions (ERC-7710, ERC-7715) | hard |

### Meta-transactions

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 036 | erc2771-forwarder | Trusted forwarder and `_msgSender` recovery, forged-forwarder attacks | medium |
| 037 | relayer-refund | Relayer that is refunded exactly its gas, replay between relayers | medium |

### Proxies and deployment

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 041 | eip1967-slots | Implementation and admin slots, `delegatecall` dispatch | easy |
| 042 | erc1167-minimal-proxy | Clones with and without immutable args | easy |
| 043 | uups-upgradeable | Upgrades from the implementation, bricking protection | medium |
| 044 | beacon-proxy | Upgrading many proxies at once | medium |
| 045 | eip2535-diamond | Facets, selectors, loupe | hard |
| 046 | create2-factory | Deterministic addresses and salts that bind the deployer | medium |
| 047 | transient-storage | EIP-1153 reentrancy guards and temporary approvals | medium |

### Defensive patterns

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 053 | reentrancy | Cross-function and read-only reentrancy, checks-effects-interactions | medium |
| 054 | pull-payments | Payments that cannot be blocked by the recipient | easy |
| 055 | two-step-ownership | Access control that cannot be lost by a typo | easy |
| 056 | timelock | Queued operations with delays, cancellation, and grace periods | medium |

### Capstone (on-chain)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 065 | smart-wallet | Passkey owner, session keys, batches, paymaster, ERC-7739, 7702 or 4337 | hard |

### Transaction sending (Go)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 070 | nonce-manager | Pending nonces, gaps, and resets for a shared sender | medium |
| 071 | fee-estimator | EIP-1559 fees and replacement bumps | medium |
| 072 | receipt-watcher | Confirmations, reorgs, and finality | hard |

### Chain reading (Go)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 078 | event-indexer | Log indexing with reorg handling | hard |
| 079 | multicall-client | Batching reads through Multicall3 with partial failures | medium |

### Bundler (Go)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 084 | userop-mempool | Mempool with per-sender rules and reputation | hard |
| 085 | bundle-builder | Gas limits, ordering, dropping failed operations | hard |
| 086 | bundler-rpc | ERC-7769 methods over a fake chain | medium |

### Services (Go)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 092 | paymaster-service | Policy, signing, validity windows, deposit tracking | medium |
| 093 | authorization-client | Signing and submitting EIP-7702 authorizations | medium |

### Capstone (off-chain)

| # | Task | What you build | Difficulty |
|---|---|---|---|
| 099 | account-stack | Factory, paymaster service, and bundler client together | hard |

## How the tests work

- Solidity tests run with Foundry. Where a task touches ERC-4337 or
  EIP-7702, the tests run against the real EntryPoint v0.8 from
  `lib/account-abstraction` and real EIP-7702 delegations (Foundry's
  `signAndAttachDelegation`), not mocks.
- Signatures are real: tests sign with `vm.sign` and compare hashes with
  vectors produced by reference implementations.
- Fuzz tests try random inputs; invariant tests try random call sequences.
  A failing fuzz test prints the counterexample — read it as a scenario.
- Go tests run with `-race` and inside `testing/synctest` bubbles against a
  fake chain; time is virtual and leaked goroutines fail the test.
- Foundry compiles every Solidity file in the repository on each run, so a
  starter that does not compile breaks the tests of every task until it is
  fixed or reset with `git checkout`.
- Tests check the requirements and the failures that are hard to see by reading
  code. Passing tests do not mean the design is good — that is what the review
  is for.

## License

[MIT](LICENSE)
