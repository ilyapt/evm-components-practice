# Replay protection

**Difficulty:** medium · **Topics:** EIP-712, nonces, deadlines, domain binding, relayed execution

A signer authorizes an action off-chain, anyone submits it, and the contract
performs it on the signer's behalf. This is the core of every meta-transaction
forwarder, permit, intent protocol, and smart-account executor. The hard part
is not the call; it is making sure the signed message can be used exactly
once, only here, only now, and only for what was signed: the nonce stops
replay, the deadline bounds the window, the domain binds it to one chain and
one deployment, and the order of effects stops a malicious target from using
it twice inside a single transaction.

Builds on task 001: the digest is EIP-712 typed data.

Implement `IntentExecutor` in `starter.sol`.

```solidity
contract IntentExecutor {
    struct Intent {
        address target;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint256 deadline;
    }

    error Expired();
    error InvalidNonce();
    error InvalidSignature();
    error CallFailed(bytes returnData);

    event Executed(address indexed signer, uint256 indexed nonce, address indexed target);
    event Cancelled(address indexed signer, uint256 indexed nonce);

    function nonces(address signer) external view returns (uint256);
    function domainSeparator() public view returns (bytes32);
    function hashIntent(Intent calldata intent) public pure returns (bytes32);
    function execute(Intent calldata intent, address signer, bytes calldata signature)
        external payable returns (bytes memory);
    function cancel(uint256 nonce) external;
    receive() external payable;
}
```

## Requirements

- The EIP-712 domain is `name = "IntentExecutor"`, `version = "1"`,
  `chainId` = the chain the call executes on (read at call time, never
  cached), `verifyingContract` = the contract itself. No `salt`.
- `hashIntent` is the EIP-712 `hashStruct` of
  `Intent(address target,uint256 value,bytes data,uint256 nonce,uint256 deadline)`;
  `data` is encoded as `keccak256(data)`.
- The signed digest is `keccak256("\x19\x01" ‖ domainSeparator() ‖ hashIntent(intent))`.
- `nonces(signer)` is the next nonce `signer` must use, starting at 0. Nonces
  are sequential per signer: `execute` reverts with `InvalidNonce` unless
  `intent.nonce == nonces(signer)`, and on success `nonces(signer)` becomes
  `intent.nonce + 1`. Different signers have independent nonces.
- `execute` reverts with `Expired` when `block.timestamp > intent.deadline`.
  `block.timestamp == intent.deadline` is still valid.
- `execute` reverts with `InvalidSignature` unless `signature` is a 65-byte
  `r ‖ s ‖ v` signature with `v` in {27, 28} that recovers to `signer` over
  the digest. A recovered `address(0)` never matches, not even when `signer`
  is `address(0)`. The `s` malleability check is optional here; task 002
  covers it.
- On success, the contract calls `intent.target` with `intent.data` and
  `intent.value` wei from its own balance (`execute` is `payable`, so a
  relayer may supply that value in the same transaction; `receive` accepts
  ether at any time), emits `Executed(signer, nonce, target)`, and returns the
  call's return data unchanged.
- The nonce is consumed before the external call, so a target that calls back
  into `execute` with the same intent gets `InvalidNonce`.
- If the call fails, `execute` reverts with `CallFailed(returnData)` where
  `returnData` is the callee's revert data unchanged (possibly empty, for
  example when the balance is insufficient). Because the whole transaction
  reverts, a failed call does not consume the nonce: the signer's next intent
  with the same nonce still executes.
- `cancel(nonce)` lets `msg.sender` invalidate their own current nonce: it
  reverts with `InvalidNonce` unless `nonce == nonces(msg.sender)`, otherwise
  sets `nonces(msg.sender)` to `nonce + 1` and emits
  `Cancelled(msg.sender, nonce)`. No signature is needed, and nobody can
  cancel on another signer's behalf.
- A signature made for one chain does not verify after the chain id changes;
  a signature made for one deployment does not verify on another deployment
  with the same code. Nothing is consumed in either case.

No external libraries in `starter.sol`.

## Validation

The tests sign real intents with `vm.sign`, execute them through a relayer
address, and check: single use, nonce order, per-signer nonces, the inclusive
deadline, chain and deployment binding, every tampered field, wrong or zero
`signer`, malformed signatures, cancel semantics, bubbled revert data for
both `Error(string)` and custom errors, value forwarding from the balance and
from `msg.value`, and a reentrant target that attempts to re-execute the same
intent from inside the call. Known vectors: the domain separator for chain 1
at `0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC` is
`0x5181336ba4a24b5506f6133cc233d3f7e2f67f2f2798d4f678adca5652b3970d`.

## Before coding

1. List every field the signer commits to, in the domain and in the struct,
   and for each one name the attack it prevents. Which field prevents a
   relayer from executing the same signed intent on a second deployment?
2. Write down the order of operations in `execute`: checks, nonce update,
   external call, event. Which step must come before the call, and what can
   a malicious `target` do if it comes after?
3. A failed call must leave the nonce unchanged. Which mechanism gives you
   that for free, and what does it mean for the relayer who paid the gas?
4. Why does `cancel` take `msg.sender` instead of a signature, and what would
   change if the signer were a contract wallet rather than an EOA?
