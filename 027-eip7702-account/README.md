# EIP-7702 account (ERC-4337 through a delegated EOA)

**Difficulty:** hard · **Topics:** EIP-7702, ERC-4337, EntryPoint v0.8, owner == address(this), initCode 0x7702 marker

Builds on 011 and 026.

Task 026 gave an EOA code that answers to the EOA's own key. This task makes
that code an ERC-4337 account, so the delegated EOA can send user operations
through the EntryPoint: a bundler pays the transaction, a paymaster can sponsor
it, and the EOA still signs with the key it always had. There is no stored
owner anywhere. The signer the account accepts is `address(this)`: the only
address whose key can produce a signature that recovers to the account's own
address is the EOA that adopted the code. The standalone implementation
contract has an address nobody holds a key for, so it can never validate
anything.

EntryPoint v0.8 knows about EIP-7702 senders. A user operation whose
`initCode` starts with the two bytes `0x7702` tells the EntryPoint "this sender
is a delegated EOA": the EntryPoint reads the delegation designator from the
sender's code, requires it to be one (otherwise `handleOps` reverts with
`"sender has no code"` or `"not an EIP-7702 delegate"`), and replaces the
`initCode` hash in `getUserOpHash` with the hash of the delegate address
(plus any bytes after the first 20 bytes of `initCode`, which the EntryPoint
then sends to the sender as an initialization call from its `SenderCreator`).
The signature therefore commits to *which implementation* the EOA is
delegated to: a bundler that includes a different authorization in the same
transaction cannot make the operation run under other code. The account does
not parse the marker itself; it only signs what `getUserOpHash` returns.
Study `lib/account-abstraction/contracts/core/Eip7702Support.sol` and
`EntryPoint.getUserOpHash` before coding.

Implement `Delegated4337Account` in `starter.sol`.

```solidity
contract Delegated4337Account is IAccount {
    struct Call { address target; uint256 value; bytes data; }

    error NotEntryPoint();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    constructor(IEntryPoint entryPoint_);
    function entryPoint() public view returns (IEntryPoint);
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external returns (uint256 validationData);
    function execute(address target, uint256 value, bytes calldata data) external;   // EntryPoint or self
    function executeBatch(Call[] calldata calls) external;                           // EntryPoint or self
    receive() external payable;
}
```

## Requirements

- `validateUserOp` reverts with `NotEntryPoint` unless `msg.sender` is the
  EntryPoint.
- `userOp.signature` is a 65-byte `r ‖ s ‖ v` ECDSA signature over
  `userOpHash` (the value the EntryPoint passes in, which is
  `EntryPoint.getUserOpHash(userOp)`). If it recovers to `address(this)`,
  return `0`; in every other case, including a signature that is not 65 bytes
  long or recovers to the zero address, return `1`. Do not revert on a bad
  signature: the EntryPoint reports a return value of `1` as
  `AA24 signature error`, and a revert as `AA23 reverted`, which breaks
  bundler simulation.
- Prefund: when `missingAccountFunds != 0`, send exactly that amount to
  `msg.sender` (the EntryPoint) with a plain call and ignore the result; the
  EntryPoint checks its own deposit and fails the operation with
  `AA21 didn't pay prefund` if it is short. The ETH comes from the EOA's own
  balance because the code runs in the EOA's context.
- `execute(target, value, data)` and `executeBatch(calls)` succeed when
  `msg.sender` is the EntryPoint or `address(this)` (a transaction signed by
  the EOA key and sent to the EOA itself); otherwise revert with
  `NotAuthorized`. Calls run in order with `call{value}`; a failing call
  reverts the batch with `CallFailed(index, returnData)` (`index` is `0` for
  `execute`). Targets see `msg.sender == the EOA`.
- No storage-based owner, no `initialize`, and no stored EntryPoint. The
  EntryPoint address is an `immutable` set in the implementation's
  constructor: immutables are baked into the implementation's bytecode, and a
  delegated EOA executes that bytecode, so every EOA that adopts the
  implementation sees the same EntryPoint without ever writing storage. That
  is exactly why an `immutable` *owner* would be wrong (same for every EOA)
  and an `immutable` EntryPoint is right (meant to be the same for every EOA).
  `entryPoint()` returns it, also when called on a delegated EOA.
- The implementation deployed on its own must not be usable: its
  `validateUserOp` returns `1` for every signature (nobody has the key of a
  contract address) and its `execute`/`executeBatch` revert with
  `NotAuthorized` for every caller except the EntryPoint, which only calls
  after a successful validation.
- Operations must work both with an empty `initCode` and with the `0x7702`
  marker `initCode`. The account signs `getUserOpHash` in both cases; the
  difference is what the hash commits to. With a marker `initCode` longer than
  20 bytes, the EntryPoint calls the sender with the remaining bytes from its
  `SenderCreator` *before* validation; that caller is neither the EntryPoint
  nor the account, so the account's authorization rules must reject it.
- After the EOA revokes its delegation, the EntryPoint fails the operation
  with `AA20 account not deployed` (the call returns no data). This is the
  EntryPoint's behaviour, not yours, but the tests pin it down.
- `receive` accepts ETH.

`starter.sol` may import `IAccount`, `IEntryPoint`, and `PackedUserOperation`
from `account-abstraction/interfaces/`. It must not inherit `BaseAccount` or
import the `core` helpers: pack the validation data and pay the prefund
yourself. No other external libraries.

## Validation

The tests deploy the real EntryPoint v0.8, delegate a fresh key with
`vm.signAndAttachDelegation`, fund the EOA, and drive every operation through
`handleOps`. Failures are decoded as `FailedOp(0, "AA..")` or
`FailedOpWithRevert(0, "AA13 EIP7702 sender init failed", inner)`; the
`0x7702` marker without a delegation is a plain string revert from
`getUserOpHash`. An independent EIP-712 hash of the operation checks that the
marker replaces the `initCode` hash with the delegate address.

## Before coding

1. In `validateUserOp` running as alice's code, what is `address(this)`? Why
   does comparing the recovered signer against it need no storage, and what
   happens to that comparison when the same code runs as the standalone
   implementation?
2. The EntryPoint address is an `immutable`. Where does an `immutable` live
   at runtime, and why does that make it safe under EIP-7702 when a stored
   owner would not be? What would change if the EntryPoint address were kept
   in storage instead?
3. The bundler receives alice's operation with `initCode = 0x7702` and a
   signed authorization pointing at a different implementation. Walk through
   `getUserOpHash`: what does the hash commit to, and at which step does the
   bundler's substitution fail?
4. Alice sends a user operation and, in the same block, a plain transaction
   from her key that calls `execute` directly. Which nonce protects which
   path, and can the two paths interfere with each other?
