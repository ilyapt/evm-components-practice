// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ECDSA recovery without the classic footguns: signature forms, malleable
/// `s`, zero-address results, and EIP-191 prefixing. See README.md for the full
/// requirements.
contract SignatureVerifier {
    error InvalidSignature();

    /// @dev Recovers the signer of `digest` from a 65-byte `r ‖ s ‖ v` or a 64-byte
    /// EIP-2098 `r ‖ yParityAndS` signature. Reverts with `InvalidSignature` on
    /// any malformed or malleable input.
    function recover(bytes32 digest, bytes calldata signature) public pure returns (address) {
        digest;
        signature;
        revert("TODO");
    }

    /// @dev Same as above for an already split signature.
    function recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) public pure returns (address) {
        digest;
        v;
        r;
        s;
        revert("TODO");
    }

    /// @dev Never reverts: false on any malformed signature or when the signer is
    /// not `expected`.
    function isValid(bytes32 digest, bytes calldata signature, address expected)
        external
        pure
        returns (bool)
    {
        digest;
        signature;
        expected;
        revert("TODO");
    }

    /// @dev EIP-191 version 0x45 digest of a 32-byte hash.
    function toEthSignedMessageHash(bytes32 hash) public pure returns (bytes32) {
        hash;
        revert("TODO");
    }

    /// @dev EIP-191 version 0x45 digest of an arbitrary-length message.
    function toEthSignedMessageHash(bytes calldata message) public pure returns (bytes32) {
        message;
        revert("TODO");
    }
}
