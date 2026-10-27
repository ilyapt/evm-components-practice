# Reviewer notes: batch-executor

> Spoilers. Read after your attempt.

## Test coverage notes

- **`supportsExecutionMode` compares the whole `bytes32` against the two
  canonical constants.** Caught by `test_ReservedAndPayloadBytesAreIgnored`
  and `testFuzz_SupportsExecutionModeMatchesLayout` (a mode with payload
  bytes set must still be supported).
- **Only byte `[0]` or only the selector bytes `[6..9]` are checked, so the
  ERC-7579 "try" execution type (`[1] = 0x01`) or the single-call type is
  accepted.** Caught by `test_SupportsExactlyTheTwoSingleBatchModes` and the
  fuzz test.
- **The batch-of-batches selector is accepted or decoded.** Caught by
  `test_SupportsExactlyTheTwoSingleBatchModes` and
  `test_ExecuteRevertsOnUnsupportedMode`.
- **`executionData` for the `0x78210001` mode is decoded as `Call[]` only,
  or empty `opData` in that mode is treated as a signed batch.** Caught by
  `test_OwnerCanUseOpDataModeWithEmptyOpData` and
  `test_StrangerCannotExecuteDirectly` (second half: must be `Unauthorized`,
  not `InvalidSignature`).
- **The nonce is incremented after the loop, or checked but never
  incremented, or incremented only on success.** Caught by
  `test_ReenteringTargetCannotReplayTheBatch` (the inner replay executes
  again; the test records whether it succeeded) and
  `test_ReplayedSignatureIsRejected`.
- **The signature is checked before the nonce and the nonce mismatch reverts
  with `InvalidSignature`.** Caught by `test_WrongNonceIsRejected` and
  `testFuzz_SignedBatchWithWrongNonceIsRejected` (the expected error is
  `InvalidNonce`). A nonce-first order also makes the error for a replay
  informative.
- **The call loop uses `require(ok)` or `revert("call failed")`, or
  re-encodes the error.** Caught by `test_CustomErrorIsBubbledUnchanged`,
  `test_StringReasonIsBubbledUnchanged` and
  `test_EmptyRevertIsBubbledAsEmpty` (revert data compared byte for byte).
- **The loop continues after a failed call (try semantics).** Caught by
  `test_FailingCallRollsBackEarlierCalls` and
  `test_FailingSignedBatchDoesNotConsumeNonce`.
- **`address(0)` is not substituted, so value is sent to the zero address or
  the self-path batch calls a non-contract.** Caught by
  `test_ZeroAddressTargetIsTheExecutorItself` and
  `test_SelfCallThroughNestedBatchIsAuthorized`.
- **`address(0)` is substituted before hashing (the digest is computed over
  `address(this)` while the signer hashed `address(0)`).** Caught by
  `test_SignedBatchCanCallTheExecutorItself` (`InvalidSignature`).
- **`msg.value` is forwarded as a whole to each call or required to equal
  the sum of values.** Caught by `test_MsgValueIsForwardedToCalls`,
  `test_MsgValueAndBalanceCombine` and
  `test_ContractBalanceFundsCallsAndReceiveAcceptsEther`.
- **The digest omits `mode`, hashes `calls` with `abi.encode(calls)` instead
  of the EIP-712 array encoding, or hashes `data` inline instead of its
  keccak256.** Caught by `test_RelayerCanSubmitSignedBatch` (hand-built
  digest in the test does not match), `test_ModeIsPartOfTheSignedDigest`
  and `test_SignatureOverDifferentCallsIsRejected`.
- **The domain separator is cached at construction or lacks
  `verifyingContract`.** Caught by `test_SignatureIsBoundToChainId` and
  `test_SignatureIsBoundToExecutor`.
- **`opData` is sliced without a length check (reverts with an index panic or
  reads garbage), or a 64-byte signature is accepted.** Caught by
  `test_MalformedOpDataIsRejected` (expects `InvalidSignature`).
- **Malleability (`s` upper half) or `v` in {0, 1} accepted.** Caught by
  `test_MalleableSignatureIsRejected`.
- **`ecrecover` returning `address(0)` compared against the owner without a
  zero check.** Not caught directly (the owner is never zero in the tests);
  look for it. A constructor that rejects a zero owner closes it too.
- **The `BatchExecuted` event is emitted before the calls, or with the
  post-increment nonce, or not for an empty batch.** Caught by
  `test_RelayerCanSubmitSignedBatch`, `test_EmptyBatchSucceedsAndEmits` and
  `test_DirectExecutionEmitsSentinelNonceAndCallCount`.
- **`execute` declares a return value.** Caught by `test_ExecuteReturnsNoData`
  (the raw call must return zero bytes).
- **Gas: all gas is forwarded to every call (`to.call{value: v}(data)`), so a
  malicious target can grief the batch; or unbounded `calls` arrays.** Not
  caught; that is the ERC's own behaviour, but ask what a per-call gas limit
  in `Call` would change and who would set it.
- **Return-data bombs: a target returns megabytes and the executor copies
  them into memory.** Not caught. Worth asking whether the successful
  return data is needed at all (it is not) and how to avoid copying it.
- **Reentrancy through the owner path: a target calls `execute` as
  `address(this)` with its own calls.** Not caught and by design allowed:
  the self path is how nested batches work, and a target can only reach it
  if the batch already called the target. Ask whether that is a problem when
  the owner signs a batch that calls an untrusted contract.

## Open choices

- The nonce value emitted for direct executions (`type(uint256).max` is the
  README's choice); an alternative is a separate event. Either is fine if
  indexers can tell the two apart.
- Whether `supportsExecutionMode` is `view` (as in the ERC interface) or
  `pure`. The ABI is identical.
- Whether `opData` is read with calldata slices on a re-decoded calldata
  offset, with assembly on the memory copy, or with `abi.decode` of a padded
  copy. Any is fine with the length check first.
- Whether the order is nonce-check, increment, signature-check, or
  signature-check first. The README fixes the error for a wrong nonce as
  `InvalidNonce` and requires the increment before the calls; both orders
  satisfy that.
- Whether to accept `abi.encode(calls)` without an `opData` word in the
  `0x78210001` mode (the ERC reference implementation sniffs the first
  offset). The README requires the two-argument encoding; supporting both is
  acceptable if documented.
- Whether to also expose an EIP-1271 / ERC-4337 entry point. Out of scope
  here; the ERC allows "authorized entry points" as another caller.

## Follow-up questions

- A relayer submits a signed batch, the first call succeeds and the second
  runs out of gas because the relayer set a low gas limit. What happens to
  the nonce, and could the relayer use that to grief the owner?
- Two signed batches are prepared off-line with nonces 3 and 4. Batch 3 is
  never submitted. What does the owner have to do to get batch 4 executed,
  and what would a 2D nonce (key + sequence, as in ERC-4337) change?
- The executor is the delegate of an EIP-7702 EOA. `address(this)` is now
  the EOA. Which of your authorization paths still makes sense, which one
  becomes redundant, and what does `owner()` mean?
- The wallet wants EIP-5792 `wallet_sendCalls` with `atomicRequired = false`.
  What mode byte would express "continue on failure", and why is that
  harder to make safe than it looks?
- A frontend sets `Call.value` so that the sum exceeds the executor's
  balance plus `msg.value`. Which call fails, with what revert data, and is
  that a good message for the user?
