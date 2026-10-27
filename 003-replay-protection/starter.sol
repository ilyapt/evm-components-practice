// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Relayed execution of signed intents, bound to a nonce, a deadline, the
/// chain, and this deployment. See README.md for the full requirements.
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

    string public constant NAME = "IntentExecutor";
    string public constant VERSION = "1";

    /// @dev The next nonce `signer` must use.
    function nonces(address signer) external view returns (uint256) {
        signer;
        revert("TODO");
    }

    function domainSeparator() public view returns (bytes32) {
        revert("TODO");
    }

    /// @dev EIP-712 `hashStruct` of an intent.
    function hashIntent(Intent calldata intent) public pure returns (bytes32) {
        intent;
        revert("TODO");
    }

    /// @dev Verifies `signature` by `signer` over the EIP-712 digest of `intent`, then
    /// performs the call exactly once. Returns the call's return data.
    function execute(Intent calldata intent, address signer, bytes calldata signature)
        external
        payable
        returns (bytes memory)
    {
        intent;
        signer;
        signature;
        revert("TODO");
    }

    /// @dev Invalidates the caller's current nonce so that an intent signed with it
    /// can never execute.
    function cancel(uint256 nonce) external {
        nonce;
        revert("TODO");
    }

    /// @dev Accepts ether that `execute` later forwards as `intent.value`.
    receive() external payable {}
}
