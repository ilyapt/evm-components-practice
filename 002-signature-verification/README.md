# Signature verification

**Difficulty:** easy · **Topics:** ecrecover, malleability, EIP-2098, EIP-191

`ecrecover` is the only signature primitive the EVM gives you, and it is a
trap: it returns `address(0)` instead of failing, it accepts two different
`s` values for the same message, it wants `v` in a form wallets do not always
produce, and it knows nothing about the 64-byte compact form or the
`personal_sign` prefix. Every contract that checks a signature (permits,
meta-transactions, account validation, session keys) wraps it in the same few
lines; getting those lines wrong once means a signature that validates twice,
or for nobody, or for everybody.

Implement `SignatureVerifier` in `starter.sol`.

```solidity
contract SignatureVerifier {
    error InvalidSignature();

    function recover(bytes32 digest, bytes calldata signature) public pure returns (address);
    function recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) public pure returns (address);
    function isValid(bytes32 digest, bytes calldata signature, address expected)
        external pure returns (bool);
    function toEthSignedMessageHash(bytes32 hash) public pure returns (bytes32);
    function toEthSignedMessageHash(bytes calldata message) public pure returns (bytes32);
}
```

## Requirements

- `recover(digest, signature)` accepts two encodings:
  - 65 bytes `r ‖ s ‖ v`, where `v` is 27 or 28, or 0 or 1 (normalized by
    adding 27);
  - 64 bytes EIP-2098 compact form `r ‖ yParityAndS`, where the top bit of the
    second word is the parity (`v = 27 + yParity`) and the remaining 255 bits
    are `s`.

  Any other length reverts with `InvalidSignature`.
- `recover(digest, v, r, s)` applies the same rules to an already split
  signature, including the `v` normalization.
- Both `recover` functions revert with `InvalidSignature` when
  - `s` is in the upper half of the curve order, that is
    `s > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`
    (`s` equal to that bound is accepted);
  - `v` after normalization is not 27 or 28;
  - `ecrecover` returns `address(0)`.
- `isValid(digest, signature, expected)` never reverts. It returns `true` only
  if `recover(digest, signature)` would succeed and return `expected`; it
  returns `false` on every failure and on a mismatch. `expected = address(0)`
  is never valid.
- `toEthSignedMessageHash(bytes32 hash)` is the EIP-191 version `0x45` digest
  `keccak256("\x19Ethereum Signed Message:\n32" ‖ hash)`.
- `toEthSignedMessageHash(bytes message)` is
  `keccak256("\x19Ethereum Signed Message:\n" ‖ len ‖ message)` where `len` is
  the decimal ASCII length of `message` with no padding and no leading zeros
  (`"0"`, `"9"`, `"10"`, `"1000"`). For a 32-byte message it equals the
  `bytes32` variant.
- Known vector: `toEthSignedMessageHash(bytes("hello world"))` is
  `0xd9eba16ed0ecae432b71fe008c98cc872bb4cc214d3220a36f365326cf807d68`.

No external libraries in `starter.sol`: the point is to write the checks
yourself and know why each one is there.

## Validation

The tests build a malleated twin of a real signature (`s' = n − s`, `v`
flipped) and show that raw `ecrecover` recovers the same signer from it while
your `recover` rejects it. They present the same signature in 65-byte, split,
and compact form and expect the same address. Lengths 0, 1, 63, 64, 65, 66
and larger, `v` in `{0, 1, 2, 26, 27, 28, 29, 30, 255}`, `s` at the half-order
boundary, above it, and above the curve order are all exercised, and the
`isValid` tests fail if it reverts for any of them.

## Before coding

1. Two different `(v, s)` pairs recover the same address for the same digest.
   Why is that true for secp256k1, and which system is harmed when a contract
   accepts both?
2. Wallets produce `v` as 27/28, as 0/1, and as a single parity bit inside
   `yParityAndS`. Where in your code does each form become the value
   `ecrecover` wants, and how many places must agree on it?
3. `recover` must revert and `isValid` must not. You cannot `try` a call to
   your own `pure` function. How do you share one set of checks between them?
4. Why does the EIP-191 prefix include the message length, and what does the
   fixed `"32"` of the `bytes32` variant protect a signer from?
