// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {OwnerAccount} from "./starter.sol";

/// A call target that records what it was called with and can be told to fail.
contract CallTarget {
    error Boom(uint256 code);

    uint256 public counter;
    uint256[] public log;
    bytes public lastData;
    uint256 public lastValue;

    receive() external payable {}

    function increment() external {
        counter++;
        log.push(counter);
    }

    function logStep(uint256 step) external {
        log.push(step);
    }

    function record(bytes calldata data) external payable {
        lastData = data;
        lastValue = msg.value;
    }

    function fail(uint256 code) external pure {
        revert Boom(code);
    }

    function logLength() external view returns (uint256) {
        return log.length;
    }
}

/// Stands in for the EntryPoint in one test: it refuses the prefund transfer.
contract RefusingEntryPoint {
    receive() external payable {
        revert("no ether, thanks");
    }

    function callValidate(
        OwnerAccount account,
        PackedUserOperation calldata op,
        bytes32 hash,
        uint256 missing
    ) external returns (uint256) {
        return account.validateUserOp(op, hash, missing);
    }
}

/// Tests for task 011. Every operation goes through the real EntryPoint v0.8.
contract Erc4337AccountTest is Test {
    uint256 constant OWNER_KEY = 0xA11CE;
    uint256 constant STRANGER_KEY = 0xB0B;

    uint128 constant VERIFICATION_GAS = 200_000;
    uint128 constant CALL_GAS = 500_000;
    uint256 constant PRE_VERIFICATION_GAS = 50_000;
    uint128 constant MAX_FEE = 1 gwei;
    uint256 constant REQUIRED_PREFUND =
        (uint256(VERIFICATION_GAS) + CALL_GAS + PRE_VERIFICATION_GAS) * MAX_FEE;

    EntryPoint entryPoint;
    OwnerAccount account;
    CallTarget target;

    address owner = vm.addr(OWNER_KEY);
    address stranger = vm.addr(STRANGER_KEY);
    address payable beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        entryPoint = new EntryPoint();
        account = new OwnerAccount(entryPoint, owner);
        target = new CallTarget();
        vm.deal(address(account), 10 ether);
    }

    // --- Helpers ---------------------------------------------------------------

    function pack(uint128 high, uint128 low) internal pure returns (bytes32) {
        return bytes32((uint256(high) << 128) | uint256(low));
    }

    function buildOp(bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: entryPoint.getNonce(address(account), 0),
            initCode: "",
            callData: callData,
            accountGasLimits: pack(VERIFICATION_GAS, CALL_GAS),
            preVerificationGas: PRE_VERIFICATION_GAS,
            gasFees: pack(MAX_FEE, MAX_FEE),
            paymasterAndData: "",
            signature: ""
        });
    }

    function executeCall(address to, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(OwnerAccount.execute, (to, value, data));
    }

    function signOp(PackedUserOperation memory op, uint256 key) internal view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);
    }

    function signedOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = buildOp(callData);
        signOp(op, OWNER_KEY);
    }

    function handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function expectFailedOp(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason));
    }

    /// Finds the UserOperationEvent in recorded logs and returns its `success` flag.
    function userOpEventSuccess(Vm.Log[] memory logs, bytes32 userOpHash)
        internal
        pure
        returns (bool found, bool success)
    {
        bytes32 sig = keccak256(
            "UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].topics[1] == userOpHash) {
                (, success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return (true, success);
            }
        }
        return (false, false);
    }

    // --- Construction ------------------------------------------------------------

    function test_ExposesEntryPointAndOwner() public view {
        assertEq(address(account.entryPoint()), address(entryPoint));
        assertEq(account.owner(), owner);
    }

    function test_AccountReceivesEther() public {
        uint256 before = address(account).balance;
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok, "plain transfer must succeed");
        assertEq(address(account).balance, before + 1 ether);
    }

    // --- The happy path through the EntryPoint ----------------------------------

    function test_SignedOpExecutesCallAndConsumesNonce() public {
        PackedUserOperation memory op =
            signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ())));
        assertEq(entryPoint.getNonce(address(account), 0), 0);

        vm.recordLogs();
        handle(op);

        assertEq(target.counter(), 1, "call executed");
        assertEq(entryPoint.getNonce(address(account), 0), 1, "nonce consumed");
        (bool found, bool success) =
            userOpEventSuccess(vm.getRecordedLogs(), entryPoint.getUserOpHash(op));
        assertTrue(found, "UserOperationEvent emitted");
        assertTrue(success, "success flag");
    }

    function test_OpCanSendValueWithTheCall() public {
        PackedUserOperation memory op = signedOp(
            executeCall(address(target), 1 ether, abi.encodeCall(CallTarget.record, (hex"1234")))
        );
        handle(op);
        assertEq(address(target).balance, 1 ether);
        assertEq(target.lastValue(), 1 ether);
        assertEq(target.lastData(), hex"1234");
    }

    function test_RevertingCallDataDoesNotRevertHandleOpsAndLeavesStateUnchanged() public {
        PackedUserOperation memory op =
            signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.fail, (7))));
        uint256 balanceBefore = address(account).balance;

        vm.recordLogs();
        handle(op); // must not revert: the EntryPoint reports failure through the event

        (bool found, bool success) =
            userOpEventSuccess(vm.getRecordedLogs(), entryPoint.getUserOpHash(op));
        assertTrue(found, "UserOperationEvent emitted");
        assertFalse(success, "success flag must be false");
        assertEq(target.counter(), 0, "target untouched");
        assertEq(entryPoint.getNonce(address(account), 0), 1, "nonce is consumed even on failure");
        assertLt(address(account).balance, balanceBefore, "gas is still paid");
    }

    // --- Signature validation ----------------------------------------------------

    function test_WrongSignerIsRejectedWithAA24() public {
        PackedUserOperation memory op =
            buildOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ())));
        signOp(op, STRANGER_KEY);
        expectFailedOp("AA24 signature error");
        handle(op);
        assertEq(target.counter(), 0);
    }

    function test_PersonalSignPrefixedSignatureIsRejected() public {
        // A common mistake on the account side: verifying a "\x19Ethereum Signed Message" digest.
        // v0.8 user operation hashes are already EIP-712 typed; the owner signs them directly.
        PackedUserOperation memory op =
            buildOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ())));
        bytes32 prefixed = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", entryPoint.getUserOpHash(op))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, prefixed);
        op.signature = abi.encodePacked(r, s, v);
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    function test_MalformedSignatureIsAA24NotAA23() public {
        // A validateUserOp that reverts on a short or long signature surfaces as
        // FailedOpWithRevert("AA23 reverted"). The account must report it as a signature failure.
        bytes memory callData =
            executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ()));

        PackedUserOperation memory op = buildOp(callData);
        op.signature = "";
        expectFailedOp("AA24 signature error");
        handle(op);

        op = signedOp(callData);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = op.signature[i];
        }
        op.signature = short;
        expectFailedOp("AA24 signature error");
        handle(op);

        op = signedOp(callData);
        op.signature = abi.encodePacked(op.signature, uint8(1));
        expectFailedOp("AA24 signature error");
        handle(op);

        op = signedOp(callData);
        op.signature[64] = bytes1(uint8(29)); // ecrecover returns address(0) for this v
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    function test_ValidateUserOpReturnsZeroForOwnerAndOneForOthers() public {
        PackedUserOperation memory op = signedOp("");
        bytes32 hash = entryPoint.getUserOpHash(op);

        vm.prank(address(entryPoint));
        assertEq(account.validateUserOp(op, hash, 0), 0, "owner signature");

        signOp(op, STRANGER_KEY);
        vm.prank(address(entryPoint));
        assertEq(account.validateUserOp(op, hash, 0), 1, "stranger signature");
    }

    function testFuzz_OnlyTheOwnerKeyValidates(uint256 key) public {
        key = bound(key, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        PackedUserOperation memory op = buildOp("");
        bytes32 hash = entryPoint.getUserOpHash(op);
        signOp(op, key);
        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(op, hash, 0);
        assertEq(validationData, key == OWNER_KEY ? 0 : 1);
    }

    function test_ValidateUserOpFromStrangerReverts() public {
        PackedUserOperation memory op = signedOp("");
        bytes32 hash = entryPoint.getUserOpHash(op);

        vm.prank(stranger);
        vm.expectRevert(OwnerAccount.NotEntryPoint.selector);
        account.validateUserOp(op, hash, 0);

        // Not even the owner: validation is the EntryPoint's call.
        vm.prank(owner);
        vm.expectRevert(OwnerAccount.NotEntryPoint.selector);
        account.validateUserOp(op, hash, 0);
    }

    // --- Prefund -----------------------------------------------------------------

    function test_PrefundIsPaidFromAccountBalanceWhenDepositIsEmpty() public {
        assertEq(account.getDeposit(), 0);
        uint256 balanceBefore = address(account).balance;
        uint256 beneficiaryBefore = beneficiary.balance;

        handle(signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ()))));

        uint256 actualGasCost = beneficiary.balance - beneficiaryBefore;
        assertGt(actualGasCost, 0);
        assertEq(
            balanceBefore - address(account).balance,
            REQUIRED_PREFUND,
            "exactly the prefund left the account"
        );
        assertEq(
            account.getDeposit(),
            REQUIRED_PREFUND - actualGasCost,
            "the unused part stays as deposit"
        );
    }

    function test_ExistingDepositCoversPrefundWithoutTouchingBalance() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger); // anyone may top up the deposit
        account.addDeposit{value: 1 ether}();
        assertEq(account.getDeposit(), 1 ether);

        uint256 balanceBefore = address(account).balance;
        uint256 beneficiaryBefore = beneficiary.balance;

        handle(signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ()))));

        uint256 actualGasCost = beneficiary.balance - beneficiaryBefore;
        assertEq(address(account).balance, balanceBefore, "balance untouched");
        assertEq(account.getDeposit(), 1 ether - actualGasCost, "deposit pays");
    }

    function test_OnlyTheMissingPartOfThePrefundIsPaid() public {
        uint256 existing = REQUIRED_PREFUND / 3;
        account.addDeposit{value: existing}();
        uint256 balanceBefore = address(account).balance;

        handle(signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ()))));

        assertEq(
            balanceBefore - address(account).balance,
            REQUIRED_PREFUND - existing,
            "only the shortfall is paid"
        );
    }

    function test_AccountWithoutFundsFailsWithAA21NotAA23() public {
        // The transfer to the EntryPoint fails for lack of balance. The account must not turn
        // that into a revert: the EntryPoint diagnoses the missing prefund itself.
        vm.deal(address(account), 0);
        PackedUserOperation memory op =
            signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ())));
        expectFailedOp("AA21 didn't pay prefund");
        handle(op);
    }

    function test_PrefundTransferFailureDoesNotRevertValidation() public {
        RefusingEntryPoint refusing = new RefusingEntryPoint();
        OwnerAccount bound_ = new OwnerAccount(IEntryPoint(address(refusing)), owner);
        vm.deal(address(bound_), 1 ether);

        PackedUserOperation memory op = buildOp("");
        op.sender = address(bound_);
        bytes32 hash = keccak256("any hash");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_KEY, hash);
        op.signature = abi.encodePacked(r, s, v);

        uint256 validationData = refusing.callValidate(bound_, op, hash, 0.1 ether);
        assertEq(validationData, 0, "validation result is independent of the transfer");
        assertEq(address(bound_).balance, 1 ether, "nothing left the account");
    }

    // --- Nonces ------------------------------------------------------------------

    function test_ReplayOfTheSameSignedOpFailsOnNonce() public {
        PackedUserOperation memory op =
            signedOp(executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ())));
        handle(op);
        assertEq(target.counter(), 1);

        expectFailedOp("AA25 invalid account nonce");
        handle(op);
        assertEq(target.counter(), 1, "not executed twice");
    }

    function test_SequentialOpsUseConsecutiveNonces() public {
        bytes memory callData =
            executeCall(address(target), 0, abi.encodeCall(CallTarget.increment, ()));
        handle(signedOp(callData));
        handle(signedOp(callData));
        handle(signedOp(callData));
        assertEq(target.counter(), 3);
        assertEq(entryPoint.getNonce(address(account), 0), 3);
    }

    // --- Execution authorization -------------------------------------------------

    function test_ExecuteByStrangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(OwnerAccount.NotAuthorized.selector);
        account.execute(address(target), 0, abi.encodeCall(CallTarget.increment, ()));

        OwnerAccount.Call[] memory calls = new OwnerAccount.Call[](1);
        calls[0] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.increment, ()));
        vm.prank(stranger);
        vm.expectRevert(OwnerAccount.NotAuthorized.selector);
        account.executeBatch(calls);
        assertEq(target.counter(), 0);
    }

    function test_OwnerCanExecuteDirectly() public {
        vm.prank(owner);
        account.execute(address(target), 0.5 ether, abi.encodeCall(CallTarget.record, (hex"beef")));
        assertEq(target.lastData(), hex"beef");
        assertEq(target.lastValue(), 0.5 ether);
        assertEq(address(target).balance, 0.5 ether);
    }

    function test_ExecuteBubblesRevertDataWithIndexZero() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnerAccount.CallFailed.selector,
                0,
                abi.encodeWithSelector(CallTarget.Boom.selector, 42)
            )
        );
        account.execute(address(target), 0, abi.encodeCall(CallTarget.fail, (42)));
    }

    function test_ExecuteBatchRunsInOrder() public {
        OwnerAccount.Call[] memory calls = new OwnerAccount.Call[](3);
        calls[0] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.logStep, (10)));
        calls[1] = OwnerAccount.Call(
            address(target), 0.25 ether, abi.encodeCall(CallTarget.record, (hex"aa"))
        );
        calls[2] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.logStep, (30)));

        handle(signedOp(abi.encodeCall(OwnerAccount.executeBatch, (calls))));

        assertEq(target.logLength(), 2);
        assertEq(target.log(0), 10);
        assertEq(target.log(1), 30);
        assertEq(target.lastValue(), 0.25 ether);
        assertEq(target.lastData(), hex"aa");
    }

    function test_ExecuteBatchBubblesTheFailingIndexAndIsAtomic() public {
        OwnerAccount.Call[] memory calls = new OwnerAccount.Call[](3);
        calls[0] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.increment, ()));
        calls[1] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.fail, (99)));
        calls[2] = OwnerAccount.Call(address(target), 0, abi.encodeCall(CallTarget.increment, ()));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnerAccount.CallFailed.selector,
                1,
                abi.encodeWithSelector(CallTarget.Boom.selector, 99)
            )
        );
        account.executeBatch(calls);
        assertEq(target.counter(), 0, "the first call must be rolled back");

        // Through the EntryPoint the same batch is reported as a failed op, not as a revert.
        vm.recordLogs();
        PackedUserOperation memory op = signedOp(abi.encodeCall(OwnerAccount.executeBatch, (calls)));
        handle(op);
        (, bool success) = userOpEventSuccess(vm.getRecordedLogs(), entryPoint.getUserOpHash(op));
        assertFalse(success);
        assertEq(target.counter(), 0);
    }

    function test_EmptyBatchIsANoOp() public {
        vm.prank(owner);
        account.executeBatch(new OwnerAccount.Call[](0));
    }

    function testFuzz_ExecuteForwardsArbitraryCalldataAndValue(bytes memory data, uint256 value)
        public
    {
        value = bound(value, 0, 1 ether);
        PackedUserOperation memory op = signedOp(
            executeCall(address(target), value, abi.encodeCall(CallTarget.record, (data)))
        );
        handle(op);
        assertEq(target.lastData(), data);
        assertEq(target.lastValue(), value);
        assertEq(address(target).balance, value);
    }

    // --- Deposit management -----------------------------------------------------

    function test_OwnerCanWithdrawDeposit() public {
        account.addDeposit{value: 2 ether}();
        address payable to = payable(makeAddr("recipient"));

        vm.prank(owner);
        account.withdrawDepositTo(to, 1.5 ether);

        assertEq(to.balance, 1.5 ether);
        assertEq(account.getDeposit(), 0.5 ether);
    }

    function test_StrangerCannotWithdrawDeposit() public {
        account.addDeposit{value: 2 ether}();
        vm.prank(stranger);
        vm.expectRevert(OwnerAccount.NotAuthorized.selector);
        account.withdrawDepositTo(payable(stranger), 1 ether);
        assertEq(account.getDeposit(), 2 ether);
    }

    function test_GetDepositReflectsTheEntryPointBalance() public {
        assertEq(account.getDeposit(), entryPoint.balanceOf(address(account)));
        account.addDeposit{value: 0.3 ether}();
        assertEq(account.getDeposit(), 0.3 ether);
        assertEq(entryPoint.balanceOf(address(account)), 0.3 ether);
    }
}
