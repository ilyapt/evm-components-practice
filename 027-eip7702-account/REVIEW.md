# Reviewer notes: eip7702-account

> Spoilers. Read after your attempt.

## Test coverage notes

- **The signer is compared against a stored or constructor-set owner instead
  of `address(this)`.** Caught by
  `test_OpSignedByTheEoaKeyExecutesAndTargetSeesTheEoa` (no owner was ever
  set, so validation returns 1 and the EntryPoint reports `AA24`) and by
  `test_StandaloneImplementationCannotValidate` if the constructor stored the
  deployer.
- **A bad signature reverts (`require(signer == address(this))`, or
  `ecrecover` fed a short signature through calldata slicing without a length
  check).** Caught by `test_MalformedSignatureIsReportedNotReverted` and
  `test_OpSignedByAnotherKeyFails`, which expect `AA24 signature error`
  rather than `AA23 reverted`.
- **`validateUserOp` is callable by anyone.** Caught by
  `test_ValidateUserOpOnlyFromEntryPoint`. Note that the self-call path
  (`msg.sender == address(this)`) must also be rejected there: letting the
  EOA "validate" is harmless by itself, but a validation that also pays the
  prefund to `msg.sender` would then pay the EOA's ETH to whoever is
  `msg.sender`.
- **Prefund paid from a stored deposit, sent to `entryPoint()` instead of
  `msg.sender` (same address here, but ask), or not sent at all.** Caught by
  `test_PrefundIsPaidFromTheEoaBalance` and `test_UnpaidPrefundIsRejected`
  (`AA21 didn't pay prefund`).
- **`execute` accepts any caller, or only the EntryPoint (no self-call
  path).** Caught by `test_StrangerCannotExecute` and
  `test_SelfCallExecutesWithoutTheEntryPoint`.
- **`execute` accepts the `SenderCreator` call made for a long `0x7702`
  initCode (for example by authorizing `tx.origin == address(this)` or any
  caller with "no code").** Caught by
  `test_MarkerInitCallDataIsNotRunByTheEntryPoint`, which expects
  `FailedOpWithRevert(0, "AA13 EIP7702 sender init failed", NotAuthorized())`.
- **The account hashes something of its own instead of signing
  `userOpHash` (for example re-hashing `userOp` without the 7702 override).**
  Caught by `test_MarkerInitCodeOpSucceeds` and
  `test_MarkerInitCodeBindsTheHashToTheDelegate`.
- **The batch continues after a failed call or reverts without the index.**
  Caught by `test_SelfCallExecuteBatchRunsInOrderAndRevertsWithIndex`.
- **The EntryPoint address is kept in storage and set in the constructor.**
  Caught by `test_DelegatedEoaReportsTheImplementationsEntryPoint` and by
  every operation test (the EOA's storage slot is zero, so `validateUserOp`
  rejects the real EntryPoint).
- **Validation reads `block.timestamp` or `block.number`, or touches storage
  outside the account.** Not caught: Foundry does not enforce ERC-7562.
  There is no time window here, so the usual reason to read the clock is
  absent; look for accidental uses (for example emitting an event with a
  timestamp, which is allowed, versus branching on it, which is not).
- **Reentrancy from a target back into `execute` through the self-call path
  is impossible (the target is not `address(this)`), but through the
  EntryPoint path it is also impossible during execution because `handleOps`
  is `nonReentrant`.** Not caught; worth stating so the user does not add a
  guard that buys nothing.
- **Return-data bombs in `CallFailed`.** Not caught.

## Open choices

- Whether `execute` may target `address(this)`. Here the self-call is the
  owner path, so an operation that makes the EOA call its own `execute` is
  pointless but harmless; with session keys or operators (016, 026) it is the
  escalation vector.
- Whether to accept `v` in the 0/1 form or only 27/28. The tests sign with
  Foundry (27/28). Either is defensible if stated.
- Whether to check the `s` upper range. Replay is prevented by the nonce and
  the EntryPoint, so malleability does not create a second valid operation;
  the user should be able to say why.
- Whether `executeBatch` wraps a single failing call differently from
  `execute` (index 0 in both is the simplest).

## Follow-up questions

- Alice delegates to implementation A, sends ten operations, then delegates
  to implementation B with a different `execute` signature. Which of her
  pending, already-signed operations are still valid, and what does the
  `0x7702` marker change about that answer?
- A paymaster sponsors alice's operations. What in this account decides
  whether the paymaster or alice pays, and what should alice sign so that she
  cannot be charged if the paymaster backs out?
- The EntryPoint is upgraded to v0.9 at a new address. Alice's implementation
  has v0.8 as an immutable. What must happen for alice to use the new
  EntryPoint, who signs it, and what does it cost her compared with a
  storage-based EntryPoint address?
- Someone sends a plain transaction to alice's address calling
  `validateUserOp` with a huge `missingAccountFunds`. Why does your access
  check matter more here than in a factory-deployed account?
- Alice's dapp wants her to approve a token and swap in one operation. Write
  the `callData` she signs, and explain where the atomicity comes from and
  where it does not (think of the swap reverting).
