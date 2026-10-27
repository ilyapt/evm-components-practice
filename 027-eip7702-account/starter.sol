// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice ERC-4337 account implementation meant to be the EIP-7702 delegate of an EOA.
/// See README.md for the full requirements.
contract Delegated4337Account is IAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotEntryPoint();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    constructor(IEntryPoint entryPoint_) {
        entryPoint_;
    }

    function entryPoint() public view returns (IEntryPoint) {
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
