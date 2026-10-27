# Reviewer notes: eoa-delegation

> Spoilers. Read after your attempt.

## Test coverage notes

- **An `initialize(owner)` or constructor-set owner is used instead of the
  self-call check.** Caught indirectly: `test_SelfCallSetsOperator` and
  `test_SelfCallExecutesAndTargetSeesTheEoaAsSender` call with
  `vm.prank(alice)` and no initialization step, so a stored owner is zero and
  the calls revert. An implementation that lets a zero owner through would
  pass `test_StrangerCannotExecute` only if it also happened to reject
  strangers; look at how the owner is established.
- **`immutable` owner or EntryPoint-style address set in the constructor.**
  Not caught for the owner (the constructor runs for the standalone deployment
  only, so the immutable would be whatever the deployer passed, and the tests
  would fail on `NotAuthorized`); the general point is that immutables live in
  the implementation's code and are therefore the same for every delegating
  EOA. Ask whether the user understands why an immutable cannot be "the
  owner" here.
- **`execute` authorizes `tx.origin == address(this)` instead of
  `msg.sender == address(this)`.** Caught by
  `test_OriginCheckFailsWhenAnOperatorDrivesTheEoa` only indirectly (operator
  path still works). Not caught directly: a stranger's contract called by
  alice in some unrelated transaction could re-enter `execute` with
  `tx.origin == alice`. Look for `tx.origin` in the starter.
- **Operators can add operators (authorization check uses "self or
  operator" for `setOperator`).** Caught by `test_OperatorCannotAddOperators`
  (`NotSelf` expected).
- **Batch does not revert on a failed call, or reverts without the index, or
  continues after a failure.** Caught by
  `test_FailingCallRevertsTheWholeBatchWithIndexAndReason` (expects
  `CallFailed(1, Error("boom"))` and the recorder empty).
- **`msg.value` is forwarded to each call instead of `calls[i].value`, or
  value is taken from the operator.** Caught by `test_OperatorCanExecute`
  (alice's balance drops, not bob's) and
  `testFuzz_BatchRunsEveryCallInOrderWithItsValue` (alice's balance ends at
  zero after the sum of per-call values).
- **The standalone implementation is usable (for example `execute` is open
  when no operator was ever set).** Caught by
  `test_ImplementationDeployedStandaloneCannotBeUsed`.
- **Storage is keyed by the implementation (for example a mapping from
  `address(this)` that is really meant to isolate accounts) or cleared on
  re-delegation.** Caught by
  `test_OperatorsPersistAcrossRedelegationToSameImplementation` and
  `test_OperatorsSurviveRevokeAndRedelegate`. Note that the persistence is a
  property of the EVM, not of the implementation; the tests document it so the
  user sees it once.
- **`Executed` is emitted with `address(this)` or the batch length is wrong.**
  Caught by `test_ExecuteEmitsExecutedWithCallerAndCount`.
- **Calls to the account itself from within `execute` (an operator making the
  EOA call its own `setOperator`).** Not decided by the statement:
  `test_OperatorCannotEscalateThroughExecute` accepts either outcome and only
  checks consistency. This is the privilege-escalation question of the task;
  raise it in review if the user allowed it without noticing.
- **Reentrancy: a target re-enters `execute` as the EOA's operator mid-batch.**
  Not caught. The batch is not atomic with respect to reentrant batches; ask
  whether that matters for an operator model.
- **Return-data bombs: `ret` copied into memory from an untrusted target.**
  Not caught. Worth one sentence on bounding the copied revert data.

## Open choices

- Whether `execute` may target `address(this)`. Allowing it lets an operator
  invoke any self-only function (including `setOperator`) with
  `msg.sender == address(this)`, which collapses the two privilege levels.
  Forbidding it costs a comparison per call. Either is acceptable if the user
  can state the consequence.
- Whether `execute` is `payable` and what to do with `msg.value`: it simply
  adds to the EOA's balance; the per-call values are independent of it.
- Whether to bound the revert data copied into `CallFailed`.
- Whether `Executed` carries the caller or the number of calls only; the
  statement asks for both so an indexer can tell operator activity from
  self-activity.

## Follow-up questions

- A dapp checks `msg.sender == tx.origin` to keep contracts out. After
  EIP-7702, alice's self-sent transaction passes that check even though her
  code is running and could, for example, re-enter the dapp in the same call.
  What should the dapp check instead, and is there a check that still works?
- The same dapp checks `msg.sender.code.length == 0`. Alice can no longer use
  it at all while delegated, not even with a plain transaction from her key.
  Who is at fault, and what would you tell each side?
- Alice wants to switch to a new implementation with a different storage
  layout. Her operators are in slot 0 of the old layout. What can the new
  implementation do about data it did not write, and why is
  "clear everything on delegation" not an option?
- An operator is compromised. Revocation of the delegation stops the operator,
  but so does `setOperator(op, false)`. Which would you choose under time
  pressure, and what does each one do to the EOA's other operators and
  pending transactions?
- Relayers submit the delegation and the first batch in one transaction with
  an authorization list. What can go wrong if the relayer reorders them, and
  what in this design makes that harmless?
