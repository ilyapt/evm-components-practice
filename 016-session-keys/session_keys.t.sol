// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SessionKeyAccount} from "./starter.sol";

/// Records every call it receives, with the caller the EVM reports.
contract SessionRecorder {
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

    function pong() external payable {
        seen.push(Seen(msg.sender, msg.value, msg.data));
    }

    function fail(string calldata reason) external pure {
        revert(reason);
    }

    receive() external payable {
        seen.push(Seen(msg.sender, msg.value, ""));
    }
}

/// Tests for task 016. Every operation goes through the real EntryPoint v0.8.
contract SessionKeysTest is Test {
    EntryPoint entryPoint;
    SessionKeyAccount account;
    SessionRecorder recorder;
    SessionRecorder other;
    address owner;
    uint256 ownerKey;
    address dapp;
    uint256 dappKey;
    address dapp2;
    uint256 dapp2Key;
    address stranger = makeAddr("stranger");
    address payable beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        entryPoint = new EntryPoint();
        (owner, ownerKey) = makeAddrAndKey("owner");
        (dapp, dappKey) = makeAddrAndKey("dapp");
        (dapp2, dapp2Key) = makeAddrAndKey("dapp2");
        account = new SessionKeyAccount(entryPoint, owner);
        recorder = new SessionRecorder();
        other = new SessionRecorder();
        vm.deal(address(account), 10 ether);
        vm.warp(1_700_000_000);
    }

    // --- Helpers ---------------------------------------------------------------------

    function pingSession(uint256 maxValue, uint48 validAfter, uint48 validUntil)
        internal
        view
        returns (SessionKeyAccount.Session memory)
    {
        return SessionKeyAccount.Session({
            target: address(recorder),
            selector: SessionRecorder.ping.selector,
            maxValuePerCall: maxValue,
            validAfter: validAfter,
            validUntil: validUntil
        });
    }

    function grant(address key, SessionKeyAccount.Session memory s) internal {
        vm.prank(owner);
        account.grantSession(key, s);
    }

    function buildOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op.sender = address(account);
        op.nonce = entryPoint.getNonce(address(account), 0);
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(500_000) << 128) | 500_000);
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

    function executeCallData(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(SessionKeyAccount.execute, (target, value, data));
    }

    function pingCallData(uint256 value) internal view returns (bytes memory) {
        return executeCallData(address(recorder), value, abi.encodeCall(SessionRecorder.ping, (1)));
    }

    function failedOp(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason);
    }

    function packedWindow(uint48 validAfter, uint48 validUntil) internal pure returns (uint256) {
        return (uint256(validAfter) << 208) | (uint256(validUntil) << 160);
    }

    // --- Base account: owner path ---------------------------------------------------

    function test_OwnerOpExecutesCall() public {
        handle(signOp(buildOp(pingCallData(1 ether)), ownerKey));
        assertEq(recorder.count(), 1);
        assertEq(recorder.get(0).sender, address(account));
        assertEq(recorder.get(0).value, 1 ether);
        assertEq(entryPoint.getNonce(address(account), 0), 1);
    }

    function test_OwnerOpExecutesBatch() public {
        SessionKeyAccount.Call[] memory calls = new SessionKeyAccount.Call[](2);
        calls[0] =
            SessionKeyAccount.Call(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        calls[1] = SessionKeyAccount.Call(
            address(other), 0.5 ether, abi.encodeCall(SessionRecorder.pong, ())
        );
        handle(signOp(buildOp(abi.encodeCall(SessionKeyAccount.executeBatch, (calls))), ownerKey));
        assertEq(recorder.count(), 1);
        assertEq(other.count(), 1);
        assertEq(other.get(0).value, 0.5 ether);
    }

    function test_UnknownSignerFails() public {
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dapp2Key);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_MalformedSignatureIsReportedNotReverted() public {
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), ownerKey);
        op.signature = new bytes(64);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_ReplayFails() public {
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), ownerKey);
        handle(op);
        vm.expectRevert(failedOp("AA25 invalid account nonce"));
        handle(op);
    }

    function test_ValidateUserOpOnlyFromEntryPoint() public {
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), ownerKey);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(owner);
        vm.expectRevert(SessionKeyAccount.NotEntryPoint.selector);
        account.validateUserOp(op, h, 0);
        vm.prank(stranger);
        vm.expectRevert(SessionKeyAccount.NotEntryPoint.selector);
        account.validateUserOp(op, h, 0);
    }

    function test_ExecuteOnlyFromEntryPointOrOwner() public {
        vm.prank(owner);
        account.execute(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        assertEq(recorder.count(), 1);

        vm.prank(stranger);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.execute(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));

        // A session key is only a signer for operations, never a direct caller.
        grant(dapp, pingSession(1 ether, 0, 0));
        vm.prank(dapp);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.execute(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        vm.prank(dapp);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.executeBatch(new SessionKeyAccount.Call[](0));
    }

    function test_PrefundIsPaidFromTheAccountBalance() public {
        uint256 before = address(account).balance;
        assertEq(entryPoint.balanceOf(address(account)), 0);
        handle(signOp(buildOp(pingCallData(0)), ownerKey));
        uint256 paid = before - address(account).balance;
        assertGt(paid, 0);
        assertEq(paid, entryPoint.balanceOf(address(account)) + beneficiary.balance);
    }

    function test_UnpaidPrefundIsRejected() public {
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), ownerKey);
        vm.deal(address(account), 0);
        vm.expectRevert(failedOp("AA21 didn't pay prefund"));
        handle(op);
    }

    function test_FailingCallRevertsTheBatchWithIndexAndReason() public {
        SessionKeyAccount.Call[] memory calls = new SessionKeyAccount.Call[](2);
        calls[0] =
            SessionKeyAccount.Call(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        calls[1] = SessionKeyAccount.Call(
            address(recorder), 0, abi.encodeCall(SessionRecorder.fail, ("boom"))
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                SessionKeyAccount.CallFailed.selector,
                1,
                abi.encodeWithSignature("Error(string)", "boom")
            )
        );
        account.executeBatch(calls);
        assertEq(recorder.count(), 0);
    }

    function test_AccountAcceptsEther() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(account).balance, 11 ether);
    }

    function test_GettersReportConstructorArguments() public view {
        assertEq(address(account.entryPoint()), address(entryPoint));
        assertEq(account.owner(), owner);
    }

    // --- Session management ---------------------------------------------------------

    function test_OwnerGrantsAndRevokesAndTheGetterFollows() public {
        SessionKeyAccount.Session memory s = pingSession(1 ether, 10, 20);
        SessionKeyAccount.Session memory empty = account.sessions(dapp);
        assertEq(empty.target, address(0));

        vm.expectEmit(true, false, false, true, address(account));
        emit SessionKeyAccount.SessionGranted(dapp, s);
        grant(dapp, s);

        SessionKeyAccount.Session memory got = account.sessions(dapp);
        assertEq(got.target, address(recorder));
        assertEq(got.selector, SessionRecorder.ping.selector);
        assertEq(got.maxValuePerCall, 1 ether);
        assertEq(got.validAfter, 10);
        assertEq(got.validUntil, 20);

        vm.expectEmit(true, false, false, true, address(account));
        emit SessionKeyAccount.SessionRevoked(dapp);
        vm.prank(owner);
        account.revokeSession(dapp);

        got = account.sessions(dapp);
        assertEq(got.target, address(0), "cleared");
        assertEq(got.selector, bytes4(0));
        assertEq(got.maxValuePerCall, 0);
        assertEq(got.validAfter, 0);
        assertEq(got.validUntil, 0);
    }

    function test_GrantOverwritesAnExistingSession() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        grant(dapp, pingSession(2 ether, 5, 0));
        assertEq(account.sessions(dapp).maxValuePerCall, 2 ether);
        assertEq(account.sessions(dapp).validAfter, 5);
    }

    function test_GrantRejectsAWindowThatEndsBeforeItStarts() public {
        vm.prank(owner);
        vm.expectRevert(SessionKeyAccount.InvalidSession.selector);
        account.grantSession(dapp, pingSession(1 ether, 20, 10));

        vm.prank(owner);
        vm.expectRevert(SessionKeyAccount.InvalidSession.selector);
        account.grantSession(dapp, pingSession(1 ether, 20, 20));
    }

    function test_GrantAcceptsNoExpiryWithALaterStart() public {
        grant(dapp, pingSession(1 ether, 20, 0));
        assertEq(account.sessions(dapp).validUntil, 0);
    }

    function test_GrantRejectsTheAccountItselfAsTarget() public {
        SessionKeyAccount.Session memory s = pingSession(0, 0, 0);
        s.target = address(account);
        s.selector = SessionKeyAccount.grantSession.selector;
        vm.prank(owner);
        vm.expectRevert(SessionKeyAccount.InvalidSession.selector);
        account.grantSession(dapp, s);
    }

    function test_GrantRejectsTheZeroTarget() public {
        SessionKeyAccount.Session memory s = pingSession(0, 0, 0);
        s.target = address(0);
        vm.prank(owner);
        vm.expectRevert(SessionKeyAccount.InvalidSession.selector);
        account.grantSession(dapp, s);
    }

    function test_StrangerCannotGrantOrRevoke() public {
        vm.prank(stranger);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.grantSession(stranger, pingSession(1 ether, 0, 0));

        grant(dapp, pingSession(1 ether, 0, 0));
        vm.prank(stranger);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.revokeSession(dapp);
        assertEq(account.sessions(dapp).target, address(recorder));
    }

    function test_SessionKeyCannotGrantOrRevokeDirectly() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        vm.prank(dapp);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.grantSession(dapp2, pingSession(1 ether, 0, 0));
        vm.prank(dapp);
        vm.expectRevert(SessionKeyAccount.NotAuthorized.selector);
        account.revokeSession(dapp);
    }

    function test_OwnerGrantsThroughAnOperationThatCallsTheAccount() public {
        bytes memory inner =
            abi.encodeCall(SessionKeyAccount.grantSession, (dapp, pingSession(1 ether, 0, 0)));
        handle(signOp(buildOp(executeCallData(address(account), 0, inner)), ownerKey));
        assertEq(account.sessions(dapp).target, address(recorder), "granted by the account itself");

        handle(signOp(buildOp(pingCallData(0.5 ether)), dappKey));
        assertEq(recorder.count(), 1);
    }

    function test_OwnerRevokesThroughAnOperationThatCallsTheAccount() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        bytes memory inner = abi.encodeCall(SessionKeyAccount.revokeSession, (dapp));
        handle(signOp(buildOp(executeCallData(address(account), 0, inner)), ownerKey));
        assertEq(account.sessions(dapp).target, address(0));
    }

    // --- Session validation -------------------------------------------------------------

    function test_SessionOpWithinScopeSucceeds() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        handle(signOp(buildOp(pingCallData(1 ether)), dappKey));
        assertEq(recorder.count(), 1);
        assertEq(recorder.get(0).sender, address(account), "calls still come from the account");
        assertEq(recorder.get(0).value, 1 ether, "value == maxValuePerCall is allowed");
        assertEq(entryPoint.getNonce(address(account), 0), 1);
    }

    function test_SessionOpWithWrongSelectorFails() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        bytes memory callData =
            executeCallData(address(recorder), 0, abi.encodeCall(SessionRecorder.pong, ()));
        PackedUserOperation memory op = signOp(buildOp(callData), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(recorder.count(), 0);
    }

    function test_SessionOpWithWrongTargetFails() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        bytes memory callData =
            executeCallData(address(other), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        PackedUserOperation memory op = signOp(buildOp(callData), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(other.count(), 0);
    }

    function test_SessionOpWithValueAboveTheLimitFails() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(1 ether + 1)), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_SessionOpWithShortDataDoesNotMatchAnySelector() public {
        // A session whose selector is 0x00000000 must not match a plain transfer.
        SessionKeyAccount.Session memory s = pingSession(1 ether, 0, 0);
        s.selector = bytes4(0);
        grant(dapp, s);
        PackedUserOperation memory op =
            signOp(buildOp(executeCallData(address(recorder), 1 ether, "")), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        op = signOp(buildOp(executeCallData(address(recorder), 1 ether, hex"000000")), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_SessionOpBeforeValidAfterFails() public {
        uint48 start = uint48(block.timestamp + 1 hours);
        grant(dapp, pingSession(1 ether, start, 0));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dappKey);
        vm.expectRevert(failedOp("AA22 expired or not due"));
        handle(op);

        // The EntryPoint treats validAfter as exclusive: at exactly validAfter it is not yet due.
        vm.warp(start);
        vm.expectRevert(failedOp("AA22 expired or not due"));
        handle(op);

        vm.warp(start + 1);
        handle(op);
        assertEq(recorder.count(), 1);
    }

    function test_SessionOpAfterValidUntilFails() public {
        uint48 end = uint48(block.timestamp + 1 hours);
        grant(dapp, pingSession(1 ether, 0, end));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dappKey);

        vm.warp(end + 1);
        vm.expectRevert(failedOp("AA22 expired or not due"));
        handle(op);

        // validUntil is inclusive.
        vm.warp(end);
        handle(op);
        assertEq(recorder.count(), 1);
    }

    function test_SessionWithNoExpiryWorksFarInTheFuture() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        vm.warp(type(uint48).max - 1);
        handle(signOp(buildOp(pingCallData(0)), dappKey));
        assertEq(recorder.count(), 1);
    }

    function test_ValidationDataPacksTheWindowAndNothingElse() public {
        grant(dapp, pingSession(1 ether, 10, 20));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dappKey);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        assertEq(
            account.validateUserOp(op, h, 0),
            packedWindow(10, 20),
            "(validAfter << 208) | (validUntil << 160)"
        );

        // The owner never gets a window.
        op = signOp(buildOp(pingCallData(0)), ownerKey);
        h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        assertEq(account.validateUserOp(op, h, 0), 0);

        // A session key with no window at all returns 0 as well: the window is the only difference.
        grant(dapp, pingSession(1 ether, 0, 0));
        op = signOp(buildOp(pingCallData(0)), dappKey);
        h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        assertEq(account.validateUserOp(op, h, 0), 0);
    }

    function test_SessionKeyCannotGrantItselfThroughExecute() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        SessionKeyAccount.Session memory wider = pingSession(type(uint256).max, 0, 0);
        bytes memory inner = abi.encodeCall(SessionKeyAccount.grantSession, (dapp, wider));
        PackedUserOperation memory op =
            signOp(buildOp(executeCallData(address(account), 0, inner)), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(account.sessions(dapp).maxValuePerCall, 1 ether, "unchanged");
    }

    function test_SessionKeyCannotCallTheAccountOutsideExecute() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        // callData that is grantSession itself, not wrapped in execute.
        bytes memory callData =
            abi.encodeCall(SessionKeyAccount.grantSession, (dapp2, pingSession(1 ether, 0, 0)));
        PackedUserOperation memory op = signOp(buildOp(callData), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(account.sessions(dapp2).target, address(0));

        // Or anything else the account does not recognise, including no callData at
        // all. A revert here would surface as AA23, not AA24.
        op = signOp(buildOp(abi.encodeWithSelector(bytes4(0x12345678), uint256(1))), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        op = signOp(buildOp(""), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_SessionBatchWithEveryCallInScopeSucceeds() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        SessionKeyAccount.Call[] memory calls = new SessionKeyAccount.Call[](3);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] = SessionKeyAccount.Call(
                address(recorder), 1 ether, abi.encodeCall(SessionRecorder.ping, (i))
            );
        }
        handle(signOp(buildOp(abi.encodeCall(SessionKeyAccount.executeBatch, (calls))), dappKey));
        assertEq(recorder.count(), 3, "the limit is per call, not per batch");
    }

    function test_SessionBatchWithOneCallOutOfScopeFails() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        SessionKeyAccount.Call[] memory calls = new SessionKeyAccount.Call[](3);
        calls[0] =
            SessionKeyAccount.Call(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (1)));
        calls[1] =
            SessionKeyAccount.Call(address(other), 0, abi.encodeCall(SessionRecorder.ping, (2)));
        calls[2] =
            SessionKeyAccount.Call(address(recorder), 0, abi.encodeCall(SessionRecorder.ping, (3)));
        PackedUserOperation memory op =
            signOp(buildOp(abi.encodeCall(SessionKeyAccount.executeBatch, (calls))), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(recorder.count(), 0);

        calls[1] = SessionKeyAccount.Call(
            address(account), 0, abi.encodeCall(SessionKeyAccount.revokeSession, (dapp2))
        );
        op = signOp(buildOp(abi.encodeCall(SessionKeyAccount.executeBatch, (calls))), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    function test_RevokedSessionFails() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        handle(signOp(buildOp(pingCallData(0)), dappKey));
        vm.prank(owner);
        account.revokeSession(dapp);
        assertEq(account.sessions(dapp).target, address(0));

        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dappKey);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
        assertEq(recorder.count(), 1);
    }

    function test_SessionsAreScopedToTheirKey() public {
        grant(dapp, pingSession(1 ether, 0, 0));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dapp2Key);
        vm.expectRevert(failedOp("AA24 signature error"));
        handle(op);
    }

    // --- Fuzz ------------------------------------------------------------------------------

    function testFuzz_ValueLimitIsEnforcedPerCall(
        uint128 limit,
        uint128 value,
        uint48 validAfter,
        uint48 validUntil
    ) public {
        vm.assume(validUntil == 0 || validUntil > validAfter);
        grant(dapp, pingSession(limit, validAfter, validUntil));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(value)), dappKey);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        uint256 data = account.validateUserOp(op, h, 0);
        if (value <= limit) {
            assertEq(data, packedWindow(validAfter, validUntil));
        } else {
            assertEq(data, 1);
        }
    }

    function testFuzz_WindowIsEnforcedByTheEntryPointNotTheAccount(
        uint48 validAfter,
        uint48 validUntil,
        uint48 now_
    ) public {
        vm.assume(validUntil == 0 || validUntil > validAfter);
        now_ = uint48(bound(now_, 1, type(uint48).max - 1));
        grant(dapp, pingSession(1 ether, validAfter, validUntil));
        PackedUserOperation memory op = signOp(buildOp(pingCallData(0)), dappKey);
        vm.warp(now_);
        bool due = now_ > validAfter && (validUntil == 0 || now_ <= validUntil);
        if (!due) {
            vm.expectRevert(failedOp("AA22 expired or not due"));
        }
        handle(op);
        assertEq(recorder.count(), due ? 1 : 0);
    }
}
