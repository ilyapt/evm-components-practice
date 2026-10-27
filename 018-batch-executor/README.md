# ERC-7821 batch executor

**Difficulty:** medium · **Topics:** ERC-7821, EIP-5792 atomicity, execution modes, revert bubbling, signature-authorized batches

A batch executor is the piece of a wallet that runs several calls as one
atomic unit: approve-then-swap, multi-step deposits, a session-key setup. An
EOA delegated with EIP-7702 or a smart account exposes it, a dapp prepares it
through `wallet_sendCalls` (EIP-5792), and ERC-7821 standardizes the
interface so every wallet and frontend agree on the mode encoding, the
calldata layout and the failure semantics: all calls succeed, or nothing
changes and the failing call's error is visible to the caller.

Implement `BatchExecutor` in `starter.sol`.

```solidity
contract BatchExecutor {
    struct Call { address to; uint256 value; bytes data; }

    error UnsupportedExecutionMode();
    error Unauthorized();
    error InvalidNonce();
    error InvalidSignature();

    event BatchExecuted(uint256 indexed nonce, uint256 calls);

    constructor(address owner_);
    function owner() external view returns (address);
    function nonce() external view returns (uint256);
    function supportsExecutionMode(bytes32 mode) external view returns (bool);
    function execute(bytes32 mode, bytes calldata executionData) external payable;
    function domainSeparator() public view returns (bytes32);
    receive() external payable;
}
```

## Requirements

### Execution modes

- `mode` follows the ERC-7579 layout that ERC-7821 adopts:

  | bytes | meaning |
  |---|---|
  | `[0]` | `0x01` = batch call |
  | `[1]` | `0x00` = revert on any failure |
  | `[2..5]` | reserved, ignored |
  | `[6..9]` | mode selector: `0x00000000` (single batch, no `opData`) or `0x78210001` (single batch, optional `opData`) |
  | `[10..31]` | unused, ignored |

  `supportsExecutionMode` returns `true` exactly when bytes `[0]`, `[1]` and
  `[6..9]` match one of the two rows; bytes `[2..5]` and `[10..31]` do not
  matter. The canonical values are
  `0x0100000000000000000000000000000000000000000000000000000000000000` and
  `0x0100000000007821000100000000000000000000000000000000000000000000`.
- The batch-of-batches mode (selector `0x78210002`) is **not** supported in
  this task: `supportsExecutionMode` returns `false` for it, as the ERC
  requires when the mode is not implemented.
- `execute` with any unsupported mode reverts with `UnsupportedExecutionMode`.

### Calldata layout

- Selector `0x00000000`: `executionData = abi.encode(Call[] calls)`.
- Selector `0x78210001`: `executionData = abi.encode(Call[] calls, bytes opData)`.
  `opData` may be empty.
- `Call.to == address(0)` means the executor itself (`address(this)`); the
  substitution happens at execution time only, the signed struct keeps the
  raw `address(0)`.

### Authorization

- Empty `opData` (always for selector `0x00000000`, optionally for
  `0x78210001`): the caller must be the executor itself (a nested batch) or
  `owner()`. Anyone else → `Unauthorized`.
- Non-empty `opData`: a signed batch that anyone (a relayer) may submit.
  `opData = abi.encodePacked(uint256 nonce, bytes signature)` with a 65-byte
  `r ‖ s ‖ v` signature, so `opData` is exactly 97 bytes; any other length →
  `InvalidSignature`.
  - `nonce` must equal `nonce()`, otherwise `InvalidNonce`. The stored nonce
    is incremented **before any call executes**, so a call in the batch that
    re-enters `execute` with the same `opData` fails with `InvalidNonce` and
    does not run the batch twice.
  - `signature` must be the owner's ECDSA signature (`v` in {27, 28}, lower-
    half `s`, non-zero recovered address) over the EIP-712 digest below;
    otherwise `InvalidSignature`.
  - A batch that reverts does not consume its nonce: the whole transaction,
    including the increment, is rolled back.

### Signed batch digest (EIP-712)

- Domain: `name = "BatchExecutor"`, `version = "1"`, `chainId` = the chain at
  call time, `verifyingContract` = the executor. `domainSeparator()` returns
  `keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("BatchExecutor"), keccak256("1"), chainid, address(this)))`.
- Types, with the referenced `Call` appended per EIP-712:

  ```
  Execute(bytes32 mode,Call[] calls,uint256 nonce)Call(address to,uint256 value,bytes data)
  Call(address to,uint256 value,bytes data)
  ```

  `hashStruct(Call) = keccak256(abi.encode(CALL_TYPEHASH, to, value, keccak256(data)))`;
  `calls` is encoded as `keccak256(hashStruct(calls[0]) ‖ hashStruct(calls[1]) ‖ ...)`
  (an empty array encodes as `keccak256("")`);
  `hashStruct(Execute) = keccak256(abi.encode(EXECUTE_TYPEHASH, mode, callsHash, nonce))`,
  where `mode` is the exact `bytes32` passed to `execute`.
- `digest = keccak256("\x19\x01" ‖ domainSeparator() ‖ hashStruct(Execute))`.
  A signature is therefore bound to the mode, the calls, the nonce, the chain
  and the executor; a different executor with the same owner rejects it.

### Execution

- Calls run in array order, each as `to.call{value: value}(data)`, with
  `to` substituted for `address(0)` as above. Value comes from the executor's
  balance, which includes the `msg.value` of the `execute` call. `receive()`
  accepts plain transfers.
- If any call fails, `execute` reverts and the revert data of the failing
  call is bubbled up **unchanged**: a custom error stays that custom error, a
  string reason stays `Error(string)`, empty revert data stays empty. Nothing
  from earlier calls in the batch survives (EIP-5792 atomicity: all effects
  or none).
- After the last call, `execute` emits `BatchExecuted(nonce, calls.length)`:
  the consumed nonce for a signed batch, `type(uint256).max` for a direct
  (owner or self) execution. An empty batch is valid and emits with `0` calls.
- `execute` returns nothing, as the ERC interface says.

No external libraries in `starter.sol`.

## Before coding

1. The owner signs a batch for nonce 0; a target in that batch calls
   `execute` again with the same `executionData`. Write down the order of
   "check nonce, increment nonce, check signature, run calls" that makes the
   inner call fail with `InvalidNonce` rather than run twice, and what breaks
   if the increment moves after the loop.
2. Which bytes of `mode` are part of the signed digest? If a frontend sets
   the unused bytes `[10..31]` to something, does the signature still verify,
   and does `supportsExecutionMode` still say `true`?
3. A call reverts with `Boom(42)`. Which exact bytes must the outer `execute`
   revert with, and why is `revert("call failed")` or `require(ok)` wrong
   for a wallet that wants to show the user the reason?
4. `Call.to == address(0)` targets the executor itself. Which function of the
   executor can a signed batch therefore call, and what stops that from being
   an authorization bypass?
