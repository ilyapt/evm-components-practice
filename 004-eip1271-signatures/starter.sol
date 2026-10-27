// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice EIP-1271: a contract validates signatures on its own behalf.
interface IERC1271 {
    /// @dev Must return `0x1626ba7e` (the selector of this function) if `signature`
    /// is valid for `hash`, and any other value otherwise.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @notice Validates a signature for either an EOA (ECDSA) or a contract (EIP-1271).
/// See README.md for the full requirements.
contract SignatureChecker {
    /// @dev True iff `signature` is valid for `hash` on behalf of `signer`, right now.
    /// Never reverts because of the signer's behaviour.
    function isValidSignatureNow(address signer, bytes32 hash, bytes calldata signature)
        external
        view
        returns (bool)
    {
        signer;
        hash;
        signature;
        revert("TODO");
    }
}

/// @notice A minimal contract signer: accepts exactly the ECDSA signatures of its owner.
contract OwnedSigner is IERC1271 {
    constructor(address owner_) {
        owner_;
        revert("TODO");
    }

    function owner() external view returns (address) {
        revert("TODO");
    }

    /// @dev Returns `0x1626ba7e` iff `signature` is a valid ECDSA signature by `owner()`
    /// over `hash`; otherwise `0xffffffff`. Never reverts.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        hash;
        signature;
        revert("TODO");
    }
}
