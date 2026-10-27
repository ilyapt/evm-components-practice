# Reviewer notes: replay-protection

> Spoilers. Read after your attempt.

## Test coverage notes

- **The nonce is incremented after the external call.** Caught by
  `test_ReentrantTargetCannotReExecuteTheSameIntent`: the nested `execute`
  succeeds, `entries` becomes 2, and value is sent twice.
- **The nonce is incremented after the call but the implementation also has
  a reentrancy guard.** Not caught: the nested call fails with the guard's
  error instead of `InvalidNonce`, so `innerError` differs and the test
  fails on the error comparison. Explain that the test asks for effects
  before interactions, not for a guard; a guard on top is fine but not a
  substitute.
- **`nonces(signer)` is checked but never written, or written to a map keyed
  by `msg.sender` (the relayer).** Caught by `test_ReplayOfExecutedIntentFails`
  and `test_ExecutesSignedIntentOnceAndReturnsData` (relayer nonce must stay 0).
- **The nonce check is `intent.nonce >= nonces(signer)` or nonces are a
  "used" bitmap rather than sequential.** Caught by
  `test_IntentsExecuteInNonceOrder` (nonce 1 before 0 must fail).
- **The deadline check is `>=`.** Caught by `test_DeadlineIsInclusive`.
- **The domain separator is cached at construction.** Caught by
  `test_DomainSeparatorFollowsChainId` and `test_RejectsSignatureForOtherChain`.
- **`verifyingContract` missing from the domain.** Caught by
  `test_DomainSeparatorMatchesVector` and `test_RejectsSignatureForOtherDeployment`.
- **`data` is ABI-encoded inline instead of hashed, or the type string has
  the fields in a different order or with spaces.** Caught by
  `test_HashIntentMatchesVector`, `test_DataIsHashedNotInlined`, and
  `testFuzz_HashIntentMatchesReference`.
- **`signer` is trusted when it is `address(0)` and `ecrecover` returns zero
  for a garbage signature.** Caught by `test_ZeroSignerIsNeverValid`.
- **The recovered address is compared against `msg.sender` instead of
  `signer`, or `signer` is ignored and the recovered address is used as the
  nonce key.** Caught by `test_RejectsSignatureByAnotherKeyForClaimedSigner`
  (Bob's signature executes under Alice's nonce) and by the nonce checks in
  `test_NoncesAreTrackedPerSigner`.
- **A failed call is swallowed (`if (!ok) return returnData;`) or reverted
  with a fixed message instead of `CallFailed(returnData)`.** Caught by
  `test_FailedCallBubblesReturnDataAndKeepsNonce` (both `Error(string)` and a
  custom error must round-trip) and `test_InsufficientBalanceFailsWithoutConsumingNonce`
  (empty return data).
- **The call forwards `msg.value` instead of `intent.value`, or requires
  `msg.value == intent.value`.** Caught by `test_ForwardsValueFromContractBalance`
  (balance funded through `vm.deal`, `msg.value` is 0) and
  `test_RelayerCanFundValueWithMsgValue`.
- **`Executed` emitted before the call, or with the relayer as `signer`.**
  Caught by `vm.expectEmit` in `test_ExecutesSignedIntentOnceAndReturnsData`
  only for the argument values; the ordering (event before a failing call)
  is not observable because the whole transaction reverts. Not an issue.
- **`cancel` bumps the nonce unconditionally, or checks `nonce` against the
  wrong account.** Caught by `test_CancelRejectsStaleOrFutureNonce` and
  `test_CancelOnlyAffectsTheCaller`.
- **Missing `s` upper-range check.** Not caught here by design (task 002).
  Mention it only if the user claims the executor is production-ready.
- **The call is made with a gas limit or with `transfer`-style 2300 gas.**
  Not caught directly; the tests' targets are cheap. Ask what a bounded gas
  stipend would do to a legitimate target and who chooses it.
- **Return-data bombs: the target returns megabytes and the executor copies
  all of it into memory.** Not caught; look for it in review and ask who
  pays for the copy (the relayer) and whether the executor should cap it.
- **The relayer address or `msg.value` is not part of what the signer
  commits to.** Not caught and not required: by design any relayer may submit.
  Ask what changes if the signer wants to pay a specific relayer.

## Open choices

- The order of the `Expired`, `InvalidNonce`, and `InvalidSignature` checks.
  The tests trigger one failure at a time, so any order passes; cheap checks
  first is the usual argument.
- Where the nonce mapping lives and how it is written: `nonces[signer]++`
  versus `= intent.nonce + 1`. Both are correct given the equality check.
- Whether the signature is split with calldata slices, assembly, or a copy.
- Whether `Executed` is emitted before or after the call. Not observable.
- Whether `receive` should exist at all. The README fixes it; ask what a
  stray transfer into the executor means for the signer.
- Whether `execute` returns the raw return data or decodes nothing. The
  README fixes the former.

## Follow-up questions

- The protocol wants parallel intents from the same signer (two
  independent actions, either order). What replaces the sequential nonce,
  and what does cancellation look like then?
- The executor is deployed behind an upgradeable proxy. Which signatures
  survive an upgrade, and should they?
- A relayer front-runs another relayer with the same signed intent. Who
  wins, who pays, and does the signer care?
- The signer wants to pay the relayer for gas. Which fields must be added to
  `Intent`, and how does the signer protect themselves from a relayer who
  inflates the gas price?
- The target is the executor itself (`intent.target == address(this)`).
  Which functions become reachable with the executor as `msg.sender`, and
  what should `execute` do about it?
