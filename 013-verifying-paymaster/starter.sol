// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice A paymaster that sponsors operations approved off-chain by a signer, for
/// EntryPoint v0.8. See README.md for the full requirements.
contract SponsorPaymaster is IPaymaster {
    error NotEntryPoint();
    error NotOwner();
    error InvalidPaymasterData();

    event Sponsored(bytes32 indexed userOpHash, address indexed sender, uint256 actualGasCost);

    constructor(IEntryPoint entryPoint_, address owner_, address signer_) {
        entryPoint_;
        owner_;
        signer_;
        revert("TODO");
    }

    function entryPoint() external view returns (IEntryPoint) {
        revert("TODO");
    }

    function owner() external view returns (address) {
        revert("TODO");
    }

    function signer() external view returns (address) {
        revert("TODO");
    }

    function setSigner(address newSigner) external {
        newSigner;
        revert("TODO");
    }

    /// @notice The hash the sponsor signs for `userOp` with the given validity window.
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        userOp;
        validUntil;
        validAfter;
        revert("TODO");
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        userOp;
        userOpHash;
        maxCost;
        context;
        validationData;
        revert("TODO");
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        mode;
        context;
        actualGasCost;
        actualUserOpFeePerGas;
        revert("TODO");
    }

    /// @notice Deposits `msg.value` into the EntryPoint for this paymaster. Anyone may call it.
    function deposit() external payable {
        revert("TODO");
    }

    function withdrawTo(address payable to, uint256 amount) external {
        to;
        amount;
        revert("TODO");
    }

    function addStake(uint32 unstakeDelaySec) external payable {
        unstakeDelaySec;
        revert("TODO");
    }

    function unlockStake() external {
        revert("TODO");
    }

    function withdrawStake(address payable to) external {
        to;
        revert("TODO");
    }
}
