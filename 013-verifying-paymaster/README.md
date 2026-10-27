# Verifying paymaster

**Difficulty:** medium · **Topics:** ERC-4337 paymasters, sponsor signatures, validity windows, deposit and stake, postOp

A paymaster is the contract that tells the EntryPoint "I will pay for this
operation". A *verifying* paymaster does so for operations that an off-chain
service has approved and signed: the dapp's backend decides who gets free
gas and for how long, the paymaster checks the signature on chain and pays
from its deposit in the EntryPoint. This is the shape of nearly every
gas-sponsorship product, and most of its security lives in one question:
what exactly does the sponsor's signature commit to?

Implement `SponsorPaymaster` in `starter.sol`, against the real EntryPoint
v0.8.

```solidity
import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract SponsorPaymaster is IPaymaster {
    error NotEntryPoint();
    error NotOwner();
    error InvalidPaymasterData();

    event Sponsored(bytes32 indexed userOpHash, address indexed sender, uint256 actualGasCost);

    constructor(IEntryPoint entryPoint_, address owner_, address signer_);

    function entryPoint() external view returns (IEntryPoint);
    function owner() external view returns (address);
    function signer() external view returns (address);
    function setSigner(address newSigner) external;                      // owner only

    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public view returns (bytes32);

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external returns (bytes memory context, uint256 validationData);
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external;

    function deposit() external payable;                                 // anyone
    function withdrawTo(address payable to, uint256 amount) external;    // owner only
    function addStake(uint32 unstakeDelaySec) external payable;          // owner only
    function unlockStake() external;                                     // owner only
    function withdrawStake(address payable to) external;                 // owner only
}
```

## Requirements

- The paymaster is bound at construction to one EntryPoint and one owner;
  the signer is mutable through `setSigner`, callable only by the owner
  (`NotOwner` otherwise).
- `userOp.paymasterAndData` has the ERC-4337 v0.7+ layout, 129 bytes in
  total:

  | bytes | field |
  |---|---|
  | `[0:20]` | paymaster address (parsed by the EntryPoint) |
  | `[20:36]` | `paymasterVerificationGasLimit`, `uint128` (parsed by the EntryPoint) |
  | `[36:52]` | `paymasterPostOpGasLimit`, `uint128` (parsed by the EntryPoint) |
  | `[52:58]` | `validUntil`, `uint48` big-endian; `0` means "no expiry" |
  | `[58:64]` | `validAfter`, `uint48` big-endian |
  | `[64:129]` | sponsor signature, 65 bytes `r ‖ s ‖ v` |

  `validatePaymasterUserOp` reverts with `InvalidPaymasterData` if the
  length is not exactly 129. The EntryPoint reports such a revert as
  `FailedOpWithRevert(opIndex, "AA33 reverted", <your revert data>)`.
- `getHash(userOp, validUntil, validAfter)` is what the sponsor signs. It is
  `keccak256(abi.encode(...))` of, in this order:
  `userOp.sender`, `userOp.nonce`, `keccak256(userOp.initCode)`,
  `keccak256(userOp.callData)`, `userOp.accountGasLimits`,
  `userOp.preVerificationGas`, `userOp.gasFees`,
  `bytes32(userOp.paymasterAndData[20:52])` (the two paymaster gas limits),
  `block.chainid`, `address(this)`, `validUntil`, `validAfter`
  (the two `uint48` values are ABI-encoded, i.e. padded to 32 bytes each).
  It must **not** commit to `userOp.signature` (the user signs after the
  sponsor, and the sponsor must not be able to change what was sponsored by
  re-signing) and must **not** commit to the sponsor signature itself.
  `getHash` must work on any `paymasterAndData` of at least 52 bytes: when the
  sponsor computes it, bytes `[64:129]` do not exist yet.
- The sponsor signs the EIP-191 digest of that hash:
  `keccak256("\x19Ethereum Signed Message:\n32" ‖ getHash(...))` (what
  `personal_sign` produces for a 32-byte message). A signature over the raw
  `getHash` value is invalid.
- `validatePaymasterUserOp` may be called only by the EntryPoint
  (`NotEntryPoint` otherwise). It parses `validUntil`, `validAfter`, and the
  signature from `paymasterAndData`, recovers the signer, and returns:
  - `validationData = (uint256(validAfter) << 208) | (uint256(validUntil) << 160) | sigFailed`,
    where `sigFailed` is `0` when the recovered address equals `signer()`
    and `1` otherwise. A wrong signer must **not revert**: returning `1`
    makes the EntryPoint report `AA34 signature error`, and lets bundlers
    estimate gas with a dummy signature. `ecrecover` returning the zero
    address, including for a signature with an invalid `v`, is a signature
    failure.
  - `context = abi.encode(userOpHash, userOp.sender)`.

  The EntryPoint enforces the window: `AA32 paymaster expired or not due`
  when `block.timestamp > validUntil` (with `validUntil == 0` meaning never)
  or `block.timestamp <= validAfter`. The paymaster does not read
  `block.timestamp` itself (ERC-7562 forbids it in validation).
- `postOp` may be called only by the EntryPoint (`NotEntryPoint` otherwise).
  It decodes the context and emits `Sponsored(userOpHash, sender,
  actualGasCost)`. It is called for successful and for reverted operations
  alike; the paymaster pays in both cases.
- `deposit()` forwards `msg.value` to the EntryPoint's
  `depositTo(address(this))` and is callable by anyone. `withdrawTo`,
  `addStake`, `unlockStake`, and `withdrawStake` forward to the EntryPoint's
  functions of the same name on behalf of the paymaster and are callable only
  by the owner (`NotOwner` otherwise). Revert reasons from the EntryPoint
  (for example a stake withdrawal that is not yet due) bubble up unchanged.
- The sponsor's signature must be useless for anything but the one operation
  it was made for: a different `callData`, `nonce`, `sender`, gas parameter,
  paymaster gas limit, window, chain id, or paymaster contract (another
  deployment with the same signer) must all be rejected with `AA34`.
- Rotating the signer invalidates every signature of the old signer, even for
  operations already handed to a bundler.

No external libraries in `starter.sol`. Importing `IPaymaster`,
`IEntryPoint`, and `PackedUserOperation` from
`account-abstraction/interfaces/` is allowed; `BasePaymaster`,
`Helpers.sol`, and `UserOperationLib` are not. The parsing, the hash, the
signature check, and the `validationData` packing are yours to write.

## Validation

```sh
forge test --match-path "013-verifying-paymaster/*" -vv
```

`-vvvv` shows the full call trace inside `handleOps`, including the
`validatePaymasterUserOp` return value and the `AAxx` check that failed.

## Before coding

1. List every field of the user operation that changes what the sponsor
   ends up paying. Which of them does the user control after the sponsor has
   signed, and what happens if one of them is missing from `getHash`?
2. The sponsor signs before the user does. Which bytes of the operation does
   that force you to leave out of the hash, and why is leaving them out safe?
3. A bundler simulates `validatePaymasterUserOp` with a dummy sponsor
   signature to estimate gas. What must your function return in that case,
   and what would a `require(signer == recovered)` do to the estimation?
4. The EntryPoint receives `validUntil` and `validAfter` only through the
   bits of `validationData`. Write out the bit positions of the three
   components and what `validUntil == 0` means to the EntryPoint.
