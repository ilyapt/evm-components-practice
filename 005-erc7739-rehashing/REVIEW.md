# Reviewer notes: erc7739-rehashing

> Spoilers. Read after your attempt.

## Test coverage notes

- **The naive EIP-1271: the owner's signature is checked over `hash`
  directly.** Caught by `test_RawSignatureOverApplicationDigestIsRejected`,
  `test_PersonalSignRejectsRawSignatureOverHash` and both
  `*ForAccountAIsRejectedByAccountB` tests (the same signature verifies on
  two accounts).
- **The account's domain separator is used as the outer `\x19\x01` separator
  in `TypedDataSign`, or the app's separator is used in `PersonalSign`.**
  Caught by `test_TypedDataSignImplicitModeAcceptsOwner` /
  `test_PersonalSignAcceptsOwner` (the hand-built digest in the test does not
  match, result `0xffffffff`).
- **`salt` is omitted from the `TypedDataSign` struct because the account's
  domain has no salt, or the fields are hashed in another order, or
  `name`/`version` are included unhashed.** Caught by every `TypedDataSign`
  happy-path test and `testFuzz_TypedDataSignRoundTrip`.
- **The type string has a space after the comma, a missing `)` before
  `contentsType`, or `contentsName` is not followed by ` contents,`.** Caught
  by the same tests: the typehash differs.
- **Explicit mode is not supported, or the name is taken before the first
  `(` even when the description does not end with `)`.** Caught by
  `test_TypedDataSignExplicitModeAcceptsOwner` (name would be `Asset`, type
  would include the trailing `Listing`).
- **The suffix is parsed from the front (first 65 bytes are the signature,
  the domain separator starts at byte 65).** Not caught: for an account whose
  own signatures are always 65 bytes this is equivalent once the total length
  is checked. Ask why the ERC fixes the layout from the end (the inner
  signature can have any length, for example a passkey or a multisig).
- **The length arithmetic is done in `uint16` (`64 + uint16(len) + 2`
  overflows) or the slice bounds are not checked before slicing.** Caught by
  `test_LengthFieldPointingPastStartIsRejectedWithoutRevert`,
  `testFuzz_TruncatedSignatureIsRejectedWithoutRevert` and
  `testFuzz_GarbageNeverReverts` (the call reverts with a panic instead of
  returning `0xffffffff`).
- **A suffix whose reconstructed hash does not match is treated as an error
  instead of falling through to `PersonalSign`.** Not distinguishable by the
  current tests (both paths return `0xffffffff` because the fallback also
  fails); ask the user which workflow runs in that case and why the ERC
  makes it a MUST.
- **A suffix that reconstructs `hash` but has an invalid `contentsName`
  falls through to `PersonalSign` instead of failing.** Not caught (the
  fallback fails too). Look for it: once the suffix matches, the
  `TypedDataSign` workflow is mandatory and its failure is final.
- **`contentsName` sanitization missing or incomplete (lowercase start,
  space, comma, `)`, NUL, empty).** Caught by
  `test_ForbiddenContentsNamesAreRejected` and
  `test_EmptyContentsDescriptionIsRejected`: the owner signed the digest the
  naive parse would produce, so only the rule rejects it.
- **The `s` upper-half check or the `v` check is missing.** Caught by
  `test_MalleableSignatureIsRejected` and
  `test_SignatureWithInvalidVIsRejected`.
- **`ecrecover` returning `address(0)` compared against an `address(0)`
  owner.** Caught by `test_ZeroOwnerNeverMatches`. A constructor that
  rejects a zero owner is also fine; the test only needs a `0xffffffff`.
- **The detection sentinel is answered for any empty signature, or for the
  sentinel hash with a non-empty signature.** Caught by
  `test_DetectionNeedsExactHashAndEmptySignature`.
- **`eip712Domain()` returns `fields = 0x1f` (salt bit set) or caches the
  chain id.** Caught by `test_Eip712DomainReportsNameVersionChainAndContract`
  and `test_Eip712DomainFollowsLiveChainId`.
- **The `PersonalSign` struct hashes `hash` again (`keccak256(abi.encode(hash))`)
  or wraps it in the EIP-191 prefix a second time.** Caught by
  `test_PersonalSignAcceptsOwner`: `prefixed` is of type `bytes`, so its
  EIP-712 encoding is the keccak256 of the prefixed message, which is `hash`.
- **Gas: `contentsName` validation and the type string are built with
  repeated `abi.encodePacked` or copied to memory several times.** Not
  caught; the tests do not measure gas. Worth asking what an unbounded
  `contentsDescr` costs and whether the account should cap `len`.
- **The "conditional skipping" clause of the ERC (accept raw signatures
  off-chain or when `hash` already binds the account).** Not implemented by
  requirement, so not tested. Ask how the account could tell that a `hash`
  already includes its address, and why the answer is "it cannot".

## Open choices

- Whether the owner is `immutable` or storage. Both pass; the follow-up is
  what an owner rotation would do to in-flight signatures.
- Whether the suffix is parsed with calldata slices, assembly, or a memory
  copy. Slices keep the bounds checks visible; assembly must reproduce them
  by hand.
- Whether `contentsName` validation also rejects `(` inside the name in
  explicit mode. The ERC only forbids it as the first byte; rejecting it
  everywhere is stricter and harmless.
- Whether to cap `contentsDescr` length (gas griefing on-chain). The ERC
  does not; the `uint16` already bounds it at 65535 bytes.
- How `isValidSignature` is structured: one function with early returns, or
  a `(digest, innerSignature)` resolver followed by one ECDSA check. The
  second makes the "which workflow" decision visible in one place.

## Follow-up questions

- The owner becomes a smart account that itself implements ERC-7739. What
  breaks, and why does the ERC say two such signers cannot be chained?
- A wallet shows the user the `TypedDataSign` request. Which fields does the
  user see, and what would they see if the account's domain fields were
  nested as an `EIP712Domain` struct instead of flattened?
- Permit2 passes the same `hash` to every account. Explain in one sentence
  why the signature for account A is useless on account B even though the
  `hash` is identical.
- An application calls `isValidSignature` off-chain with `eth_call` and
  then on-chain in the same flow. The ERC allows skipping the rehashing
  off-chain. Should the account do it, and how would the application know
  which signature format to request?
- The account later adds a session-key validator that also answers
  `isValidSignature`. Where does the `TypedDataSign` logic live so that
  every validator gets the replay protection?
