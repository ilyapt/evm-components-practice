// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Delegated4337Account} from "./starter.sol";

/// Records every call it receives, with the caller the EVM reports.
contract Delegated4337Recorder {
    struct Seen {
        address sender;
        uint256 value;
        bytes data;
    }

    Seen[] public seen;

    function count() external view returns (uint256) {
        return seen.length;
    }

    function get(uint256 i) external view returns (Seen memory) {
        return seen[i];
    }

    function ping(uint256 x) external payable returns (uint256) {
        seen.push(Seen(msg.sender, msg.value, msg.data));
        return x + 1;
    }

    function fail(string calldata reason) external pure {
        revert(reason);
    }

    fallback() external payable {
        seen.push(Seen(msg.sender, msg.value, msg.data));
    }

    receive() external payable {
        seen.push(Seen(msg.sender, msg.value, ""));
    }
}

/// Tests for task 027. Alice is a fresh EOA delegated to the implementation under
/// test; every operation goes through the real EntryPoint v0.8.
contract Eip7702AccountTest is Test {
    EntryPoint entryPoint;
    Delegated4337Account impl;
    Delegated4337Recorder recorder;
    address alice;
    uint256 aliceKey;
    address bob;
    uint256 bobKey;
    address payable beneficiary = payable(makeAddr("beneficiary"));
    address stranger = makeAddr("stranger");

    bytes constant MARKER = hex"7702";

    function setUp() public {
        entryPoint = new EntryPoint();
        impl = new Delegated4337Account(entryPoint);
        recorder = new Delegated4337Recorder();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.deal(alice, 10 ether);
    }

    // --- Helpers ---------------------------------------------------------------------

    function account() internal view returns (Delegated4337Account) {
        return Delegated4337Account(payable(alice));
    }

    function buildOp(address sender, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = entryPoint.getNonce(sender, 0);
        op.initCode = initCode;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(400_000) << 128) | 400_000);
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
    }

    function signOp(PackedUserOperation memory op, uint256 key)
        internal
        view
        returns (PackedUserOperation memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function pingCallData(uint256 x, uint256 value) internal view returns (bytes memory) {
        return abi.encodeCall(
            Delegated4337Account.execute,
            (address(recorder), value, abi.encodeCall(Delegated4337Recorder.ping, (x)))
        );
    }

    function failedOp(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason);
    }

    // --- Delegation and the EntryPoint ---------------------------------------------

    function test_DelegatedEoaReportsTheImplementationsEntryPoint() public view {
        assertEq(alice.code, abi.encodePacked(bytes3(0xef0100), address(impl)));
        // The immutable is part of the implementation's code, so the EOA sees it.
        assertEq(address(account().entryPoint()), address(entryPoint));
    }

    function test_OpSignedByTheEoaKeyExecutesAndTargetSeesTheEoa() public {
        handle(signOp(buildOp(alice, "", pingCallData(7, 1 ether)), aliceKey));

        assertEq(recorder.count(), 1);
        Delegated4337Recorder.Seen memory s = recorder.get(0);
        assertEq(
            s.sender, alice, "the target sees the EOA, not the EntryPoint or the implementation"
        );
        assertEq(s.value, 1 ether);
        assertEq(s.data, abi.encodeCall(Delegated4337Recorder.ping, (7)));
        assertEq(entryPoint.getNonce(alice, 0), 1, "nonce advanced");
    }

    function test_OpSignedByAnotherKeyFails() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), bobKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(recorder.count(), 0);
    }

    function test_MalformedSignatureIsReportedNotReverted() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = op.signature[i];
        }
        op.signature = short;
        // A revert inside validateUserOp would surface as "AA23 reverted"; the
        // account must return 1 instead so that bundlers can simulate.
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_ReplayFails() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey);
        handle(op);
        vm.expectRevert(failedOp("AA25 invalid account nonce"));
        handle(op);
        assertEq(recorder.count(), 1);
    }

    function test_OpAfterRevocationIsRejectedByTheEntryPoint() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey);
        vm.signAndAttachDelegation(address(0), aliceKey);
        assertEq(alice.code.length, 0);
        // The call to validateUserOp returns no data; the EntryPoint reports the
        // sender as not deployed.
        vm.expectRevert(failedOp("AA20 account not deployed"));
        handle(op);
    }

    // --- The 0x7702 initCode marker ---------------------------------------------------

    function test_MarkerInitCodeOpSucceeds() public {
        handle(signOp(buildOp(alice, MARKER, pingCallData(3, 0)), aliceKey));
        assertEq(recorder.count(), 1);
        assertEq(entryPoint.getNonce(alice, 0), 1);
    }

    function test_MarkerInitCodeBindsTheHashToTheDelegate() public {
        PackedUserOperation memory op = buildOp(alice, MARKER, pingCallData(3, 0));
        bytes32 real = entryPoint.getUserOpHash(op);
        assertEq(
            real,
            refHash(op, keccak256(abi.encodePacked(address(impl)))),
            "initCode hash is replaced by the delegate"
        );
        bytes32 naive = refHash(op, keccak256(op.initCode));
        assertNotEq(real, naive, "hashing the literal 0x7702 bytes gives a different hash");

        // A signature over the naive hash is a signature for nothing.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, naive);
        op.signature = abi.encodePacked(r, s, v);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_MarkerAndEmptyInitCodeAreBothAcceptedForTheSameAccount() public {
        handle(signOp(buildOp(alice, MARKER, pingCallData(1, 0)), aliceKey));
        handle(signOp(buildOp(alice, "", pingCallData(2, 0)), aliceKey));
        handle(signOp(buildOp(alice, MARKER, pingCallData(3, 0)), aliceKey));
        assertEq(recorder.count(), 3);
        assertEq(entryPoint.getNonce(alice, 0), 3);
    }

    function test_MarkerInitCodeWithoutDelegationIsRejectedByTheEntryPoint() public {
        vm.signAndAttachDelegation(address(0), aliceKey);
        PackedUserOperation memory op = buildOp(alice, MARKER, pingCallData(1, 0));
        op.signature = new bytes(65);
        // getUserOpHash itself reverts: the marker promises a delegated sender.
        vm.expectRevert(bytes("sender has no code"));
        entryPoint.getUserOpHash(op);
        vm.expectRevert(bytes("sender has no code"));
        handle(op);
    }

    function test_MarkerInitCodeFromAPlainContractIsRejectedByTheEntryPoint() public {
        // The standalone implementation has code, but not a delegation designator.
        PackedUserOperation memory op = buildOp(address(impl), MARKER, pingCallData(1, 0));
        op.signature = new bytes(65);
        vm.expectRevert(bytes("not an EIP-7702 delegate"));
        handle(op);
    }

    function test_MarkerInitCallDataIsNotRunByTheEntryPoint() public {
        // initCode = 0x7702 padded to 20 bytes, then calldata the EntryPoint sends to
        // the sender through its SenderCreator. That caller is neither the EntryPoint
        // nor the account itself, so execute must refuse it.
        bytes memory initCode = abi.encodePacked(bytes20(MARKER), pingCallData(9, 0));
        PackedUserOperation memory op =
            signOp(buildOp(alice, initCode, pingCallData(1, 0)), aliceKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector,
                0,
                "AA13 EIP7702 sender init failed",
                abi.encodeWithSelector(Delegated4337Account.NotAuthorized.selector)
            )
        );
        handle(op);
        assertEq(recorder.count(), 0);
    }

    // --- Prefund -----------------------------------------------------------------------

    function test_PrefundIsPaidFromTheEoaBalance() public {
        uint256 before = alice.balance;
        assertEq(entryPoint.balanceOf(alice), 0);
        handle(signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey));
        uint256 paid = before - alice.balance;
        assertGt(paid, 0, "the prefund left the EOA");
        assertEq(
            paid,
            entryPoint.balanceOf(alice) + beneficiary.balance,
            "prefund = what the bundler collected + what stayed on deposit"
        );
    }

    function test_ExistingDepositCoversThePrefund() public {
        entryPoint.depositTo{value: 1 ether}(alice);
        uint256 before = alice.balance;
        handle(signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey));
        assertEq(alice.balance, before, "missingAccountFunds was zero: nothing to pay");
        assertLt(entryPoint.balanceOf(alice), 1 ether, "gas came out of the deposit");
    }

    function test_UnpaidPrefundIsRejected() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey);
        vm.deal(alice, 0);
        vm.expectRevert(failedOp("AA21 didn't pay prefund"));
        handle(op);
    }

    // --- Direct access -------------------------------------------------------------------

    function test_ValidateUserOpOnlyFromEntryPoint() public {
        PackedUserOperation memory op = signOp(buildOp(alice, "", pingCallData(1, 0)), aliceKey);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(stranger);
        vm.expectRevert(Delegated4337Account.NotEntryPoint.selector);
        account().validateUserOp(op, h, 0);
        vm.prank(alice);
        vm.expectRevert(Delegated4337Account.NotEntryPoint.selector);
        account().validateUserOp(op, h, 0);
    }

    function test_SelfCallExecutesWithoutTheEntryPoint() public {
        vm.prank(alice);
        account()
            .execute(address(recorder), 2 ether, abi.encodeCall(Delegated4337Recorder.ping, (1)));
        assertEq(recorder.get(0).sender, alice);
        assertEq(recorder.get(0).value, 2 ether);
        assertEq(entryPoint.getNonce(alice, 0), 0, "no operation, no nonce");
    }

    function test_SelfCallExecuteBatchRunsInOrderAndRevertsWithIndex() public {
        Delegated4337Account.Call[] memory calls = new Delegated4337Account.Call[](2);
        calls[0] = Delegated4337Account.Call(
            address(recorder), 0, abi.encodeCall(Delegated4337Recorder.ping, (1))
        );
        calls[1] = Delegated4337Account.Call(
            address(recorder), 0, abi.encodeCall(Delegated4337Recorder.ping, (2))
        );
        vm.prank(alice);
        account().executeBatch(calls);
        assertEq(recorder.count(), 2);
        assertEq(recorder.get(1).data, abi.encodeCall(Delegated4337Recorder.ping, (2)));

        calls[1].data = abi.encodeCall(Delegated4337Recorder.fail, ("boom"));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Delegated4337Account.CallFailed.selector,
                1,
                abi.encodeWithSignature("Error(string)", "boom")
            )
        );
        account().executeBatch(calls);
        assertEq(recorder.count(), 2, "the batch is atomic");
    }

    function test_StrangerCannotExecute() public {
        vm.prank(stranger);
        vm.expectRevert(Delegated4337Account.NotAuthorized.selector);
        account().execute(address(recorder), 0, "");

        vm.prank(bob);
        vm.expectRevert(Delegated4337Account.NotAuthorized.selector);
        account().executeBatch(new Delegated4337Account.Call[](0));
    }

    function test_FailedExecutionStillConsumesTheNonceAndPaysGas() public {
        bytes memory callData = abi.encodeCall(
            Delegated4337Account.execute,
            (address(recorder), 0, abi.encodeCall(Delegated4337Recorder.fail, ("boom")))
        );
        uint256 before = alice.balance;
        handle(signOp(buildOp(alice, "", callData), aliceKey));
        assertEq(recorder.count(), 0);
        assertEq(entryPoint.getNonce(alice, 0), 1, "validation succeeded, execution reverted");
        assertLt(alice.balance, before, "gas was still paid");
    }

    function test_DelegatedEoaAcceptsEther() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = alice.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(alice.balance, 11 ether);
    }

    // --- Standalone implementation -------------------------------------------------------

    function test_StandaloneImplementationCannotValidate() public {
        vm.deal(address(impl), 1 ether);
        PackedUserOperation memory op = buildOp(address(impl), "", pingCallData(1, 0));
        bytes32 h = entryPoint.getUserOpHash(op);
        // Nobody holds the key of a contract address: every signature fails.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, h);
        op.signature = abi.encodePacked(r, s, v);
        vm.prank(address(entryPoint));
        assertEq(impl.validateUserOp(op, h, 0), 1);

        (v, r, s) = vm.sign(bobKey, h);
        op.signature = abi.encodePacked(r, s, v);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_StandaloneImplementationCannotExecute() public {
        vm.prank(stranger);
        vm.expectRevert(Delegated4337Account.NotAuthorized.selector);
        impl.execute(address(recorder), 0, "");
        vm.prank(alice);
        vm.expectRevert(Delegated4337Account.NotAuthorized.selector);
        impl.executeBatch(new Delegated4337Account.Call[](0));
    }

    // --- Fuzz --------------------------------------------------------------------------------

    function testFuzz_ExecuteForwardsArbitraryCalldataAndValue(bytes memory data, uint96 value)
        public
    {
        vm.deal(alice, uint256(value) + 1 ether);
        bytes memory callData =
            abi.encodeCall(Delegated4337Account.execute, (address(recorder), value, data));
        handle(signOp(buildOp(alice, "", callData), aliceKey));
        assertEq(recorder.count(), 1);
        Delegated4337Recorder.Seen memory s = recorder.get(0);
        assertEq(s.sender, alice);
        assertEq(s.value, value);
        assertEq(s.data, data);
    }

    function testFuzz_OnlyTheEoaKeyValidates(uint248 keySeed) public {
        uint256 key = uint256(keySeed) + 1;
        vm.assume(key != aliceKey);
        PackedUserOperation memory op = buildOp(alice, "", pingCallData(1, 0));
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        op.signature = abi.encodePacked(r, s, v);
        vm.prank(address(entryPoint));
        assertEq(account().validateUserOp(op, h, 0), 1);

        (v, r, s) = vm.sign(aliceKey, h);
        op.signature = abi.encodePacked(r, s, v);
        vm.prank(address(entryPoint));
        assertEq(account().validateUserOp(op, h, 0), 0);
    }

    // --- Independent hash of a PackedUserOperation (EntryPoint v0.8 typed data) ------------

    bytes32 constant PACKED_USEROP_TYPEHASH = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)"
    );

    function refHash(PackedUserOperation memory op, bytes32 initCodeHash)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                PACKED_USEROP_TYPEHASH,
                op.sender,
                op.nonce,
                initCodeHash,
                keccak256(op.callData),
                op.accountGasLimits,
                op.preVerificationGas,
                op.gasFees,
                keccak256(op.paymasterAndData)
            )
        );
        return
            keccak256(abi.encodePacked("\x19\x01", entryPoint.getDomainSeparatorV4(), structHash));
    }
}
