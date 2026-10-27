# Reviewer notes: eip712-typed-data

> Spoilers. Read after your attempt.

## Test coverage notes

- **The domain separator is cached in an `immutable` or computed once in the
  constructor.** Caught by `test_DomainSeparatorFollowsChainId` (wrong value
  after `vm.chainId`). An implementation that caches it together with the
  chain id and recomputes on mismatch is fine; ask what it saves.
- **`verifyingContract` or `chainId` missing from the domain, or the domain
  type string lists the fields in a different order.** Caught by
  `test_DomainSeparatorMatchesSpecVector` and
  `test_DomainSeparatorBoundToContract`.
- **The referenced type (`Person`) is not appended to the `Mail` or `Group`
  type string, or is appended for every field that uses it, or the
  `encodeType` has spaces.** Caught by `test_MailDigestMatchesSpecVector` and
  the `testFuzz_Hash*` tests (wrong struct hash).
- **A `string` is encoded as `bytes32(name)` or with `abi.encodePacked`
  padding instead of `keccak256(bytes(name))`.** Caught by
  `test_StringsAreHashedNotPadded` and the fuzz tests.
- **`Person[]` is hashed as the concatenation of raw fields instead of the
  concatenation of struct hashes.** Caught by
  `test_ArrayOfStructsIsNotHashedAsRawFields`.
- **`bytes32[]` is hashed with `abi.encode` (which adds offset and length) or
  the empty array case is special-cased wrongly.** Caught by
  `testFuzz_HashGroupMatchesReference` and
  `test_EmptyArraysAndStringsHashToKeccakOfEmpty`.
- **`digest` uses `abi.encode` instead of packed encoding, or the wrong
  prefix (`\x19Ethereum Signed Message`).** Caught by
  `test_MailDigestMatchesSpecVector`.
- **`recoverMailSigner` returns `address(0)` for a garbage signature.**
  Caught by `test_RecoverRejectsZeroAddress`.
- **The signature length is not checked, and bytes beyond 65 are ignored.**
  Caught by `test_RecoverRejectsWrongLength`.
- **`v` is read as `uint8(signature[64])` without accepting 0/1 forms.** Not
  caught and not required here; task 002 covers signature forms.
- **The `s` upper-range (malleability) check is missing.** Not caught here by
  design; task 002.
- **Gas: `hashGroup` builds the member hashes with repeated `abi.encodePacked`
  concatenation.** Not caught; correct but quadratic. Worth asking what it
  costs for large arrays and what a fixed-size `bytes32[]` buffer changes.

## Open choices

- Whether the type hashes are `constant` expressions or computed from string
  constants at runtime. Both are correct; constants are what production code
  does.
- Whether `hashPerson` is `public` because the API says so or `internal` with
  a public wrapper. The tests call it through the ABI only.
- How `recoverMailSigner` splits the signature: calldata slices, assembly, or
  `abi.decode` of a padded copy. Any is fine if the length check comes first.
- Whether the domain separator is recomputed on every call or cached with the
  chain id. The README requires only that it follows the live chain id.

## Follow-up questions

- A wallet shows the user "Hello, Bob!" but the contract hashed a different
  type string. What does the user see, what does the contract verify, and who
  loses?
- The contract is deployed behind a proxy and later upgraded. Which part of
  the domain changes, and which signatures survive the upgrade?
- `Mail` gains an optional field. How do you version the type without
  breaking old signatures, and should you?
- Why does EIP-712 hash dynamic values instead of including them inline, and
  what would break if it did not?
- The contract must support many struct types. Would you keep one function
  per struct, or a generic encoder, and what does each cost in review effort?
