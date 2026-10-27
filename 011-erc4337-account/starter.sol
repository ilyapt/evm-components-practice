// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice A minimal single-owner ERC-4337 smart account for EntryPoint v0.8. See README.md
/// for the full requirements.
contract OwnerAccount is IAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotEntryPoint();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    constructor(IEntryPoint entryPoint_, address owner_) {
        entryPoint_;
        owner_;
        revert("TODO");
    }

    function entryPoint() external view returns (IEntryPoint) {
        revert("TODO");
    }

    function owner() external view returns (address) {
        revert("TODO");
    }

    /// @inheritdoc IAccount
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

    /// @notice Deposits `msg.value` into the EntryPoint for this account.
    function addDeposit() external payable {
        revert("TODO");
    }

    function getDeposit() external view returns (uint256) {
        revert("TODO");
    }

    function withdrawDepositTo(address payable to, uint256 amount) external {
        to;
        amount;
        revert("TODO");
    }

    // The correct body may well be empty; replace the revert.
    receive() external payable {
        revert("TODO");
    }
}
