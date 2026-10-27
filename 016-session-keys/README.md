# Session keys

**Difficulty:** hard · **Topics:** ERC-4337, session keys, scoped permissions, validity windows in validationData, revocation, ERC-7562

Builds on 011: the single-owner account is rewritten here, then extended.

A session key is a temporary key the owner of a smart account hands to a
dapp, a game, or an automation so that it can act without asking the owner to
sign every operation. The key is worthless unless the account enforces its
scope: which contract it may call, which function, how much ETH per call, and
when. Everything the account checks about a session must happen inside
`validateUserOp`, where ERC-4337 gives it the operation's `callData` and the
EntryPoint gives it a way to express the time window without reading the
clock itself: the `validationData` return value.

Implement `SessionKeyAccount` in `starter.sol`.

```solidity
contract SessionKeyAccount is IAccount {
    struct Call { address target; uint256 value; bytes data; }
    struct Session {
        address target;
        bytes4 selector;
        uint256 maxValuePerCall;
        uint48 validAfter;
        uint48 validUntil;
    }

    error NotEntryPoint();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);
    error InvalidSession();

    event SessionGranted(address indexed key, Session session);
    event SessionRevoked(address indexed key);

    constructor(IEntryPoint entryPoint_, address owner_);
    function entryPoint() external view returns (IEntryPoint);
    function owner() external view returns (address);
    function sessions(address key) external view returns (Session memory);
    function grantSession(address key, Session calldata session) external;  // owner or self
    function revokeSession(address key) external;                            // owner or self
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external returns (uint256 validationData);
    function execute(address target, uint256 value, bytes calldata data) external;   // EntryPoint or owner
    function executeBatch(Call[] calldata calls) external;                           // EntryPoint or owner
    receive() external payable;
}
```

## Requirements

Base account (as in 011):

- `validateUserOp` reverts with `NotEntryPoint` unless `msg.sender` is the
  EntryPoint given to the constructor.
- `userOp.signature` is a 65-byte `r ‖ s ‖ v` ECDSA signature over
  `userOpHash`. Recover the signer. A signature that is not 65 bytes long or
  recovers to the zero address is a failure.
- Prefund: when `missingAccountFunds != 0`, send exactly that amount to
  `msg.sender` with a plain call and ignore the result.
- `execute` and `executeBatch` succeed when `msg.sender` is the EntryPoint or
  the owner; otherwise revert with `NotAuthorized`. Calls run in order with
  `call{value}`; a failing call reverts the batch with
  `CallFailed(index, returnData)` (`index` is `0` for `execute`).
- `entryPoint()` and `owner()` return the constructor arguments. `receive`
  accepts ETH.

Sessions:

- `sessions(key)` returns the session granted to `key`, or a zeroed struct.
- `grantSession(key, session)` and `revokeSession(key)` succeed when
  `msg.sender` is the owner or the account itself (so the owner can grant
  through an operation whose `callData` is
  `execute(address(this), 0, grantSession(...))`); otherwise revert with
  `NotAuthorized`.
- `grantSession` reverts with `InvalidSession` when `session.target` is
  `address(0)` or `address(this)`, or when
  `session.validUntil != 0 && session.validUntil <= session.validAfter`.
  `validUntil == 0` means no expiry. A grant to a key that already has a
  session replaces it. Emit `SessionGranted(key, session)`.
- `revokeSession` clears the session (`sessions(key)` returns a zeroed
  struct afterwards) and emits `SessionRevoked(key)`.

Validation:

- If the recovered signer is the owner, return `0`.
- Otherwise, if the signer has a session, the operation's `callData` must be
  either
  - a call to this account's `execute(target, value, data)` with
    `target == session.target`, `value <= session.maxValuePerCall`,
    `data.length >= 4`, and `bytes4(data) == session.selector`; or
  - a call to this account's `executeBatch(calls)` where every call satisfies
    the same three checks (the value limit is per call, not per batch);

  and in both forms a call whose `target` is the account itself is out of
  scope, whatever the session says. If the `callData` is within scope, return
  `(uint256(session.validAfter) << 208) | (uint256(session.validUntil) << 160)`
  with the low 160 bits zero. The EntryPoint enforces the window: it rejects
  the operation with `AA22 expired or not due` when
  `block.timestamp <= validAfter` or `block.timestamp > validUntil`
  (`validUntil == 0` is treated as "forever").
- In every other case (unknown signer, revoked or never-granted session, out
  of scope `callData`, a `callData` that is not `execute` or `executeBatch`
  or is shorter than four bytes, a malformed signature) return `1`. Do not
  revert: the EntryPoint reports `1` as `AA24 signature error` and a revert
  as `AA23 reverted`, which breaks bundler simulation.
- Validation must not read `block.timestamp` or `block.number`
  (ERC-7562 banned opcodes). Time is expressed through the return value, not
  checked by the account.
- Nonces are the EntryPoint's job; the account does not track them.

`starter.sol` may import `IAccount`, `IEntryPoint`, and `PackedUserOperation`
from `account-abstraction/interfaces/`. It must not inherit `BaseAccount` or
import the `core` helpers: pack the validation data and pay the prefund
yourself. No other external libraries.

## Validation

The tests deploy the real EntryPoint v0.8 and send every operation through
`handleOps`, signed over `entryPoint.getUserOpHash(op)` either by the owner
key or by a session key. Windows are exercised with `vm.warp`, so a session
that reads the clock itself would still pass; the reviewer looks for that.
Session scope failures must surface as `FailedOp(0, "AA24 signature error")`,
window failures as `FailedOp(0, "AA22 expired or not due")`.

## Before coding

1. The session key signs an operation whose `callData` calls `execute` with
   `target = address(this)` and `data = grantSession(key, wider)`. Which of
   your checks stops it, and would it still be stopped if `grantSession`
   accepted `target == address(this)`?
2. Why must the window go into `validationData` instead of a
   `require(block.timestamp < validUntil)` inside `validateUserOp`? What does
   a bundler do with an operation whose validation result depends on the
   block it is simulated in?
3. `executeBatch` with ten calls: do you decode the whole array in
   validation, and what bounds the gas you spend there? Who pays for a
   session key that submits a batch of a thousand calls that fails
   validation?
4. The owner revokes a session while an operation signed by that key is
   already in the mempool. Which transaction wins, and what does the key
   holder see?
