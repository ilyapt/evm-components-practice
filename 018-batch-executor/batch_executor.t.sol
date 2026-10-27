// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BatchExecutor} from "./starter.sol";

/// Records every call it receives, in order, with sender, value and calldata.
contract Recorder {
    struct Entry {
        address sender;
        uint256 value;
        bytes data;
    }

    Entry[] public entries;

    function count() external view returns (uint256) {
        return entries.length;
    }

    function entry(uint256 i) external view returns (Entry memory) {
        return entries[i];
    }

    function ping(uint256 x) external payable returns (uint256) {
        entries.push(Entry(msg.sender, msg.value, msg.data));
        return x + 1;
    }

    receive() external payable {
        entries.push(Entry(msg.sender, msg.value, ""));
    }

    fallback() external payable {
        entries.push(Entry(msg.sender, msg.value, msg.data));
    }
}

/// Fails in the three shapes a wallet must bubble up unchanged.
contract Reverter {
    error Boom(uint256 code);

    function boom(uint256 code) external pure {
        revert Boom(code);
    }

    function fail(string calldata reason) external pure {
        revert(reason);
    }

    function failSilently() external pure {
        assembly {
            revert(0, 0)
        }
    }
}

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }
}

/// A target that re-enters the executor with the same signed batch while being called.
contract Reentrant {
    BatchExecutor public executor;
    bytes32 public mode;
    bytes public executionData;
    uint256 public hits;
    bytes4 public innerError;
    bool public innerSucceeded;

    function arm(BatchExecutor executor_, bytes32 mode_, bytes calldata executionData_) external {
        executor = executor_;
        mode = mode_;
        executionData = executionData_;
    }

    function poke() external {
        hits++;
        if (hits > 1) return; // The replay must never get here.
        try executor.execute(mode, executionData) {
            innerSucceeded = true;
        } catch (bytes memory err) {
            innerError = bytes4(err);
        }
    }
}

contract BatchExecutorTest is Test {
    bytes32 constant MODE_NO_OPDATA =
        0x0100000000000000000000000000000000000000000000000000000000000000;
    bytes32 constant MODE_OPDATA =
        0x0100000000007821000100000000000000000000000000000000000000000000;
    bytes32 constant MODE_BATCH_OF_BATCHES =
        0x0100000000007821000200000000000000000000000000000000000000000000;
    uint256 constant DIRECT = type(uint256).max;
    uint256 constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // Independent EIP-712 encoding, written out from the README.
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");
    bytes32 constant EXECUTE_TYPEHASH = keccak256(
        "Execute(bytes32 mode,Call[] calls,uint256 nonce)Call(address to,uint256 value,bytes data)"
    );

    address ownerAddr;
    uint256 ownerKey;
    address strangerAddr;
    uint256 strangerKey;
    address relayer;

    BatchExecutor ex;
    Recorder rec;
    Reverter rev;
    Counter counter;

    event BatchExecuted(uint256 indexed nonce, uint256 calls);

    function setUp() public {
        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
        (strangerAddr, strangerKey) = makeAddrAndKey("stranger");
        relayer = makeAddr("relayer");
        ex = new BatchExecutor(ownerAddr);
        rec = new Recorder();
        rev = new Reverter();
        counter = new Counter();
        vm.deal(ownerAddr, 100 ether);
        vm.deal(relayer, 100 ether);
        vm.deal(strangerAddr, 100 ether);
    }

    // --- Reference encoding ------------------------------------------------------------

    function refDomainSeparator(address executor) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("BatchExecutor"), keccak256("1"), block.chainid, executor
            )
        );
    }

    function refDigest(address executor, bytes32 mode, BatchExecutor.Call[] memory calls, uint256 n)
        internal
        view
        returns (bytes32)
    {
        bytes memory packed;
        for (uint256 i = 0; i < calls.length; i++) {
            packed = abi.encodePacked(
                packed,
                keccak256(
                    abi.encode(CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data))
                )
            );
        }
        bytes32 structHash = keccak256(abi.encode(EXECUTE_TYPEHASH, mode, keccak256(packed), n));
        return keccak256(abi.encodePacked("\x19\x01", refDomainSeparator(executor), structHash));
    }

    function signedOpData(
        uint256 key,
        address executor,
        bytes32 mode,
        BatchExecutor.Call[] memory calls,
        uint256 n
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, refDigest(executor, mode, calls, n));
        return abi.encodePacked(n, r, s, v);
    }

    function signedData(BatchExecutor.Call[] memory calls) internal view returns (bytes memory) {
        return
            abi.encode(calls, signedOpData(ownerKey, address(ex), MODE_OPDATA, calls, ex.nonce()));
    }

    function call(address to, uint256 value, bytes memory data)
        internal
        pure
        returns (BatchExecutor.Call memory)
    {
        return BatchExecutor.Call({to: to, value: value, data: data});
    }

    function one(BatchExecutor.Call memory c)
        internal
        pure
        returns (BatchExecutor.Call[] memory calls)
    {
        calls = new BatchExecutor.Call[](1);
        calls[0] = c;
    }

    function two(BatchExecutor.Call memory a, BatchExecutor.Call memory b)
        internal
        pure
        returns (BatchExecutor.Call[] memory calls)
    {
        calls = new BatchExecutor.Call[](2);
        calls[0] = a;
        calls[1] = b;
    }

    /// Raw call so revert data can be compared byte for byte.
    function rawExecute(address from, uint256 value, bytes32 mode, bytes memory executionData)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(from);
        (ok, ret) = address(ex).call{value: value}(
            abi.encodeWithSelector(BatchExecutor.execute.selector, mode, executionData)
        );
    }

    // --- Modes ---------------------------------------------------------------------------

    function test_SupportsExactlyTheTwoSingleBatchModes() public view {
        assertTrue(ex.supportsExecutionMode(MODE_NO_OPDATA), "single batch");
        assertTrue(ex.supportsExecutionMode(MODE_OPDATA), "single batch with opData");
        assertFalse(ex.supportsExecutionMode(MODE_BATCH_OF_BATCHES), "batch of batches");
        assertFalse(ex.supportsExecutionMode(bytes32(0)), "zero");
        // byte [1] = 0x01 is ERC-7579 "try" execution: not atomic, not supported.
        assertFalse(
            ex.supportsExecutionMode(
                0x0101000000000000000000000000000000000000000000000000000000000000
            ),
            "try mode"
        );
        // byte [0] = 0x00 is a single call, not a batch.
        assertFalse(
            ex.supportsExecutionMode(
                0x0000000000000000000000000000000000000000000000000000000000000000
            ),
            "single call"
        );
        assertFalse(
            ex.supportsExecutionMode(
                0x0100000000007821000300000000000000000000000000000000000000000000
            ),
            "unknown selector"
        );
        assertFalse(
            ex.supportsExecutionMode(
                0x0100000000007821000000000000000000000000000000000000000000000000
            ),
            "selector 78210000"
        );
    }

    function test_ReservedAndPayloadBytesAreIgnored() public view {
        // bytes [2..5] and [10..31] set to arbitrary values.
        assertTrue(
            ex.supportsExecutionMode(
                0x0100deadbeef00000000ffffffffffffffffffffffffffffffffffffffffffff
            )
        );
        assertTrue(
            ex.supportsExecutionMode(
                0x0100deadbeef78210001ffffffffffffffffffffffffffffffffffffffffffff
            )
        );
        assertFalse(
            ex.supportsExecutionMode(
                0x0100deadbeef78210002ffffffffffffffffffffffffffffffffffffffffffff
            )
        );
    }

    function testFuzz_SupportsExecutionModeMatchesLayout(bytes32 mode) public view {
        uint256 head = (uint256(mode) >> (22 * 8)) & 0xffff00000000ffffffff;
        bool expected = head == 0x01000000000000000000 || head == 0x01000000000078210001;
        assertEq(ex.supportsExecutionMode(mode), expected);
    }

    function test_ExecuteRevertsOnUnsupportedMode() public {
        bytes[] memory batches = new bytes[](0);
        vm.prank(ownerAddr);
        vm.expectRevert(BatchExecutor.UnsupportedExecutionMode.selector);
        ex.execute(MODE_BATCH_OF_BATCHES, abi.encode(batches));

        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](0);
        vm.prank(ownerAddr);
        vm.expectRevert(BatchExecutor.UnsupportedExecutionMode.selector);
        ex.execute(
            0x0101000000000000000000000000000000000000000000000000000000000000, abi.encode(calls)
        );
    }

    // --- Direct execution: order, targets, values --------------------------------------

    function test_CallsExecuteInOrderWithValueAndData() public {
        vm.deal(address(ex), 1 ether);
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](3);
        calls[0] = call(address(rec), 0.1 ether, abi.encodeCall(Recorder.ping, (1)));
        calls[1] = call(address(rec), 0, hex"c0ffee");
        calls[2] = call(address(rec), 0.2 ether, "");
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(calls));

        assertEq(rec.count(), 3);
        Recorder.Entry memory e0 = rec.entry(0);
        assertEq(e0.sender, address(ex));
        assertEq(e0.value, 0.1 ether);
        assertEq(e0.data, abi.encodeCall(Recorder.ping, (1)));
        Recorder.Entry memory e1 = rec.entry(1);
        assertEq(e1.value, 0);
        assertEq(e1.data, hex"c0ffee");
        Recorder.Entry memory e2 = rec.entry(2);
        assertEq(e2.value, 0.2 ether);
        assertEq(e2.data, "");
        assertEq(address(rec).balance, 0.3 ether);
        assertEq(address(ex).balance, 0.7 ether);
    }

    function test_ZeroAddressTargetIsTheExecutorItself() public {
        vm.deal(address(ex), 1 ether);
        // Sending value to address(0) would leave the executor; sending it to itself does not.
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(one(call(address(0), 0.5 ether, ""))));
        assertEq(address(ex).balance, 1 ether, "value stayed in the executor");
        assertEq(address(0).balance, 0, "nothing sent to the zero address");
    }

    function test_SelfCallThroughNestedBatchIsAuthorized() public {
        bytes memory inner =
            abi.encode(one(call(address(rec), 0, abi.encodeCall(Recorder.ping, (7)))));
        BatchExecutor.Call memory outerCall =
            call(address(0), 0, abi.encodeCall(BatchExecutor.execute, (MODE_NO_OPDATA, inner)));
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(one(outerCall)));
        assertEq(rec.count(), 1, "inner batch ran through the self path");
        assertEq(rec.entry(0).data, abi.encodeCall(Recorder.ping, (7)));
    }

    function test_EmptyBatchSucceedsAndEmits() public {
        BatchExecutor.Call[] memory calls = new BatchExecutor.Call[](0);
        vm.expectEmit(true, true, true, true, address(ex));
        emit BatchExecuted(DIRECT, 0);
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(calls));
    }

    function test_DirectExecutionEmitsSentinelNonceAndCallCount() public {
        BatchExecutor.Call[] memory calls =
            two(call(address(rec), 0, ""), call(address(rec), 0, ""));
        vm.expectEmit(true, true, true, true, address(ex));
        emit BatchExecuted(DIRECT, 2);
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(calls));
        assertEq(ex.nonce(), 0, "direct execution does not touch the nonce");
    }

    function test_ExecuteReturnsNoData() public {
        (bool ok, bytes memory ret) =
            rawExecute(ownerAddr, 0, MODE_NO_OPDATA, abi.encode(one(call(address(rec), 0, ""))));
        assertTrue(ok);
        assertEq(ret.length, 0, "ERC-7821 execute has no return value");
    }

    // --- Authorization without opData ---------------------------------------------------

    function test_OwnerCanExecuteDirectly() public {
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(one(call(address(rec), 0, ""))));
        assertEq(rec.count(), 1);
    }

    function test_StrangerCannotExecuteDirectly() public {
        bytes memory data = abi.encode(one(call(address(rec), 0, "")));
        vm.prank(strangerAddr);
        vm.expectRevert(BatchExecutor.Unauthorized.selector);
        ex.execute(MODE_NO_OPDATA, data);

        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.Unauthorized.selector);
        ex.execute(MODE_OPDATA, abi.encode(one(call(address(rec), 0, "")), bytes("")));
        assertEq(rec.count(), 0);
    }

    function test_OwnerCanUseOpDataModeWithEmptyOpData() public {
        vm.prank(ownerAddr);
        ex.execute(MODE_OPDATA, abi.encode(one(call(address(rec), 0, "")), bytes("")));
        assertEq(rec.count(), 1);
        assertEq(ex.nonce(), 0);
    }

    // --- Failure semantics -------------------------------------------------------------

    function test_CustomErrorIsBubbledUnchanged() public {
        bytes memory data =
            abi.encode(one(call(address(rev), 0, abi.encodeCall(Reverter.boom, (42)))));
        (bool ok, bytes memory ret) = rawExecute(ownerAddr, 0, MODE_NO_OPDATA, data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Reverter.Boom.selector, 42));
    }

    function test_StringReasonIsBubbledUnchanged() public {
        bytes memory data =
            abi.encode(one(call(address(rev), 0, abi.encodeCall(Reverter.fail, ("nope")))));
        (bool ok, bytes memory ret) = rawExecute(ownerAddr, 0, MODE_NO_OPDATA, data);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "nope"));
    }

    function test_EmptyRevertIsBubbledAsEmpty() public {
        bytes memory data =
            abi.encode(one(call(address(rev), 0, abi.encodeCall(Reverter.failSilently, ()))));
        (bool ok, bytes memory ret) = rawExecute(ownerAddr, 0, MODE_NO_OPDATA, data);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_FailingCallRollsBackEarlierCalls() public {
        BatchExecutor.Call[] memory calls = two(
            call(address(counter), 0, abi.encodeCall(Counter.increment, ())),
            call(address(rev), 0, abi.encodeCall(Reverter.boom, (1)))
        );
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(Reverter.Boom.selector, 1));
        ex.execute(MODE_NO_OPDATA, abi.encode(calls));
        assertEq(counter.count(), 0, "first call rolled back");
    }

    function test_FailingSignedBatchDoesNotConsumeNonce() public {
        BatchExecutor.Call[] memory calls = two(
            call(address(counter), 0, abi.encodeCall(Counter.increment, ())),
            call(address(rev), 0, abi.encodeCall(Reverter.boom, (1)))
        );
        bytes memory data = signedData(calls);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Reverter.Boom.selector, 1));
        ex.execute(MODE_OPDATA, data);
        assertEq(ex.nonce(), 0);
        assertEq(counter.count(), 0);
        // The same signed batch can be submitted again once the target no longer fails.
    }

    function test_InsufficientBalanceFailsTheBatch() public {
        // The executor has nothing; the call cannot forward 1 ether and fails with empty data.
        bytes memory data = abi.encode(one(call(address(rec), 1 ether, "")));
        (bool ok, bytes memory ret) = rawExecute(ownerAddr, 0, MODE_NO_OPDATA, data);
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(rec.count(), 0);
    }

    // --- Signed batches ----------------------------------------------------------------

    function test_DomainSeparatorMatchesReference() public view {
        assertEq(ex.domainSeparator(), refDomainSeparator(address(ex)));
    }

    function test_RelayerCanSubmitSignedBatch() public {
        BatchExecutor.Call[] memory calls = two(
            call(address(rec), 0, abi.encodeCall(Recorder.ping, (1))),
            call(address(counter), 0, abi.encodeCall(Counter.increment, ()))
        );
        bytes memory data = signedData(calls);
        vm.expectEmit(true, true, true, true, address(ex));
        emit BatchExecuted(0, 2);
        vm.prank(relayer);
        ex.execute(MODE_OPDATA, data);
        assertEq(rec.count(), 1);
        assertEq(rec.entry(0).sender, address(ex));
        assertEq(counter.count(), 1);
        assertEq(ex.nonce(), 1);
    }

    function test_ReplayedSignatureIsRejected() public {
        bytes memory data =
            signedData(one(call(address(counter), 0, abi.encodeCall(Counter.increment, ()))));
        vm.prank(relayer);
        ex.execute(MODE_OPDATA, data);
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidNonce.selector);
        ex.execute(MODE_OPDATA, data);
        assertEq(counter.count(), 1);
    }

    function test_SignatureOverDifferentCallsIsRejected() public {
        BatchExecutor.Call[] memory signedCalls =
            one(call(address(rec), 0, abi.encodeCall(Recorder.ping, (1))));
        BatchExecutor.Call[] memory otherCalls =
            one(call(address(rec), 0, abi.encodeCall(Recorder.ping, (2))));
        bytes memory opData = signedOpData(ownerKey, address(ex), MODE_OPDATA, signedCalls, 0);
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(otherCalls, opData));

        // Same calls but a different value in one of them.
        otherCalls[0] = call(address(rec), 1, abi.encodeCall(Recorder.ping, (1)));
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(otherCalls, opData));
        assertEq(rec.count(), 0);
    }

    function test_ModeIsPartOfTheSignedDigest() public {
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        // Signed for the canonical mode, submitted with a payload byte set: still a supported
        // mode, but not the one the owner signed.
        bytes memory opData = signedOpData(ownerKey, address(ex), MODE_OPDATA, calls, 0);
        bytes32 variant = 0x0100000000007821000100000000000000000000000000000000000000000001;
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(variant, abi.encode(calls, opData));

        // Signed for the variant, submitted with the variant: fine.
        bytes memory opData2 = signedOpData(ownerKey, address(ex), variant, calls, 0);
        vm.prank(relayer);
        ex.execute(variant, abi.encode(calls, opData2));
        assertEq(rec.count(), 1);
    }

    function test_WrongNonceIsRejected() public {
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        bytes memory opData = signedOpData(ownerKey, address(ex), MODE_OPDATA, calls, 5);
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidNonce.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, opData));
    }

    function test_StrangerSignatureIsRejected() public {
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        bytes memory opData = signedOpData(strangerKey, address(ex), MODE_OPDATA, calls, 0);
        vm.prank(strangerAddr);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, opData));
        assertEq(ex.nonce(), 0, "a rejected batch consumes nothing");
    }

    function test_MalformedOpDataIsRejected() public {
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        bytes memory good = signedOpData(ownerKey, address(ex), MODE_OPDATA, calls, 0);
        // 96 bytes: v missing.
        bytes memory short = new bytes(96);
        for (uint256 i = 0; i < 96; i++) {
            short[i] = good[i];
        }
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, short));
        // 98 bytes: trailing byte.
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, abi.encodePacked(good, uint8(0))));
        // 1 byte: nothing to read.
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, hex"01"));
    }

    function test_MalleableSignatureIsRejected() public {
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, refDigest(address(ex), MODE_OPDATA, calls, 0));
        bytes32 s2 = bytes32(SECP256K1_N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, abi.encodePacked(uint256(0), r, s2, v2)));
        // v outside {27, 28}.
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(
            MODE_OPDATA, abi.encode(calls, abi.encodePacked(uint256(0), r, s, uint8(v - 27)))
        );
    }

    function test_SignatureIsBoundToChainId() public {
        bytes memory data = signedData(one(call(address(rec), 0, "")));
        vm.chainId(block.chainid + 1);
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        ex.execute(MODE_OPDATA, data);
    }

    function test_SignatureIsBoundToExecutor() public {
        BatchExecutor other = new BatchExecutor(ownerAddr);
        bytes memory data = signedData(one(call(address(rec), 0, "")));
        // Same owner, same nonce (0), same calls: only the verifying contract differs.
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidSignature.selector);
        other.execute(MODE_OPDATA, data);
    }

    function test_ReenteringTargetCannotReplayTheBatch() public {
        Reentrant target = new Reentrant();
        BatchExecutor.Call[] memory calls = two(
            call(address(target), 0, abi.encodeCall(Reentrant.poke, ())),
            call(address(counter), 0, abi.encodeCall(Counter.increment, ()))
        );
        bytes memory data = signedData(calls);
        target.arm(ex, MODE_OPDATA, data);

        vm.prank(relayer);
        ex.execute(MODE_OPDATA, data);

        assertFalse(target.innerSucceeded(), "the replay must not execute");
        assertEq(target.innerError(), BatchExecutor.InvalidNonce.selector, "rejected by nonce");
        assertEq(target.hits(), 1, "poke ran exactly once");
        assertEq(counter.count(), 1, "the outer batch completed");
        assertEq(ex.nonce(), 1);
    }

    function test_SignedBatchCanCallTheExecutorItself() public {
        // A signed batch that re-enters execute via the self path with an inner direct batch.
        bytes memory inner =
            abi.encode(one(call(address(rec), 0, abi.encodeCall(Recorder.ping, (9)))));
        BatchExecutor.Call[] memory calls = one(
            call(address(0), 0, abi.encodeCall(BatchExecutor.execute, (MODE_NO_OPDATA, inner)))
        );
        bytes memory data = signedData(calls);
        vm.prank(relayer);
        ex.execute(MODE_OPDATA, data);
        assertEq(rec.count(), 1);
        assertEq(ex.nonce(), 1);
    }

    // --- Value accounting --------------------------------------------------------------

    function test_MsgValueIsForwardedToCalls() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        BatchExecutor.Call[] memory calls = two(call(a, 0.6 ether, ""), call(b, 0.4 ether, ""));
        vm.prank(ownerAddr);
        ex.execute{value: 1 ether}(MODE_NO_OPDATA, abi.encode(calls));
        assertEq(a.balance, 0.6 ether);
        assertEq(b.balance, 0.4 ether);
        assertEq(address(ex).balance, 0);
    }

    function test_ContractBalanceFundsCallsAndReceiveAcceptsEther() public {
        (bool ok,) = address(ex).call{value: 2 ether}("");
        assertTrue(ok, "receive");
        assertEq(address(ex).balance, 2 ether);
        address a = makeAddr("a");
        bytes memory data = signedData(one(call(a, 1.5 ether, "")));
        vm.prank(relayer);
        ex.execute(MODE_OPDATA, data);
        assertEq(a.balance, 1.5 ether);
        assertEq(address(ex).balance, 0.5 ether);
    }

    function test_MsgValueAndBalanceCombine() public {
        vm.deal(address(ex), 0.5 ether);
        address a = makeAddr("a");
        vm.prank(ownerAddr);
        ex.execute{value: 0.5 ether}(MODE_NO_OPDATA, abi.encode(one(call(a, 1 ether, ""))));
        assertEq(a.balance, 1 ether);
        assertEq(address(ex).balance, 0);
    }

    // --- Fuzz ----------------------------------------------------------------------------

    function randomCalls(uint8 n, bytes32 seed)
        internal
        view
        returns (BatchExecutor.Call[] memory calls)
    {
        n = n % 6;
        calls = new BatchExecutor.Call[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 h = keccak256(abi.encode(seed, i));
            uint256 len = uint256(h) % 40;
            bytes memory data = new bytes(len);
            for (uint256 j = 0; j < len; j++) {
                data[j] = bytes1(uint8(uint256(keccak256(abi.encode(h, j)))));
            }
            calls[i] = call(address(rec), uint256(h) % 0.01 ether, data);
        }
    }

    function assertRecorded(BatchExecutor.Call[] memory calls) internal view {
        assertEq(rec.count(), calls.length, "every call recorded");
        for (uint256 i = 0; i < calls.length; i++) {
            Recorder.Entry memory e = rec.entry(i);
            assertEq(e.sender, address(ex), "sender");
            assertEq(e.value, calls[i].value, "value");
            assertEq(e.data, calls[i].data, "data");
        }
    }

    function testFuzz_DirectBatchExecutesAllCallsInOrder(uint8 n, bytes32 seed) public {
        BatchExecutor.Call[] memory calls = randomCalls(n, seed);
        vm.deal(address(ex), 1 ether);
        vm.prank(ownerAddr);
        ex.execute(MODE_NO_OPDATA, abi.encode(calls));
        assertRecorded(calls);
    }

    function testFuzz_SignedBatchRoundTrip(uint8 n, bytes32 seed, address submitter) public {
        vm.assume(submitter != address(ex));
        BatchExecutor.Call[] memory calls = randomCalls(n, seed);
        vm.deal(address(ex), 1 ether);
        bytes memory data = signedData(calls);
        vm.prank(submitter);
        ex.execute(MODE_OPDATA, data);
        assertRecorded(calls);
        assertEq(ex.nonce(), 1);
        // Nonces are sequential: the next batch must use 1.
        bytes memory next = signedData(calls);
        vm.prank(submitter);
        ex.execute(MODE_OPDATA, next);
        assertEq(ex.nonce(), 2);
    }

    function testFuzz_SignedBatchWithWrongNonceIsRejected(uint256 n) public {
        vm.assume(n != 0);
        BatchExecutor.Call[] memory calls = one(call(address(rec), 0, ""));
        bytes memory opData = signedOpData(ownerKey, address(ex), MODE_OPDATA, calls, n);
        vm.prank(relayer);
        vm.expectRevert(BatchExecutor.InvalidNonce.selector);
        ex.execute(MODE_OPDATA, abi.encode(calls, opData));
    }
}
