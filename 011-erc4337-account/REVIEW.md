# Reviewer notes: erc4337-account

> Spoilers. Read after your attempt.

## Test coverage notes

- **`validateUserOp` has no caller check, or checks the owner instead of the
  EntryPoint.** Caught by `test_ValidateUserOpFromStrangerReverts` (expects
  `NotEntryPoint` from a stranger and from the owner).
- **The owner signs a `"\x19Ethereum Signed Message:\n32"`-prefixed digest.**
  Caught by `test_PersonalSignPrefixedSignatureIsRejected` (a prefixed
  signature must fail) and by every happy-path test (a direct signature must
  pass).
- **A bad signature reverts instead of returning `1`** (for example a
  `require(signer == owner)`). Caught by `test_WrongSignerIsRejectedWithAA24`:
  the EntryPoint reports `FailedOpWithRevert(0, "AA23 reverted", …)` instead
  of `FailedOp(0, "AA24 signature error")`.
- **The signature is split with `abi.decode` or calldata slices without a
  length check, so a 0-, 64- or 66-byte signature reverts.** Caught by
  `test_MalformedSignatureIsAA24NotAA23` (AA23 instead of AA24).
- **`ecrecover` returning `address(0)` is compared against the owner without
  care.** Only dangerous if the owner could be `address(0)`; the test with
  `v = 29` in `test_MalformedSignatureIsAA24NotAA23` still expects `1`, which
  any comparison against a real owner satisfies. Not caught for an account
  constructed with a zero owner; look for a constructor check.
- **The prefund is not paid, or paid from the deposit (`withdrawTo`) instead
  of the balance, or paid with the wrong amount (the whole prefund instead
  of `missingAccountFunds`).** Caught by
  `test_PrefundIsPaidFromAccountBalanceWhenDepositIsEmpty` and
  `test_OnlyTheMissingPartOfThePrefundIsPaid` (exact balance deltas), and by
  `test_ExistingDepositCoversPrefundWithoutTouchingBalance` (balance must not
  move when the deposit suffices).
- **The prefund transfer's result is checked and a failure reverts.** Caught
  by `test_PrefundTransferFailureDoesNotRevertValidation` (validation must
  return normally when the recipient refuses ETH) and by
  `test_AccountWithoutFundsFailsWithAA21NotAA23` (the EntryPoint must be the
  one that diagnoses the missing prefund).
- **The prefund is paid with `transfer`/`send` (2300 gas) instead of
  `call`.** The EntryPoint's `receive()` calls `depositTo`, which writes
  storage and emits an event: 2300 gas is not enough. Caught by the prefund
  tests (AA21).
- **The account keeps its own nonce and checks or increments it.** Not caught
  directly: the tests use the EntryPoint's sequential nonce and the account's
  extra check would agree with it. Look for it in review; ask what happens
  with 2D nonce keys (task 012) and with gas estimation.
- **`execute`/`executeBatch` are callable by anyone.** Caught by
  `test_ExecuteByStrangerReverts`.
- **`execute` swallows a failed call (unchecked `call` result).** Caught by
  `test_ExecuteBubblesRevertDataWithIndexZero` and
  `test_RevertingCallDataDoesNotRevertHandleOpsAndLeavesStateUnchanged` (the
  `UserOperationEvent.success` flag must be `false`).
- **`executeBatch` continues after a failure, or reports index 0 for every
  failure, or does not include the callee's revert data.** Caught by
  `test_ExecuteBatchBubblesTheFailingIndexAndIsAtomic` (exact
  `CallFailed(1, Boom(99))` encoding, counter must be rolled back).
- **`executeBatch` reuses `msg.value` or ignores `calls[i].value`.** Caught by
  `test_ExecuteBatchRunsInOrder` (0.25 ether must arrive with the second
  call).
- **`withdrawDepositTo` is open or only checks the EntryPoint.** Caught by
  `test_StrangerCannotWithdrawDeposit` and `test_OwnerCanWithdrawDeposit`.
- **`receive` missing or reverting.** Caught by `test_AccountReceivesEther`.
- **Signature malleability (`s` in the upper half) is accepted.** Not caught
  and harmless here: the EntryPoint nonce prevents replay, and the
  malleated signature authorizes the same operation. Worth a sentence in
  review, not a fix.
- **ERC-7562 violations in `validateUserOp`** (reading `block.timestamp`,
  calling another contract, reading another contract's storage). Not caught:
  Foundry does not run the bundler's simulation rules. Look for them in
  review.
- **The owner or EntryPoint is kept in regular storage and could be
  rewritten through `execute(address(this), …)`.** Not caught (no setter is
  in the API). Look for it: an `immutable` makes the question moot; storage
  makes "who can write it" a question to answer.

## Open choices

- `owner` and `entryPoint` as `immutable` or in storage. Immutable is
  cheaper and cannot be changed; storage opens the door to ownership
  transfer later (and to an unintended write through `execute`).
- Whether `withdrawDepositTo` should also accept the account itself as caller
  (`msg.sender == address(this)`), so a user operation can withdraw the
  deposit through `execute`. The README asks for owner-only; the other
  choice is defensible if the self-call path is argued through.
- How the signature is split: calldata slices, assembly, or a padded copy.
  Any is fine behind a length check that returns `1` instead of reverting.
- Whether `_call` uses all remaining gas or caps it. The EntryPoint already
  bounds the execution with `callGasLimit`, so forwarding everything is the
  common choice.
- Whether `CallFailed` for a single `execute` uses index `0` or the raw
  revert data is bubbled unchanged. The README fixes index `0`; the
  reasoning (uniform decoding for indexers) is worth hearing.

## Follow-up questions

- A bundler estimates gas with a dummy signature. Walk through what your
  `validateUserOp` does with it and what the EntryPoint's simulation reports.
  What breaks if the dummy signature has the wrong length?
- The owner wants to rotate their key. What has to change in the account,
  who may trigger it, and what happens to operations already signed with the
  old key but not yet included?
- The account should accept operations only within a time window signed by
  the owner. Where does the window go in the signed data, and how does it
  reach the EntryPoint through `validationData`?
- The same account should also be usable as an EIP-7702 delegate. Which
  assumptions in your code (constructor, immutables, `address(this)`) stop
  holding, and what replaces them?
- `executeBatch` with 50 calls of which the last fails: what has the account
  paid for, what has the user got, and should a batch ever be allowed to
  continue past a failure?
