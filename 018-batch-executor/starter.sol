// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal ERC-7821 batch executor with owner, self and signature-authorized
/// batches. See README.md for the full requirements, the mode layout and the digest.
contract BatchExecutor {
    struct Call {
        address to; // Replaced with address(this) if address(0).
        uint256 value;
        bytes data;
    }

    error UnsupportedExecutionMode();
    error Unauthorized();
    error InvalidNonce();
    error InvalidSignature();

    /// @dev `nonce` is the consumed nonce for a signed batch, DIRECT_EXECUTION_NONCE otherwise.
    event BatchExecuted(uint256 indexed nonce, uint256 calls);

    string public constant NAME = "BatchExecutor";
    string public constant VERSION = "1";

    /// @dev Canonical values of the two supported modes (bytes [2..5] and [10..31] are ignored).
    bytes32 public constant MODE_SINGLE_BATCH =
        0x0100000000000000000000000000000000000000000000000000000000000000;
    bytes32 public constant MODE_SINGLE_BATCH_OPDATA =
        0x0100000000007821000100000000000000000000000000000000000000000000;

    uint256 public constant DIRECT_EXECUTION_NONCE = type(uint256).max;

    constructor(address owner_) {
        owner_;
        revert("TODO");
    }

    receive() external payable {}

    function owner() external view returns (address) {
        revert("TODO");
    }

    function nonce() external view returns (uint256) {
        revert("TODO");
    }

    function supportsExecutionMode(bytes32 mode) external view returns (bool) {
        mode;
        revert("TODO");
    }

    function execute(bytes32 mode, bytes calldata executionData) external payable {
        mode;
        executionData;
        revert("TODO");
    }

    function domainSeparator() public view returns (bytes32) {
        revert("TODO");
    }
}
