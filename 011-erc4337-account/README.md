# ERC-4337 account

**Difficulty:** medium · **Topics:** ERC-4337, validateUserOp, prefund, EntryPoint, execution authorization

A smart account is a contract that the ERC-4337 EntryPoint can ask two things
of: "is this operation yours, and will you pay for it?" (`validateUserOp`)
and "do it" (the `callData` call). Everything a wallet does with account
abstraction — owner signatures, gas sponsorship, batching, session keys — is
built on an account that answers those two questions correctly. This task is
the smallest such account: one owner key, ECDSA, no upgrades, no modules,
working against the real EntryPoint v0.8.

Implement `OwnerAccount` in `starter.sol`.

```solidity
import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

contract OwnerAccount is IAccount {
    struct Call { address target; uint256 value; bytes data; }

    error NotEntryPoint();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    constructor(IEntryPoint entryPoint_, address owner_);

    function entryPoint() external view returns (IEntryPoint);
    function owner() external view returns (address);

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external returns (uint256 validationData);

    function execute(address target, uint256 value, bytes calldata data) external;
    function executeBatch(Call[] calldata calls) external;

    function addDeposit() external payable;
    function getDeposit() external view returns (uint256);
    function withdrawDepositTo(address payable to, uint256 amount) external;

    receive() external payable;
}
```

## Requirements

- The account is bound at construction to one EntryPoint and one owner.
  `entryPoint()` and `owner()` return them.
- `validateUserOp` may be called only by the EntryPoint; any other caller,
  including the owner, gets `NotEntryPoint`.
- `userOp.signature` is the owner's 65-byte ECDSA signature `r ‖ s ‖ v`
  (`v` is 27 or 28) over `userOpHash` **directly**. No
  `"\x19Ethereum Signed Message:\n32"` prefix: EntryPoint v0.8 hashes are
  already EIP-712 typed data (domain `ERC4337`/`1`, the chain id and the
  EntryPoint address are inside the hash), so a wallet signs them with
  `eth_signTypedData_v4`.
- `validateUserOp` returns `0` when the signature recovers to the owner and
  `1` (`SIG_VALIDATION_FAILED`) otherwise. It must **not revert** on a bad
  signature, and "bad" includes a signature of the wrong length, an invalid
  `v`, or anything that makes `ecrecover` return the zero address. The
  EntryPoint turns the return value `1` into `FailedOp("AA24 signature
  error")`; a revert inside `validateUserOp` becomes `FailedOpWithRevert("AA23
  reverted", …)`, which bundlers treat as a broken account rather than a bad
  signature, and which breaks gas estimation (bundlers estimate with a dummy
  signature and rely on `1`, not on a revert).
- When `missingAccountFunds > 0`, the account pays exactly that amount to
  `msg.sender` (the EntryPoint) with a plain `call` carrying the value, from
  the account's own ETH balance, and **ignores the result** of that call.
  Document in a comment why ignoring it is correct. The EntryPoint credits the
  value to the account's deposit; whatever the operation does not consume
  stays there.
- The account keeps **no nonce of its own**. The EntryPoint validates and
  increments `userOp.nonce`; replaying an executed operation must fail with
  the EntryPoint's `AA25 invalid account nonce`, not with anything the account
  does.
- `execute` and `executeBatch` may be called by the EntryPoint or by the
  owner directly; anyone else gets `NotAuthorized`.
- `execute` performs `target.call{value: value}(data)`. If the call fails, it
  reverts with `CallFailed(0, returnData)`, where `returnData` is the callee's
  revert data.
- `executeBatch` performs the calls in array order and reverts with
  `CallFailed(i, returnData)` for the first failing call `i`. A failed call
  rolls the whole batch back. An empty batch succeeds.
- `addDeposit` forwards `msg.value` to the EntryPoint's `depositTo(address(this))`
  and is callable by anyone. `getDeposit` returns the account's balance in
  the EntryPoint (`balanceOf`).
- `withdrawDepositTo` is callable only by the owner (`NotAuthorized`
  otherwise) and forwards to the EntryPoint's `withdrawTo(to, amount)`.
- The account accepts plain ETH transfers.
- `validateUserOp` must stay within ERC-7562 validation rules: no
  `block.timestamp`/`block.number`, no storage of other contracts, no
  external calls except the prefund transfer to the EntryPoint. Bundlers
  simulate validation with these rules and drop operations that break them.

No external libraries in `starter.sol`. Importing `IAccount`, `IEntryPoint`,
and `PackedUserOperation` from `account-abstraction/interfaces/` is allowed;
`BaseAccount`, `Helpers.sol`, and `UserOperationLib` are not. The signature
check, the validation-data convention, and the prefund are yours to write.

## Validation

```sh
forge test --match-path "011-erc4337-account/*" -vv
```

`-vvvv` shows the full call trace inside `handleOps`, which is the fastest
way to see which `AAxx` check an operation failed.

## Before coding

1. A user operation's signature is checked twice: once by the bundler's
   simulation and once on chain. What must `validateUserOp` do for the
   simulation to be useful, and which failures must therefore be *returned*
   rather than *reverted*?
2. The EntryPoint tells you `missingAccountFunds`. Where does the money come
   from, where does it go, and who checks that it arrived? What does your
   account gain by checking the transfer's result itself?
3. The same signed operation is submitted twice. Which component rejects the
   second one, at which point of `handleOps`, and what does your account
   contribute to that?
4. `execute` is reachable by the EntryPoint and by the owner. What is the
   difference between those two paths in terms of who paid for gas and
   which checks have already happened?
