// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Single-owner ERC-4337 account with scoped session keys. See README.md for the
/// full requirements.
contract SessionKeyAccount is IAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

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

    constructor(IEntryPoint entryPoint_, address owner_) {
        entryPoint_;
        owner_;
    }

    function entryPoint() external view returns (IEntryPoint) {
        revert("TODO");
    }

    function owner() external view returns (address) {
        revert("TODO");
    }

    function sessions(address key) external view returns (Session memory) {
        key;
        revert("TODO");
    }

    function grantSession(address key, Session calldata session) external {
        key;
        session;
        revert("TODO");
    }

    function revokeSession(address key) external {
        key;
        revert("TODO");
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        userOp;
        userOpHash;
        missingAccountFunds;
        validationData;
        revert("TODO");
    }

    function execute(address target, uint256 value, bytes calldata data) external {
        target;
        value;
        data;
        revert("TODO");
    }

    function executeBatch(Call[] calldata calls) external {
        calls;
        revert("TODO");
    }

    receive() external payable {}
}
