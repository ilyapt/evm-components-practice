// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Implementation contract for an EIP-7702 delegated EOA. See README.md for the
/// full requirements.
contract DelegatedAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotSelf();
    error NotAuthorized();
    error CallFailed(uint256 index, bytes returnData);

    event OperatorSet(address indexed operator, bool allowed);
    event Executed(address indexed by, uint256 calls);

    function isOperator(address who) external view returns (bool) {
        who;
        revert("TODO");
    }

    function setOperator(address operator, bool allowed) external {
        operator;
        allowed;
        revert("TODO");
    }

    function execute(Call[] calldata calls) external payable {
        calls;
        revert("TODO");
    }

    receive() external payable {}
}
