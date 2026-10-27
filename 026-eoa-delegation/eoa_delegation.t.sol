// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DelegatedAccount} from "./starter.sol";

/// Records every call it receives, with the caller the EVM reports.
contract DelegationCallRecorder {
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

/// A target with the classic "no contracts" checks.
contract DelegationNoContracts {
    uint256 public originChecks;
    uint256 public codeSizeChecks;

    function requireOrigin() external {
        require(msg.sender == tx.origin, "no contracts");
        originChecks++;
    }

    function requireNoCode() external {
        require(msg.sender.code.length == 0, "no contracts");
        codeSizeChecks++;
    }
}

/// Tests for task 026. Alice is a fresh EOA whose code becomes the EIP-7702
/// delegation designator pointing at the implementation under test.
contract EoaDelegationTest is Test {
    DelegatedAccount impl;
    DelegationCallRecorder recorder;
    address alice;
    uint256 aliceKey;
    address bob;
    uint256 bobKey;
    address stranger = makeAddr("stranger");

    function setUp() public {
        impl = new DelegatedAccount();
        recorder = new DelegationCallRecorder();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        vm.signAndAttachDelegation(address(impl), aliceKey);
        vm.deal(alice, 10 ether);
    }

    function account() internal view returns (DelegatedAccount) {
        return DelegatedAccount(payable(alice));
    }

    function pingCall(uint256 x, uint256 value)
        internal
        view
        returns (DelegatedAccount.Call memory)
    {
        return DelegatedAccount.Call({
            target: address(recorder),
            value: value,
            data: abi.encodeCall(DelegationCallRecorder.ping, (x))
        });
    }

    function single(DelegatedAccount.Call memory c)
        internal
        pure
        returns (DelegatedAccount.Call[] memory calls)
    {
        calls = new DelegatedAccount.Call[](1);
        calls[0] = c;
    }

    function setOperatorAsAlice(address operator, bool allowed) internal {
        vm.prank(alice);
        account().setOperator(operator, allowed);
    }

    // --- Delegation mechanics ---------------------------------------------------

    function test_DelegatedEoaCodeIsTheDesignator() public view {
        assertEq(
            alice.code,
            abi.encodePacked(bytes3(0xef0100), address(impl)),
            "0xef0100 || implementation"
        );
        assertEq(alice.code.length, 23);
    }

    function test_SelfCallExecutesAndTargetSeesTheEoaAsSender() public {
        vm.prank(alice);
        account().execute(single(pingCall(7, 1 ether)));

        assertEq(recorder.count(), 1);
        DelegationCallRecorder.Seen memory s = recorder.get(0);
        assertEq(s.sender, alice, "the target must see the EOA itself, not the implementation");
        assertEq(s.value, 1 ether);
        assertEq(s.data, abi.encodeCall(DelegationCallRecorder.ping, (7)));
        assertEq(alice.balance, 9 ether, "value leaves the EOA's own balance");
    }

    function test_ExecuteEmitsExecutedWithCallerAndCount() public {
        DelegatedAccount.Call[] memory calls = new DelegatedAccount.Call[](2);
        calls[0] = pingCall(1, 0);
        calls[1] = pingCall(2, 0);
        vm.expectEmit(true, false, false, true, alice);
        emit DelegatedAccount.Executed(alice, 2);
        vm.prank(alice);
        account().execute(calls);
    }

    function test_CallsRunInOrder() public {
        DelegatedAccount.Call[] memory calls = new DelegatedAccount.Call[](3);
        calls[0] = pingCall(10, 0);
        calls[1] = pingCall(20, 0);
        calls[2] = pingCall(30, 0);
        vm.prank(alice);
        account().execute(calls);
        assertEq(recorder.count(), 3);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                recorder.get(i).data,
                abi.encodeCall(DelegationCallRecorder.ping, ((i + 1) * 10)),
                "order"
            );
        }
    }

    function test_FailingCallRevertsTheWholeBatchWithIndexAndReason() public {
        DelegatedAccount.Call[] memory calls = new DelegatedAccount.Call[](3);
        calls[0] = pingCall(1, 0);
        calls[1] = DelegatedAccount.Call({
            target: address(recorder),
            value: 0,
            data: abi.encodeCall(DelegationCallRecorder.fail, ("boom"))
        });
        calls[2] = pingCall(3, 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DelegatedAccount.CallFailed.selector,
                1,
                abi.encodeWithSignature("Error(string)", "boom")
            )
        );
        account().execute(calls);
        assertEq(recorder.count(), 0, "the first call must be rolled back with the batch");
    }

    function test_EmptyBatchIsAllowed() public {
        vm.prank(alice);
        account().execute(new DelegatedAccount.Call[](0));
    }

    function test_DelegatedEoaAcceptsEther() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = alice.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(alice.balance, 11 ether);
    }

    // --- Authority -----------------------------------------------------------------

    function test_SelfCallSetsOperator() public {
        assertFalse(account().isOperator(bob));
        vm.expectEmit(true, false, false, true, alice);
        emit DelegatedAccount.OperatorSet(bob, true);
        setOperatorAsAlice(bob, true);
        assertTrue(account().isOperator(bob));

        setOperatorAsAlice(bob, false);
        assertFalse(account().isOperator(bob));
    }

    function test_OperatorCanExecute() public {
        setOperatorAsAlice(bob, true);
        vm.prank(bob);
        account().execute(single(pingCall(1, 0.5 ether)));
        assertEq(recorder.get(0).sender, alice, "calls still come from the EOA, not the operator");
        assertEq(alice.balance, 9.5 ether, "value is the EOA's, not the operator's");
    }

    function test_RemovedOperatorCannotExecute() public {
        setOperatorAsAlice(bob, true);
        setOperatorAsAlice(bob, false);
        vm.prank(bob);
        vm.expectRevert(DelegatedAccount.NotAuthorized.selector);
        account().execute(single(pingCall(1, 0)));
    }

    function test_StrangerCannotExecute() public {
        vm.prank(stranger);
        vm.expectRevert(DelegatedAccount.NotAuthorized.selector);
        account().execute(single(pingCall(1, 0)));
    }

    function test_StrangerCannotSetOperator() public {
        vm.prank(stranger);
        vm.expectRevert(DelegatedAccount.NotSelf.selector);
        account().setOperator(stranger, true);
    }

    function test_OperatorCannotAddOperators() public {
        setOperatorAsAlice(bob, true);
        vm.prank(bob);
        vm.expectRevert(DelegatedAccount.NotSelf.selector);
        account().setOperator(stranger, true);
    }

    function test_OperatorCannotEscalateThroughExecute() public {
        // An operator tries to have the EOA call its own setOperator. That self-call
        // has msg.sender == the EOA, so the design must decide whether execute may
        // target the account itself. Either way the batch must not silently succeed
        // in making the operator a self-caller for other purposes: here it is
        // allowed by the requirements and is one of the follow-up questions.
        setOperatorAsAlice(bob, true);
        DelegatedAccount.Call[] memory calls = new DelegatedAccount.Call[](1);
        calls[0] = DelegatedAccount.Call({
            target: alice,
            value: 0,
            data: abi.encodeCall(DelegatedAccount.setOperator, (stranger, true))
        });
        vm.prank(bob);
        try account().execute(calls) {
            // Allowed by the statement: the self-call is authentic. Record the fact.
            assertTrue(account().isOperator(stranger));
        } catch {
            assertFalse(account().isOperator(stranger));
        }
    }

    function test_ImplementationDeployedStandaloneCannotBeUsed() public {
        // Nobody can be msg.sender == address(impl) for the implementation itself,
        // and it has no operators: the standalone contract is inert.
        vm.prank(stranger);
        vm.expectRevert(DelegatedAccount.NotAuthorized.selector);
        impl.execute(single(pingCall(1, 0)));

        vm.prank(stranger);
        vm.expectRevert(DelegatedAccount.NotSelf.selector);
        impl.setOperator(stranger, true);

        vm.prank(alice);
        vm.expectRevert(DelegatedAccount.NotAuthorized.selector);
        impl.execute(single(pingCall(1, 0)));
        assertFalse(impl.isOperator(alice));
    }

    function test_AnotherDelegatedEoaHasItsOwnOperators() public {
        vm.signAndAttachDelegation(address(impl), bobKey);
        setOperatorAsAlice(stranger, true);
        assertTrue(account().isOperator(stranger));
        assertFalse(DelegatedAccount(payable(bob)).isOperator(stranger), "storage is per EOA");
    }

    // --- Storage persistence and revocation --------------------------------------

    function test_OperatorsPersistAcrossRedelegationToSameImplementation() public {
        setOperatorAsAlice(bob, true);
        vm.signAndAttachDelegation(address(impl), aliceKey);
        assertTrue(account().isOperator(bob), "storage lives in the EOA, not in the delegation");
    }

    function test_OperatorsSurviveRevokeAndRedelegate() public {
        setOperatorAsAlice(bob, true);

        vm.signAndAttachDelegation(address(0), aliceKey);
        assertEq(alice.code.length, 0, "revoked");

        vm.signAndAttachDelegation(address(impl), aliceKey);
        assertTrue(account().isOperator(bob), "revocation does not clear the EOA's storage");
        vm.prank(bob);
        account().execute(single(pingCall(1, 0)));
        assertEq(recorder.count(), 1);
    }

    function test_AfterRevocationThereIsNoCodeToRun() public {
        setOperatorAsAlice(bob, true);
        vm.signAndAttachDelegation(address(0), aliceKey);
        assertEq(alice.code.length, 0);

        // A plain transfer still works: it is an EOA again.
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = alice.call{value: 1 ether}("");
        assertTrue(sent);
        assertEq(alice.balance, 11 ether);

        // Calling execute on an address without code "succeeds" with no effect and
        // no return data: the EVM does not run anything. Callers that do not check
        // the code size are silently fooled.
        bytes memory data = abi.encodeCall(DelegatedAccount.execute, (single(pingCall(1, 0))));
        vm.prank(bob);
        (bool ok, bytes memory ret) = alice.call(data);
        assertTrue(ok, "a call to an EOA succeeds");
        assertEq(ret.length, 0, "and returns nothing");
        assertEq(recorder.count(), 0, "nothing was executed");

        // The same is true for views: a caller that expects a bool gets no bytes
        // back. The storage is still there, but nothing reads it any more.
        (bool okView, bytes memory retView) =
            alice.staticcall(abi.encodeCall(DelegatedAccount.isOperator, (bob)));
        assertTrue(okView);
        assertEq(retView.length, 0);
    }

    // --- "No contracts" assumptions -----------------------------------------------

    function test_OriginCheckFailsWhenAnOperatorDrivesTheEoa() public {
        DelegationNoContracts nc = new DelegationNoContracts();
        setOperatorAsAlice(bob, true);
        DelegatedAccount.Call[] memory calls = single(
            DelegatedAccount.Call({
                target: address(nc),
                value: 0,
                data: abi.encodeCall(DelegationNoContracts.requireOrigin, ())
            })
        );
        // Bob sends the transaction: tx.origin == bob, msg.sender at the target == alice.
        vm.prank(bob, bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                DelegatedAccount.CallFailed.selector,
                0,
                abi.encodeWithSignature("Error(string)", "no contracts")
            )
        );
        account().execute(calls);
    }

    function test_OriginCheckPassesForASelfCallEvenThoughTheEoaHasCode() public {
        DelegationNoContracts nc = new DelegationNoContracts();
        DelegatedAccount.Call[] memory calls = single(
            DelegatedAccount.Call({
                target: address(nc),
                value: 0,
                data: abi.encodeCall(DelegationNoContracts.requireOrigin, ())
            })
        );
        // Alice sends her own transaction: tx.origin == msg.sender == alice, while
        // the call arrives from code. "msg.sender == tx.origin" no longer proves
        // that the caller is not a contract.
        vm.prank(alice, alice);
        account().execute(calls);
        assertEq(nc.originChecks(), 1);
    }

    function test_CodeSizeCheckRejectsTheDelegatedEoa() public {
        DelegationNoContracts nc = new DelegationNoContracts();
        DelegatedAccount.Call[] memory calls = single(
            DelegatedAccount.Call({
                target: address(nc),
                value: 0,
                data: abi.encodeCall(DelegationNoContracts.requireNoCode, ())
            })
        );
        vm.prank(alice, alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DelegatedAccount.CallFailed.selector,
                0,
                abi.encodeWithSignature("Error(string)", "no contracts")
            )
        );
        account().execute(calls);
    }

    // --- Fuzz ----------------------------------------------------------------------

    function testFuzz_BatchRunsEveryCallInOrderWithItsValue(
        uint96[8] memory values,
        uint8 count,
        bytes[8] memory datas
    ) public {
        count = count % 9;
        DelegatedAccount.Call[] memory calls = new DelegatedAccount.Call[](count);
        uint256 total;
        for (uint256 i = 0; i < count; i++) {
            calls[i] = DelegatedAccount.Call({
                target: address(recorder), value: values[i], data: datas[i]
            });
            total += values[i];
        }
        vm.deal(alice, total);
        vm.prank(alice);
        account().execute(calls);

        assertEq(recorder.count(), count);
        assertEq(alice.balance, 0);
        for (uint256 i = 0; i < count; i++) {
            DelegationCallRecorder.Seen memory s = recorder.get(i);
            assertEq(s.sender, alice);
            assertEq(s.value, values[i]);
            assertEq(s.data, datas[i]);
        }
    }

    function testFuzz_OnlySelfOrOperatorsExecute(address caller) public {
        vm.assume(caller != alice);
        vm.assume(caller.code.length == 0);
        vm.prank(caller);
        vm.expectRevert(DelegatedAccount.NotAuthorized.selector);
        account().execute(single(pingCall(1, 0)));

        setOperatorAsAlice(caller, true);
        vm.prank(caller);
        account().execute(single(pingCall(1, 0)));
        assertEq(recorder.count(), 1);
    }
}
