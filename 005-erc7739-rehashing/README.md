# ERC-7739 defensive rehashing

**Difficulty:** hard · **Topics:** ERC-7739, EIP-1271, EIP-712 nesting, ERC-5267, cross-account replay

A smart account whose owner is an EOA answers `isValidSignature` (EIP-1271)
by checking the owner's ECDSA signature. The naive version checks it over the
`hash` the application passes in. That hash binds the application's domain
and the signed struct, but not the account: the same owner signature is valid
on every account that owner controls, so a Permit2 approval or a marketplace
order signed for account A can be replayed on account B. ERC-7739 fixes this
by having the owner sign a digest that nests the application's typed data
inside the account's own EIP-712 domain, so wallets still show the original
fields and the signature only verifies on the account it was made for. This
task is the account side; every modern smart-account implementation (Solady,
OpenZeppelin, Safe, Coinbase, Kernel) ships a version of it.

Implement `Erc7739Account` in `starter.sol`.

```solidity
contract Erc7739Account {
    constructor(address owner_);
    function owner() external view returns (address);

    // ERC-5267
    function eip712Domain()
        external view
        returns (
            bytes1 fields, string memory name, string memory version, uint256 chainId,
            address verifyingContract, bytes32 salt, uint256[] memory extensions
        );

    // EIP-1271 with ERC-7739 semantics
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external view returns (bytes4);
}
```

## Requirements

### Domain (ERC-5267)

- The account's EIP-712 domain is `name = "Erc7739Account"`, `version = "1"`,
  `chainId` = the chain the call executes on, `verifyingContract` = the
  account itself. No `salt`, no extensions.
- `eip712Domain()` returns `fields = 0x0f` (bits 0..3: name, version,
  chainId, verifyingContract), the values above, `salt = bytes32(0)` and an
  empty `extensions` array. The account domain separator is
  `keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("Erc7739Account"), keccak256("1"), chainid, address(this)))`
  and must follow the live `chainid`.

### Detection

- `isValidSignature(0x7739773977397739773977397739773977397739773977397739773977397739, "")`
  (that exact hash, empty signature) returns `0x77390001`. Any other call
  returns `0x1626ba7e` (valid) or `0xffffffff` (invalid).

### Choosing the workflow

- The signature is parsed from the end. If it is long enough and its last
  `2 + len + 64` bytes decode as

  ```
  originalSignature ‖ APP_DOMAIN_SEPARATOR (32) ‖ contentsHash (32) ‖ contentsDescr (len bytes) ‖ uint16(len)
  ```

  **and** `hash == keccak256("\x19\x01" ‖ APP_DOMAIN_SEPARATOR ‖ contentsHash)`,
  the account MUST run the `TypedDataSign` workflow with `originalSignature`
  = everything before the suffix.
- Otherwise the account MUST run the `PersonalSign` workflow with the whole
  `signature` as the owner's signature.
- Nothing else chooses the workflow: a suffix whose reconstructed hash does not
  match is not an error, it just means the bytes are not a suffix.

### `TypedDataSign` workflow

- `contentsDescr` describes the application's struct type. Two modes:
  - **Implicit mode**, when `contentsDescr` ends with `)`:
    `contentsType = contentsDescr` and `contentsName` is the substring of
    `contentsDescr` before the first `(`.
    Example: `Order(address maker,uint256 price,uint256 nonce)` → name `Order`.
  - **Explicit mode**, when `contentsDescr` does not end with `)`:
    `contentsDescr = contentsType ‖ contentsName`, where `contentsType` ends
    at the last `)` and `contentsName` is everything after it.
    Example: `Asset(address token,uint256 id)Listing(Asset asset,address maker,uint256 price)Listing`
    → type `Asset(...)Listing(...)`, name `Listing`. Explicit mode exists
    because EIP-712 sorts referenced types by name, so a struct that
    references another struct is not always first in the type string.
  Both modes must be supported.
- The signature is invalid (`0xffffffff`) if `contentsName` is empty, starts
  with any of the bytes `abcdefghijklmnopqrstuvwxyz(`, or contains any of the
  bytes `,` (comma), ` ` (space), `)` or `\x00`.
- The account builds the type string and the type hash on the fly:

  ```
  typedDataSignTypehash = keccak256(
      "TypedDataSign(" ‖ contentsName ‖ " contents,"
      "string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)"
      ‖ contentsType
  )
  ```

  For the `Order` example this is the keccak256 of
  `TypedDataSign(Order contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)Order(address maker,uint256 price,uint256 nonce)`.
- The final digest nests the account's domain fields **inside the struct**
  and uses the **application's** domain separator as the outer one:

  ```
  finalDigest = keccak256("\x19\x01" ‖ APP_DOMAIN_SEPARATOR ‖ keccak256(abi.encode(
      typedDataSignTypehash,
      contentsHash,
      keccak256("Erc7739Account"),   // eip712Domain().name
      keccak256("1"),                // eip712Domain().version
      chainid,                       // eip712Domain().chainId
      address(this),                 // eip712Domain().verifyingContract
      bytes32(0)                     // eip712Domain().salt (always present as a field)
  )))
  ```

- The result is `0x1626ba7e` if `originalSignature` is the owner's ECDSA
  signature over `finalDigest`, `0xffffffff` otherwise.

### `PersonalSign` workflow

- `hash` is treated as an EIP-191 personal-sign hash computed by the
  application. The struct is `PersonalSign(bytes prefixed)`, where
  `prefixed` is the prefixed message bytes; since `bytes` are encoded by
  their keccak256 and that keccak256 is exactly `hash`:

  ```
  finalDigest = keccak256("\x19\x01" ‖ ACCOUNT_DOMAIN_SEPARATOR ‖ keccak256(abi.encode(
      keccak256("PersonalSign(bytes prefixed)"),
      hash
  )))
  ```

- The result is `0x1626ba7e` if `signature` is the owner's ECDSA signature
  over `finalDigest`, `0xffffffff` otherwise.

### ECDSA and robustness

- A signature is only accepted as 65 bytes `r ‖ s ‖ v` with `v` in {27, 28}
  and `s` in the lower half of the curve order
  (`s <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`).
  A recovered `address(0)` is never a match.
- `isValidSignature` never reverts for malformed input (wrong lengths, bad
  suffix, garbage bytes); it returns `0xffffffff`.
- Consequences the tests check: an owner signature made for account A is
  rejected by account B with the same owner in both workflows; a raw owner
  signature over the application's digest (the naive EIP-1271) is rejected;
  changing the chain id invalidates both workflows.

No external libraries in `starter.sol`: parsing the suffix, building the
type string and recovering the signer is the task. The ERC text is at
<https://eips.ethereum.org/EIPS/eip-7739>; the layouts above are copied from
it and are enough to implement from.

## Before coding

1. Write down which domain separator is the outer one in each workflow and
   which domain's fields end up inside the struct. What does the owner's
   wallet show for the `TypedDataSign` request, and why does the account's
   domain still bind the signature?
2. Two accounts with the same owner receive the same `hash` and the same
   `signature`. Name the exact field, in each workflow, that makes the
   second account return `0xffffffff`.
3. The suffix is parsed from the end with an untrusted `uint16` length. List
   the length checks you need before slicing so that no input can make the
   function revert, and decide what happens when the length field points
   past the start of the signature.
4. Why does the standard reject a `contentsName` that starts with a lowercase
   letter or contains a space, comma or `)`? What could a phishing site do
   with `contentsName = "uint256 x,bytes32 y"`?
