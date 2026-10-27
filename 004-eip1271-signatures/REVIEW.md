# Reviewer notes: eip1271-signatures

> Spoilers. Read after your attempt.

## Test coverage notes

- **The path is chosen by trying ECDSA first and falling back to EIP-1271
  only if recovery does not match.** Caught by
  `test_ContractPathIsUsedEvenIfSignatureRecoversToTheAddress`: after
  `vm.etch`, the address has code that rejects everything, yet the signature
  still recovers to it. An implementation that tries ECDSA first returns
  `true`.
- **The path is chosen by `signature.length` (65 means EOA).** Caught by the
  same test and by `test_EcdsaPathIsNotUsedForContracts` (a contract signer
  must be asked even for a 65-byte signature; also `"garbage"` must be
  accepted by a contract that accepts everything).
- **The EIP-1271 call is made through a Solidity interface call
  (`IERC1271(signer).isValidSignature(...) == magic`).** Reverts on a
  reverting signer, on empty or short return data, on a word whose low 28
  bytes are not zero, and on a contract without the function: caught by
  `test_RevertingSignerIsFalse`, `test_EmptyReturnSignerIsFalse`,
  `test_ShortMagicIsRejected`, `test_WrongValueSignerIsFalse`, and
  `test_ContractWithoutIsValidSignatureIsFalse` (the test reverts instead of
  asserting `false`). The interface call does use `staticcall` under the
  hood, so `test_StateWritingSignerIsFalse` also reverts rather than passes.
- **The EIP-1271 call is a low-level `call` instead of `staticcall`.** Does
  not compile while `isValidSignatureNow` is `view`; if the user drops
  `view`, the test file no longer compiles either (its test functions are
  `view`). If it somehow got through, `test_StateWritingSignerIsFalse` would
  catch it. In review, ask why the EIP requires `view` on the signer side.
- **The return data is decoded with `abi.decode(ret, (bytes4))` without a
  length check.** Reverts on empty or 4-byte return data: caught by
  `test_EmptyReturnSignerIsFalse` and `test_ShortMagicIsRejected`.
- **The return data is compared with `bytes4(ret) == magic` after checking
  `ret.length >= 4`.** Accepts the 4-byte return: caught by
  `test_ShortMagicIsRejected`. The EIP says the return is an ABI-encoded
  `bytes4`, which is a full word.
- **The whole return data is compared against `abi.encode(magic)` (exactly
  32 bytes required).** Caught by `test_PaddedMagicIsAccepted`.
- **The magic value is compared right-aligned (`uint256(ret) == 0x1626ba7e`)
  or the constant is written as `bytes32(uint256(0x1626ba7e))`.** Caught by
  `test_WrongValueSignerIsFalse` (right-aligned mock accepted) and by every
  `OwnedSigner` happy path (the real value rejected).
- **`OwnedSigner.isValidSignature` reverts on a wrong length (for example by
  slicing `signature[0:32]` before checking the length, or using
  `abi.decode`).** Caught by `test_OwnedSignerDoesNotRevertOnMalformedLength`.
- **`OwnedSigner` returns `bytes4(0)` or reverts for an invalid signature.**
  Caught by `test_OwnedSignerReturnsFailureValueForOthers` (the README fixes
  the failure value to `0xffffffff`).
- **ECDSA path without the `s` check or without the zero-address check.**
  Caught by `test_EoaRejectsUpperHalfS`, `test_EoaZeroAddressIsNeverASigner`,
  and `test_OwnedSignerWithZeroOwnerAcceptsNothing`.
- **`owner` is stored but `isValidSignature` compares against `msg.sender`
  or `address(this)`.** Caught by `test_OwnedSignerReturnsMagicForOwner`.
- **Return-data bombs: the signer returns megabytes and the checker copies
  everything into memory.** Not caught; look for it in review. Ask whether a
  bounded copy (`returndatacopy` of the first word) is worth the assembly.
- **Gas: the signer burns all forwarded gas and reverts.** Not caught; the
  checker returns `false` but the caller paid. Ask who should cap the gas and
  what a too-low cap does to a legitimate multisig signer.
- **A signer in construction (`code.length == 0` while its constructor
  runs) is treated as an EOA.** Not caught. Mention ERC-6492 in the follow-up.

## Open choices

- Whether the two ECDSA checks are a shared free function, an internal
  library, or duplicated. Duplicated logic with subtly different rules is the
  issue to look for.
- Whether `v` in {0, 1} is normalized. The README requires only 27/28; the
  tests do not exercise 0/1 on this task.
- `abi.decode(ret, (bytes32))` after a length check versus assembly
  `mload(add(ret, 32))` versus `bytes32(ret)`. All correct if the length check
  is `>= 32`.
- Whether `OwnedSigner` stores the owner as `immutable` or in storage. Ask
  what changes if the owner must be rotatable.
- Whether `OwnedSigner` reads `signature.length` before slicing or wraps a
  reverting helper in `try` on an external self-call. The latter costs an
  external call and makes `view` harder to keep.

## Follow-up questions

- A wallet is counterfactual (not deployed yet) and wants to sign a permit.
  `code.length` is zero, so the checker takes the ECDSA path. How does
  ERC-6492 solve this, and what does the checker have to do with the
  `factory` and `factoryCalldata` it carries?
- The signer contract validates the signature against a hash that it
  rehashes with its own domain (ERC-7739). Why would it do that, and what
  does the checker have to know?
- The checker is used inside a protocol that stores "signature already
  used" by hashing the signature bytes. What does a contract signer that
  accepts any bytes do to that deduplication?
- A multisig signer needs several ECDSA signatures concatenated in one
  `signature` argument. Does the checker need to change? Does `OwnedSigner`
  generalize, and how does the threshold check avoid duplicate signers?
- After EIP-7702, an EOA can have code. Which of the two paths applies to a
  delegated EOA, and what must its delegate implement for existing
  signatures to keep working?
