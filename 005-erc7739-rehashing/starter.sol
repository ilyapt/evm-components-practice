// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Smart account with an EOA owner that implements EIP-1271 with the ERC-7739
/// defensive rehashing scheme (TypedDataSign and PersonalSign workflows). See README.md
/// for the full requirements and the exact byte layouts.
contract Erc7739Account {
    string public constant NAME = "Erc7739Account";
    string public constant VERSION = "1";

    /// @dev EIP-1271 return values.
    bytes4 public constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 public constant ERC1271_FAIL = 0xffffffff;

    /// @dev ERC-7739 support detection: `isValidSignature(ERC7739_DETECTION_HASH, "")`
    /// returns `ERC7739_MAGIC`.
    bytes32 public constant ERC7739_DETECTION_HASH =
        0x7739773977397739773977397739773977397739773977397739773977397739;
    bytes4 public constant ERC7739_MAGIC = 0x77390001;

    constructor(address owner_) {
        owner_;
        revert("TODO");
    }

    function owner() external view returns (address) {
        revert("TODO");
    }

    /// @notice ERC-5267 domain discovery.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        (fields, name, version, chainId, verifyingContract, salt, extensions);
        revert("TODO");
    }

    /// @notice EIP-1271 with ERC-7739 semantics. Never reverts on malformed input.
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
