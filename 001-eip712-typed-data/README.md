# EIP-712 typed data

**Difficulty:** medium · **Topics:** EIP-712, domain separator, struct hashing, dynamic types, arrays

Hash a structured message the way EIP-712 says, so that a wallet shows the
user readable fields and a contract can recover who signed exactly those
fields. Every permit, order, meta-transaction, user operation, and session key
starts here: if the contract hashes something different from what the wallet
hashed, the signature verifies for nothing or, worse, for something else.

Implement `TypedData` in `starter.sol`.

```solidity
contract TypedData {
    struct Person { string name; address wallet; }
    struct Mail { Person from; Person to; string contents; }
    struct Group { string name; Person[] members; bytes32[] tags; }

    error InvalidSignature();

    function domainSeparator() public view returns (bytes32);
    function hashPerson(Person calldata person) public pure returns (bytes32);
    function hashMail(Mail calldata mail) public pure returns (bytes32);
    function hashGroup(Group calldata group) public pure returns (bytes32);
    function digest(bytes32 structHash) public view returns (bytes32);
    function recoverMailSigner(Mail calldata mail, bytes calldata signature)
        external view returns (address);
}
```

## Requirements

- The domain is `name = "Ether Mail"`, `version = "1"`, `chainId` = the chain
  the call executes on, `verifyingContract` = the contract itself. No `salt`.
- `domainSeparator()` reflects the chain id at call time. After a fork that
  changes `chainid`, signatures made for the old chain do not verify.
- `hashPerson`, `hashMail`, and `hashGroup` return `hashStruct` as defined by
  EIP-712: `keccak256(typeHash ‖ encodeData)`, where
  - the type hash is `keccak256(encodeType)` and `encodeType` of a struct
    that references other structs appends the referenced types, sorted by
    name, after the primary type;
  - `string` and `bytes` values are encoded as the `keccak256` of their
    contents;
  - arrays are encoded as the `keccak256` of the concatenation of the
    encoded elements (for `Person[]`, the concatenation of each element's
    `hashStruct`; for `bytes32[]`, the concatenation of the elements);
  - an empty array or an empty string hashes to `keccak256("")`.
- `digest(structHash)` returns `keccak256("\x19\x01" ‖ domainSeparator() ‖ structHash)`.
- `recoverMailSigner` returns the address that signed `digest(hashMail(mail))`
  with a 65-byte `r ‖ s ‖ v` signature where `v` is 27 or 28.
- `recoverMailSigner` reverts with `InvalidSignature` if the signature is not
  65 bytes long or recovery yields the zero address. Task 002 covers
  malleability; here a well-formed signature is enough.
- The implementation must reproduce the example from the EIP-712
  specification: for chain id 1 and the contract at
  `0xCcCCccccCCCCcCCCCCCcCCCCCCCCcCCCCCCCCccCcC`, the domain separator is
  `0xf2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f`.

No external libraries in `starter.sol`: the point is to write the encoding
yourself.

## Before coding

1. Write down, by hand, the exact `encodeType` string of `Mail` and of
   `Group`. Where does `Person` go, and why?
2. Which fields of the domain can change after deployment, and which must
   therefore not be cached in an `immutable` or a constant?
3. For `Group.members`, what exactly gets concatenated before the final
   `keccak256`: the raw fields, the struct hashes, or something else?
4. A signature over `hashMail(mail)` is presented to a different contract
   with the same code. What makes it fail, and where in the hash does that
   live?
