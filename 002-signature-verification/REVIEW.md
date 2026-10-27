# Reviewer notes: signature-verification

> Spoilers. Read after your attempt.

## Test coverage notes

- **No upper-half `s` check, or the check uses `>=` instead of `>`.** Caught by
  `test_MalleatedSignatureRecoversSameSignerRawButIsRejected` and
  `testFuzz_MalleatedTwinIsRejected` (the twin recovers instead of reverting),
  and by `test_AcceptsSExactlyAtHalfOrder` (the boundary value is rejected).
- **The `s` check is applied only to the 65-byte path and not to the compact
  path, for example because "compact `s` is always below 2^255".** Caught by
  `test_RejectsUpperHalfSInCompactForm`: `n/2 + 1` fits in 255 bits.
- **The parity bit is read with the wrong shift or the mask leaves the top bit
  in `s`.** Caught by `test_CompactAndFullFormsAgreeForBothParities` (one of
  the parities recovers a different address or reverts).
- **`v` is not normalized (0/1 rejected).** Caught by `test_AcceptsVZeroAndOne`.
  Normalizing with `if (v < 27) v += 27` instead of an explicit `0 || 1` check
  passes every test and is correct: 2..26 become 29..53, which `ecrecover`
  rejects, and no `uint8` wrap is possible below 27. Ask which form the user
  finds easier to defend in review.
- **`ecrecover` returning `address(0)` is returned as the signer.** Caught by
  `test_RejectsZeroAddressRecovery`, and in `isValid` by the
  `expected = address(0)` case of `test_IsValidReturnsFalseInsteadOfReverting`.
- **Length is not checked and the bytes beyond 65 are ignored, or a 64-byte
  input is parsed as a truncated 65-byte one.** Caught by
  `test_RejectsWrongLength` and `testFuzz_WrongLengthIsRejected`.
- **`isValid` is implemented with `try this.recover(...)`.** Does not compile
  as `pure` (`this` reads the environment); if the user relaxes `isValid` to
  `view` the starter no longer matches the API and the tests fail to compile.
  Look for the shared non-reverting internal path in review.
- **The EIP-191 prefix is built with `abi.encode` instead of packed
  encoding.** Caught by `test_EthSignedMessageHashOfBytes32IsPackedPrefix`.
- **The length is written in hex, padded to a fixed width, or written as
  `uint256` bytes.** Caught by `test_EthSignedMessageHashUsesDecimalLength`
  and `test_EthSignedMessageHashOfBytesMatchesKnownVector`.
- **The decimal conversion mishandles zero or multi-digit lengths (reversed
  digits, off-by-one buffer).** Caught by `test_EthSignedMessageHashUsesDecimalLength`
  (lengths 0, 9, 10, 99, 100, 1000, 1023) and `testFuzz_EthSignedMessageHashMatchesReference`.
- **`s` above the curve order (not just above `n/2`) is passed to
  `ecrecover`.** Caught by `test_RejectsSAboveCurveOrder` only because the
  half-order check also covers it; an implementation that checks `s < n`
  separately is not wrong, just redundant.
- **Signature parsing with `abi.decode(signature, (bytes32, bytes32, uint8))`
  on the 65-byte input.** Caught by every 65-byte test: `abi.decode` expects
  `v` padded to a word, so it reverts on 65 bytes.
- **`r == 0` or `s == 0` is accepted before calling `ecrecover`.** Not caught
  directly (the precompile returns zero for those and the zero-address check
  then fires); worth asking whether an explicit early check is clearer or just
  more code.

## Open choices

- Whether the split-signature `recover` is the single implementation that the
  bytes variant delegates to, or the other way around. Either is fine; the
  checks must not be duplicated with subtle differences.
- How `v` normalization is expressed: `if (v < 27) v += 27` versus an explicit
  `v == 0 || v == 1`. The first accepts `v = 2..26` as `29..53`, which
  `ecrecover` then rejects; the second is stricter and easier to read.
- Whether the half-order constant is written as a hex literal or derived from
  `n`. A literal is what production code does; it must be the exact value.
- Whether `isValid` returns `false` or reverts when `expected` is the zero
  address. The README fixes it to `false`; the mechanism (reject zero signer,
  compare afterwards) is the user's.
- Calldata slicing, `abi.decode` of a padded copy, or assembly for parsing.
  Any is fine if the length check comes first.

## Follow-up questions

- The verifier is used by a contract that stores "this signature was used"
  by hashing the signature bytes. What does malleability do to that
  deduplication, and is the half-order check enough?
- A wallet signs with `eth_sign` and another with `personal_sign`. Which
  prefix does each apply, and what does your `recover` need to know about it?
- A contract needs to verify signatures over a message that is already a
  hash versus one that is raw bytes. Why does EIP-191 distinguish them, and
  what would an attacker do if `toEthSignedMessageHash(bytes)` were used with
  a message that is exactly 32 bytes long by one caller and `bytes32` by
  another?
- Should `recover` accept the compact form at all when the rest of the
  system only produces 65-byte signatures? What is the cost of accepting two
  encodings in a system that deduplicates by signature bytes?
- EIP-7212 / RIP-7212 adds a P-256 precompile. Which of the checks in this
  task carry over to that curve, and which do not?
