# EOA delegation (EIP-7702)

**Difficulty:** medium · **Topics:** EIP-7702, delegation designators, self-calls, initialization without a constructor, revocation, storage persistence

EIP-7702 lets an externally owned account set its code to a *delegation
designator*: the 23 bytes `0xef0100 ‖ implementation`. From then on every call
to the EOA runs the implementation's code in the EOA's own context: its
address, its balance, its storage. The EOA keeps its private key and can still
send ordinary transactions, including transactions to itself. This is how a
plain wallet gains batching, sponsored gas, and session-style operators without
moving funds to a new address. The implementation contract here is the
simplest useful one: a batch executor whose only authority is the EOA key,
plus operators the key can appoint.

Implement `DelegatedAccount` in `starter.sol`.

```solidity
contract DelegatedAccount {
    struct Call { address target; uint256 value; bytes data; }

    error NotSelf();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    event OperatorSet(address indexed operator, bool allowed);
    event Executed(address indexed by, uint256 calls);

    function isOperator(address who) external view returns (bool);
    function setOperator(address operator, bool allowed) external;  // only self
    function execute(Call[] calldata calls) external payable;         // self or operator
    receive() external payable;
}
```

## Requirements

- The EOA's own key is the only root authority. A transaction signed by the
  EOA key and sent to the EOA itself arrives in the implementation's code with
  `msg.sender == address(this)`. That, and nothing else, is "the owner".
- `setOperator(operator, allowed)` succeeds only when
  `msg.sender == address(this)`; any other caller, including an operator,
  reverts with `NotSelf`. It records the flag and emits
  `OperatorSet(operator, allowed)`. `isOperator` returns the current flag.
- `execute(calls)` succeeds when `msg.sender == address(this)` or
  `isOperator(msg.sender)`; any other caller reverts with `NotAuthorized`.
- `execute` runs the calls in order with `call{value: calls[i].value}(calls[i].data)`
  to `calls[i].target`. Every target sees `msg.sender == the EOA`, and the value
  comes from the EOA's balance. If call `i` fails, the whole batch reverts
  with `CallFailed(i, returnData)` where `returnData` is the failing call's
  raw revert data; nothing before `i` stays applied. An empty batch succeeds.
  On success emit `Executed(msg.sender, calls.length)`.
- There is no constructor logic, no `immutable`, and no `initialize` function.
  Under EIP-7702 the implementation is deployed once and then adopted by many
  EOAs; its constructor runs only for the standalone deployment, never for an
  EOA, and an `initialize(owner)` function that sets a stored owner can be
  front-run: anyone who sees the delegation land calls `initialize` first and
  owns the account. The self-call check removes the need for initialization:
  the EOA key already proves ownership on every call.
- The implementation contract deployed on its own (not as a delegate) must be
  inert: no caller can satisfy `msg.sender == address(this)` for it, it has no
  operators, so `execute` and `setOperator` revert for everyone.
- Storage written while delegated lives in the EOA's account, not in the
  implementation. Operators set under one delegation are still set after the
  EOA re-delegates to the same implementation, and still set after the EOA
  revokes its delegation (sets its code back to empty) and delegates again.
- After revocation the EOA has no code: plain value transfers to it succeed,
  and a call carrying `execute` calldata succeeds with no effect and no return
  data, because there is nothing to run. The tests assert what the EVM does
  here; the implementation cannot change it, but you must know it.
- `receive` accepts ETH so that the delegated EOA can still be paid.

No external libraries in `starter.sol`.

## Validation

The tests delegate a fresh key with Foundry's `vm.signAndAttachDelegation` and
make self-calls with `vm.prank(alice)` so that `msg.sender == address(this)`
inside the implementation. A recording target checks which `msg.sender` the
outside world sees. Two "no contracts" targets show what happens to
`msg.sender == tx.origin` and `msg.sender.code.length == 0` checks when the
caller is a delegated EOA.

## Before coding

1. Inside `execute`, running as alice's code, what are `address(this)`,
   `msg.sender`, and `tx.origin` when (a) alice sends the transaction herself
   and (b) an operator sends it? Which of the three identifies the account?
2. Why can an `initialize(address owner)` function not be made safe under
   EIP-7702 by a "call it in the same transaction" argument alone? Who else
   can send a transaction to alice's address between the delegation and the
   initialization, and what stops them?
3. Alice sets an operator, revokes the delegation, and a month later
   delegates to a different implementation that also keeps a
   `mapping(address => bool)` in slot 0. What does the new implementation
   read, and what would you want from the new implementation before trusting
   it with that slot? (Task 028 covers migration.)
4. A target contract rejects callers with `msg.sender.code.length != 0`.
   Can alice ever use it through `execute`? Through a direct transaction from
   her key while still delegated?
