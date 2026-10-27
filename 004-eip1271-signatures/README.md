# EIP-1271 signatures

**Difficulty:** easy · **Topics:** EIP-1271, contract signers, staticcall, return-data validation

A smart-contract wallet has no private key, so it cannot produce an ECDSA
signature; instead EIP-1271 lets the contract itself answer "is this
signature valid for this hash?". Any protocol that accepts signatures
(permits, orders, session keys, off-chain authorizations) needs one checker
that works for both kinds of signer and cannot be tricked by a signer
contract that reverts, returns garbage, or returns the right bytes in the
wrong shape. The companion piece is the signer side: a minimal contract that
delegates to its owner's key and answers without ever reverting.

Builds on tasks 001 and 002.

Implement `SignatureChecker` and `OwnedSigner` in `starter.sol`.

```solidity
interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external view returns (bytes4);
}

contract SignatureChecker {
    function isValidSignatureNow(address signer, bytes32 hash, bytes calldata signature)
        external view returns (bool);
}

contract OwnedSigner is IERC1271 {
    constructor(address owner_);
    function owner() external view returns (address);
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external view returns (bytes4);
}
```

## Requirements

`SignatureChecker.isValidSignatureNow(signer, hash, signature)`:

- If `signer` has no code, use the ECDSA path: `signature` must be 65 bytes
  `r ‖ s ‖ v` with `v` in {27, 28} and `s` not in the upper half of the curve
  order (`s ≤ 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`);
  the result is `true` iff `ecrecover` returns a non-zero address equal to
  `signer`. `signer = address(0)` is never valid.
- If `signer` has code, use the EIP-1271 path: `staticcall`
  `isValidSignature(hash, signature)` on `signer` and return `true` only if
  the call succeeded, the return data is at least 32 bytes long, and its
  first 32-byte word is `0x1626ba7e` left-aligned (that is, `bytes4` ABI
  encoding: `0x1626ba7e` followed by 28 zero bytes).
- The decision between the two paths depends only on `signer.code.length`.
  A contract address never takes the ECDSA path, even if the signature would
  recover to that address.
- The function never reverts because of the signer's behaviour. A signer
  that reverts, returns nothing, returns fewer than 32 bytes (including
  exactly the 4 magic bytes), returns a full word with a different value, or
  has no `isValidSignature` function at all yields `false`. A signer that
  returns the magic value followed by more bytes (for example 64 bytes in
  total) is accepted.
- Because the call is a `staticcall`, a signer that modifies state during
  validation fails the call and yields `false`.

`OwnedSigner`:

- Stores the owner given at construction and exposes it through `owner()`.
- `isValidSignature(hash, signature)` returns `0x1626ba7e` iff `signature`
  is a valid ECDSA signature by `owner()` over `hash` under the same rules as
  the ECDSA path above (65 bytes, `v` in {27, 28}, low `s`, non-zero
  recovery). Otherwise it returns `0xffffffff`. It never reverts, whatever
  the length or content of `signature`.

No external libraries in `starter.sol`. The two contracts may share an
internal helper.

## Validation

The tests cover: EOA happy path and mismatch, malformed length, malleated
`s`, bad `v`, zero address; the contract path through `OwnedSigner`; mock
signers that revert, return nothing, return a wrong word, return the magic
right-aligned, return it padded to 64 bytes (accepted), return only 4 bytes
(rejected), write state, or have no `isValidSignature`; an EOA that later
gets code (`vm.etch`) and must switch to the contract path; and fuzzing over
keys and hashes on both paths.

## Before coding

1. What decides which path is taken, and what goes wrong if the decision is
   made from the signature (for example "if it recovers to `signer`, accept")
   rather than from the address?
2. Write the exact return data of a correct `isValidSignature` call: how many
   bytes, and at which offset is `0x1626ba7e`? Which of `abi.decode(ret, (bytes4))`,
   `bytes4(ret)`, and `bytes32(ret) == bytes32(magic)` is right on a 64-byte
   payload, and which on a 4-byte one?
3. Why `staticcall` rather than `call`? Name one thing a malicious signer
   could do inside `isValidSignature` if it were a `call`.
4. Which failures of the signer contract are converted to `false`, and is
   there any failure that should propagate as a revert instead?
