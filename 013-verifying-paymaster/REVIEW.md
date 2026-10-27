# Reviewer notes: verifying-paymaster

> Spoilers. Read after your attempt.

## Test coverage notes

- **`validatePaymasterUserOp` or `postOp` has no caller check.** Caught by
  `test_ValidatePaymasterUserOpFromStrangerReverts` and
  `test_PostOpFromStrangerReverts` (expect `NotEntryPoint`).
- **A wrong signer reverts instead of returning `sigFailed = 1`.** Caught by
  `test_WrongSignerIsAA34` and every other `*IsBoundTo*` test: the EntryPoint
  reports `FailedOpWithRevert(0, "AA33 reverted", …)` instead of
  `FailedOp(0, "AA34 signature error")`.
- **`ecrecover` returning `address(0)` is compared with `signer()` only.**
  Caught by `test_ZeroAddressSignerNeverValidates` (signer rotated to the
  zero address, garbage signature must still fail). Without that rotation
  the comparison would pass by accident, so the check is easy to forget.
- **The sponsor signs the raw `getHash` instead of its EIP-191 digest (or the
  other way round).** Caught by `test_SignatureOverTheRawHashIsRejected`
  and by the happy-path tests.
- **`getHash` hashes the whole `paymasterAndData`** (so it depends on the
  sponsor signature) **or includes `userOp.signature`.** Caught by
  `test_GetHashIgnoresTheSignatureBytesOfPaymasterAndData`,
  `test_SponsorSignatureIsIndependentOfTheAccountSignature`, and, since the
  sponsor in the tests signs before the user, by every happy-path test.
- **`getHash` leaves out the paymaster gas limits (bytes 20..52).** Caught by
  `test_SignatureIsBoundToPaymasterGasLimits` (the user raises
  `paymasterVerificationGasLimit` after sponsorship) and by
  `testFuzz_GetHashMatchesReferenceEncoding`.
- **`getHash` leaves out `block.chainid` or `address(this)`.** Caught by
  `test_SignatureIsBoundToChainId` (`vm.chainId`, user re-signs) and
  `test_SignatureIsBoundToThePaymasterAddress` (a second paymaster with the
  same signer must not accept the signature).
- **`getHash` leaves out gas fields or the nonce.** Caught by
  `test_SignatureIsBoundToGasParameters` (`accountGasLimits`, `gasFees`,
  `preVerificationGas` tampered one at a time) and
  `test_SignatureIsBoundToNonce` (the sponsor's approval reused for the
  account's next operation).
- **The window is not packed into `validationData`, or `validUntil` and
  `validAfter` are swapped (bits 160 vs 208).** Caught by
  `test_ValidationDataPacksWindowAndSignatureResult` (exact value on a direct
  call as the EntryPoint), `test_ExpiredWindowIsAA32`,
  `test_NotYetDueWindowIsAA32`, `test_WindowBoundaries`, and
  `testFuzz_ValidityWindow`.
- **`validUntil`/`validAfter` are parsed at the wrong offsets (for example
  52..64 read as two `uint256`s, or little-endian).** Caught by the window
  tests and `test_SignatureIsBoundToTheWindow`.
- **The window is enforced in the paymaster with `block.timestamp`.** Not
  caught by Foundry (ERC-7562 opcode rules are a bundler concern), and the
  results would even agree with the EntryPoint's. Look for it in review;
  ask what the bundler's simulation does with that opcode.
- **No length check on `paymasterAndData`.** Caught by
  `test_MalformedPaymasterDataIsAA33WithInvalidPaymasterData`: a 52-, 64-,
  128-, or 130-byte field must produce exactly
  `FailedOpWithRevert(0, "AA33 reverted", InvalidPaymasterData())`. An
  implementation that reverts with a slice-out-of-bounds panic instead fails
  on the inner revert data.
- **`context` is empty or does not carry the hash and the sender.** Caught by
  `test_SponsoredEmitsEventWithUserOpHashAndSender` (the EntryPoint skips
  `postOp` entirely when the context is empty, so no `Sponsored` event) and
  `test_ValidationDataPacksWindowAndSignatureResult`.
- **`postOp` emits only for `opSucceeded`.** Caught by
  `test_RevertingOpIsStillPaidByThePaymasterAndReportedInPostOp`.
- **Stake and withdrawal functions are open, or `deposit()` is owner-only.**
  Caught by `test_StakeLifecycleIsOwnerOnly`, `test_WithdrawToIsOwnerOnly`,
  `test_AnyoneCanDeposit`.
- **`setSigner` is open.** Caught by `test_SetSignerIsOwnerOnly`.
- **Signature malleability (`s` in the upper half) is accepted.** Not caught
  and not exploitable here: a malleated sponsor signature approves the same
  operation, and the account nonce prevents a second execution. Worth a
  sentence in review.
- **The signer is stored in a mapping or array, or validation reads another
  contract's storage.** Not caught; the paymaster's own storage is allowed
  by ERC-7562 only because the paymaster is staked. Ask whether the
  paymaster needs a stake at all for this design, and why bundlers require
  one for paymasters that touch storage.
- **`maxCost` is ignored.** Not a defect for this task (the sponsor signed
  the gas parameters), but worth asking: what does `maxCost` tell you that
  the signed fields do not, and when would a paymaster use it?

## Open choices

- `owner` and `entryPoint` as `immutable` versus storage. A mutable owner
  needs a transfer path; the README does not ask for one.
- Whether the signer can be set to `address(0)` as a way to pause
  sponsorship, and whether `setSigner` should emit an event (an indexer
  that watches sponsorships has no other way to learn about rotation).
- Whether `getHash` is `view` (reads `block.chainid` and `address(this)`)
  or takes those as parameters. The README fixes it as `view`; the tests
  call it through the ABI.
- How the signature is split: calldata slices, assembly, or a padded copy.
- Whether `postOp` does more than emit: a per-sender budget or a counter is
  where production paymasters put their accounting, and `postOp` is where
  the actual cost is known.
- Whether `validatePaymasterUserOp` should return an empty context for
  operations that need no `postOp` (saves gas, loses the event). The README
  requires the event.

## Follow-up questions

- The sponsor signed an operation with `maxFeePerGas = 100 gwei` and the
  base fee is 10 gwei. What does the paymaster actually pay, and who keeps
  the difference between the prefund and the actual cost?
- The signer key leaks. List what the attacker can do, in order of damage,
  and what the owner's first transaction should be.
- Product asks for "sponsor up to 0.01 ETH per user per day". Where does
  that state live, which function updates it, and what does ERC-7562 say
  about reading it during validation?
- The sponsor service wants to approve operations for accounts that do not
  exist yet (counterfactual deployment through `initCode`). What in your
  hash already covers that, and what could still go wrong between signing
  and inclusion?
- A bundler includes the operation 40 minutes after the sponsor signed it,
  with `validUntil` 30 minutes out. Who loses what, and does the sponsor
  signature's expiry protect the sponsor or the user?
- The same paymaster is deployed at the same address on two chains with the
  same signer. Which field of `getHash` keeps a signature from one chain off
  the other, and what if the service signs for both chains with one key?
