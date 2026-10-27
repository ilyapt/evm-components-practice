// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IntentExecutor} from "./starter.sol";

/// A target that records what it was called with, returns data, and can fail
/// in the two common ways (reason string, custom error).
contract IntentTarget {
    error Boom(uint256 code);

    uint256 public calls;
    uint256 public lastValue;
    address public lastSender;

    function ping(uint256 x) external payable returns (uint256) {
        calls++;
        lastValue = msg.value;
        lastSender = msg.sender;
        return x * 2;
    }

    function fail(string calldata reason) external payable {
        revert(reason);
    }

    function failCustom(uint256 code) external payable {
        revert Boom(code);
    }

    receive() external payable {
        calls++;
        lastValue = msg.value;
        lastSender = msg.sender;
    }
}

/// Accepts any calldata; used by the fuzz test.
contract IntentRecorder {
    uint256 public calls;
    uint256 public lastValue;
    bytes public lastData;

    fallback(bytes calldata input) external payable returns (bytes memory) {
        calls++;
        lastValue = msg.value;
        lastData = input;
        return abi.encode(input.length);
    }

    receive() external payable {
        calls++;
        lastValue = msg.value;
        delete lastData;
    }
}

/// On the first call, tries to execute the very same intent again from inside
/// the call and records the outcome instead of reverting.
contract ReentrantIntentTarget {
    IntentExecutor public immutable executor;
    IntentExecutor.Intent internal intent;
    address internal signer;
    bytes internal signature;

    uint256 public entries;
    bool public innerSucceeded;
    bytes public innerError;

    constructor(IntentExecutor executor_) {
        executor = executor_;
    }

    function arm(IntentExecutor.Intent memory intent_, address signer_, bytes memory signature_)
        external
    {
        intent = intent_;
        signer = signer_;
        signature = signature_;
    }

    receive() external payable {
        entries++;
        if (entries == 1) {
            try executor.execute(intent, signer, signature) {
                innerSucceeded = true;
            } catch (bytes memory err) {
                innerError = err;
            }
        }
    }
}

/// Tests for task 003. Digests are computed from an independent EIP-712
/// encoding written out at the bottom of this file; the starter is never used
/// to produce an expectation.
contract ReplayProtectionTest is Test {
    // Domain separator for name "IntentExecutor", version "1", chain 1, contract 0xCcCC…C.
    address constant SPEC_CONTRACT = 0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC;
    bytes32 constant SPEC_DOMAIN_SEPARATOR =
        0x5181336ba4a24b5506f6133cc233d3f7e2f67f2f2798d4f678adca5652b3970d;
    // hashIntent({target: 0xbBbB…B, value: 1e18, data: 0xdeadbeef, nonce: 7, deadline: 1700000000}).
    bytes32 constant SPEC_INTENT_HASH =
        0x64f230c7872e7f6d5ad8a1b604f737b30346dc11fc25108606b235b425820f5b;
    address constant BOB = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    uint256 constant T0 = 1_000_000;

    IntentExecutor ex;
    IntentTarget target;
    uint256 aliceKey;
    address alice;
    address relayer;

    function setUp() public {
        vm.chainId(1);
        vm.warp(T0);
        ex = new IntentExecutor();
        target = new IntentTarget();
        (alice, aliceKey) = makeAddrAndKey("alice");
        relayer = makeAddr("relayer");
        vm.deal(relayer, 100 ether);
    }

    // --- helpers ---------------------------------------------------------------

    function pingIntent(uint256 nonce) internal view returns (IntentExecutor.Intent memory) {
        return IntentExecutor.Intent({
            target: address(target),
            value: 0,
            data: abi.encodeCall(IntentTarget.ping, (7)),
            nonce: nonce,
            deadline: T0 + 1 hours
        });
    }

    function digestFor(
        IntentExecutor executor,
        IntentExecutor.Intent memory intent,
        uint256 chainId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", refDomainSeparator(chainId, address(executor)), refHashIntent(intent)
            )
        );
    }

    function sign(uint256 key, IntentExecutor.Intent memory intent)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digestFor(ex, intent, block.chainid));
        return abi.encodePacked(r, s, v);
    }

    function executeAs(address caller, IntentExecutor.Intent memory intent, bytes memory sig)
        internal
        returns (bytes memory)
    {
        vm.prank(caller);
        return ex.execute(intent, alice, sig);
    }

    // --- hashing -----------------------------------------------------------------

    function test_DomainSeparatorMatchesVector() public {
        IntentExecutor deployed = new IntentExecutor();
        vm.etch(SPEC_CONTRACT, address(deployed).code);
        assertEq(IntentExecutor(payable(SPEC_CONTRACT)).domainSeparator(), SPEC_DOMAIN_SEPARATOR);
    }

    function test_DomainSeparatorFollowsChainId() public {
        bytes32 before = ex.domainSeparator();
        vm.chainId(10);
        assertNotEq(ex.domainSeparator(), before, "must follow the live chain id");
        assertEq(ex.domainSeparator(), refDomainSeparator(10, address(ex)));
    }

    function test_DomainSeparatorBoundToContract() public {
        IntentExecutor other = new IntentExecutor();
        assertNotEq(ex.domainSeparator(), other.domainSeparator());
        assertEq(other.domainSeparator(), refDomainSeparator(1, address(other)));
    }

    function test_HashIntentMatchesVector() public view {
        IntentExecutor.Intent memory intent = IntentExecutor.Intent({
            target: BOB, value: 1 ether, data: hex"deadbeef", nonce: 7, deadline: 1_700_000_000
        });
        assertEq(ex.hashIntent(intent), SPEC_INTENT_HASH);
    }

    function testFuzz_HashIntentMatchesReference(
        address target_,
        uint256 value,
        bytes memory data,
        uint256 nonce,
        uint256 deadline
    ) public view {
        IntentExecutor.Intent memory intent = IntentExecutor.Intent({
            target: target_, value: value, data: data, nonce: nonce, deadline: deadline
        });
        assertEq(ex.hashIntent(intent), refHashIntent(intent));
    }

    function test_DataIsHashedNotInlined() public view {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes32 inlined = keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.target,
                intent.value,
                intent.data,
                intent.nonce,
                intent.deadline
            )
        );
        assertNotEq(ex.hashIntent(intent), inlined, "bytes must be hashed, not ABI-encoded inline");
        assertEq(ex.hashIntent(intent), refHashIntent(intent));
    }

    // --- execution ---------------------------------------------------------------

    function test_ExecutesSignedIntentOnceAndReturnsData() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);

        vm.expectEmit(true, true, true, true, address(ex));
        emit IntentExecutor.Executed(alice, 0, address(target));
        bytes memory ret = executeAs(relayer, intent, sig);

        assertEq(abi.decode(ret, (uint256)), 14, "return data of the call");
        assertEq(target.calls(), 1);
        assertEq(target.lastSender(), address(ex), "the executor is the caller");
        assertEq(ex.nonces(alice), 1);
        assertEq(ex.nonces(relayer), 0, "the relayer's nonce is untouched");
    }

    function test_ReplayOfExecutedIntentFails() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);
        executeAs(relayer, intent, sig);

        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        executeAs(relayer, intent, sig);
        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        executeAs(alice, intent, sig);
        assertEq(target.calls(), 1);
        assertEq(ex.nonces(alice), 1);
    }

    function test_IntentsExecuteInNonceOrder() public {
        IntentExecutor.Intent memory first = pingIntent(0);
        IntentExecutor.Intent memory second = pingIntent(1);
        bytes memory sig0 = sign(aliceKey, first);
        bytes memory sig1 = sign(aliceKey, second);

        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        executeAs(relayer, second, sig1);

        executeAs(relayer, first, sig0);
        executeAs(relayer, second, sig1);
        assertEq(ex.nonces(alice), 2);

        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        executeAs(relayer, first, sig0);
    }

    function test_NoncesAreTrackedPerSigner() public {
        (address bob, uint256 bobKey) = makeAddrAndKey("bob");
        executeAs(relayer, pingIntent(0), sign(aliceKey, pingIntent(0)));
        assertEq(ex.nonces(bob), 0);

        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(bobKey, intent);
        vm.prank(relayer);
        ex.execute(intent, bob, sig);
        assertEq(ex.nonces(bob), 1);
        assertEq(ex.nonces(alice), 1);
    }

    // --- domain binding ------------------------------------------------------------

    function test_RejectsSignatureForOtherChain() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent); // signed for chain 1
        vm.chainId(2);
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, intent, sig);
        assertEq(ex.nonces(alice), 0);

        vm.chainId(1);
        executeAs(relayer, intent, sig);
    }

    function test_RejectsSignatureForOtherDeployment() public {
        IntentExecutor other = new IntentExecutor();
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent); // signed for `ex`
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        vm.prank(relayer);
        other.execute(intent, alice, sig);
        assertEq(other.nonces(alice), 0);
    }

    // --- deadline ---------------------------------------------------------------

    function test_DeadlineIsInclusive() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        intent.deadline = T0 + 100;
        bytes memory sig = sign(aliceKey, intent);

        vm.warp(T0 + 101);
        vm.expectRevert(IntentExecutor.Expired.selector);
        executeAs(relayer, intent, sig);
        assertEq(ex.nonces(alice), 0, "an expired intent consumes nothing");

        vm.warp(T0 + 100);
        executeAs(relayer, intent, sig);
        assertEq(target.calls(), 1);
    }

    // --- signature checks -----------------------------------------------------------

    function test_RejectsTamperedFields() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);

        IntentExecutor.Intent memory t = pingIntent(0);
        t.target = address(new IntentTarget());
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, t, sig);

        t = pingIntent(0);
        t.value = 1;
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, t, sig);

        t = pingIntent(0);
        t.data = abi.encodeCall(IntentTarget.ping, (8));
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, t, sig);

        t = pingIntent(0);
        t.deadline = t.deadline + 1 days;
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, t, sig);

        assertEq(ex.nonces(alice), 0);
        assertEq(target.calls(), 0);
    }

    function test_RejectsSignatureByAnotherKeyForClaimedSigner() public {
        (, uint256 bobKey) = makeAddrAndKey("bob");
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory bobSig = sign(bobKey, intent);
        // Bob's signature, claimed to be Alice's.
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, intent, bobSig);
    }

    function test_ZeroSignerIsNeverValid() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        // r = s = 0 makes ecrecover return address(0): that must not match signer = 0.
        bytes memory zeroSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        vm.prank(relayer);
        ex.execute(intent, address(0), zeroSig);
    }

    function test_RejectsMalformedSignature() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);

        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, intent, short);

        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, intent, abi.encodePacked(sig, uint8(0)));

        bytes memory badV = sign(aliceKey, intent);
        badV[64] = bytes1(uint8(29));
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        executeAs(relayer, intent, badV);
    }

    // --- cancel ----------------------------------------------------------------------

    function test_CancelInvalidatesCurrentNonce() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);

        vm.expectEmit(true, true, true, true, address(ex));
        emit IntentExecutor.Cancelled(alice, 0);
        vm.prank(alice);
        ex.cancel(0);
        assertEq(ex.nonces(alice), 1);

        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        executeAs(relayer, intent, sig);
        assertEq(target.calls(), 0);

        // The next nonce is still usable.
        IntentExecutor.Intent memory next = pingIntent(1);
        executeAs(relayer, next, sign(aliceKey, next));
        assertEq(target.calls(), 1);
    }

    function test_CancelRejectsStaleOrFutureNonce() public {
        vm.prank(alice);
        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        ex.cancel(1);

        vm.prank(alice);
        ex.cancel(0);

        vm.prank(alice);
        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        ex.cancel(0);
        assertEq(ex.nonces(alice), 1);
    }

    function test_CancelOnlyAffectsTheCaller() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        bytes memory sig = sign(aliceKey, intent);

        // The relayer cannot cancel Alice's intent; it only burns its own nonce.
        vm.prank(relayer);
        ex.cancel(0);
        assertEq(ex.nonces(relayer), 1);
        assertEq(ex.nonces(alice), 0);

        executeAs(relayer, intent, sig);
        assertEq(target.calls(), 1);
    }

    // --- call failure and value ---------------------------------------------------------

    function test_FailedCallBubblesReturnDataAndKeepsNonce() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        intent.data = abi.encodeCall(IntentTarget.fail, ("nope"));
        bytes memory sig = sign(aliceKey, intent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentExecutor.CallFailed.selector, abi.encodeWithSignature("Error(string)", "nope")
            )
        );
        executeAs(relayer, intent, sig);
        assertEq(ex.nonces(alice), 0, "a failed call consumes nothing");

        intent.data = abi.encodeCall(IntentTarget.failCustom, (42));
        sig = sign(aliceKey, intent);
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentExecutor.CallFailed.selector,
                abi.encodeWithSelector(IntentTarget.Boom.selector, 42)
            )
        );
        executeAs(relayer, intent, sig);
        assertEq(ex.nonces(alice), 0);

        // The same nonce is still usable by a different intent.
        executeAs(relayer, pingIntent(0), sign(aliceKey, pingIntent(0)));
        assertEq(ex.nonces(alice), 1);
    }

    function test_InsufficientBalanceFailsWithoutConsumingNonce() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        intent.value = 1 ether;
        bytes memory sig = sign(aliceKey, intent);
        assertEq(address(ex).balance, 0);

        vm.expectRevert(abi.encodeWithSelector(IntentExecutor.CallFailed.selector, bytes("")));
        executeAs(relayer, intent, sig);
        assertEq(ex.nonces(alice), 0);
        assertEq(target.calls(), 0);
    }

    function test_ReceiveAcceptsEther() public {
        vm.prank(relayer);
        (bool ok,) = address(ex).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(ex).balance, 1 ether);
    }

    function test_ForwardsValueFromContractBalance() public {
        vm.deal(address(ex), 1 ether);
        IntentExecutor.Intent memory intent = pingIntent(0);
        intent.value = 0.3 ether;
        intent.data = ""; // plain transfer, hits receive()
        executeAs(relayer, intent, sign(aliceKey, intent));

        assertEq(address(target).balance, 0.3 ether);
        assertEq(address(ex).balance, 0.7 ether);
        assertEq(target.lastValue(), 0.3 ether);
        assertEq(target.lastSender(), address(ex));
    }

    function test_RelayerCanFundValueWithMsgValue() public {
        IntentExecutor.Intent memory intent = pingIntent(0);
        intent.value = 0.5 ether;
        bytes memory sig = sign(aliceKey, intent);

        vm.prank(relayer);
        ex.execute{value: 0.5 ether}(intent, alice, sig);
        assertEq(target.lastValue(), 0.5 ether);
        assertEq(address(ex).balance, 0);
    }

    function test_ReentrantTargetCannotReExecuteTheSameIntent() public {
        vm.deal(address(ex), 1 ether);
        ReentrantIntentTarget reentrant = new ReentrantIntentTarget(ex);
        IntentExecutor.Intent memory intent = IntentExecutor.Intent({
            target: address(reentrant), value: 0.1 ether, data: "", nonce: 0, deadline: T0 + 1 hours
        });
        bytes memory sig = sign(aliceKey, intent);
        reentrant.arm(intent, alice, sig);

        executeAs(relayer, intent, sig);

        assertEq(reentrant.entries(), 1, "the target ran exactly once");
        assertFalse(reentrant.innerSucceeded(), "the nested execute must fail");
        assertEq(
            reentrant.innerError(),
            abi.encodeWithSelector(IntentExecutor.InvalidNonce.selector),
            "the nonce is consumed before the call"
        );
        assertEq(address(reentrant).balance, 0.1 ether, "value sent once");
        assertEq(ex.nonces(alice), 1);
    }

    // --- fuzz --------------------------------------------------------------------------

    function testFuzz_ExecutesSignedIntent(
        uint248 keySeed,
        bytes memory data,
        uint96 value,
        uint32 deadlineOffset
    ) public {
        uint256 key = uint256(keySeed) + 1;
        address signer = vm.addr(key);
        IntentRecorder recorder = new IntentRecorder();
        vm.deal(address(ex), uint256(value));

        IntentExecutor.Intent memory intent = IntentExecutor.Intent({
            target: address(recorder),
            value: value,
            data: data,
            nonce: 0,
            deadline: T0 + deadlineOffset
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digestFor(ex, intent, 1));
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        bytes memory ret = ex.execute(intent, signer, sig);

        if (data.length == 0) {
            assertEq(ret.length, 0, "receive() returns nothing");
        } else {
            assertEq(
                abi.decode(ret, (uint256)), data.length, "fallback return data is passed through"
            );
        }
        assertEq(recorder.calls(), 1);
        assertEq(recorder.lastData(), data);
        assertEq(recorder.lastValue(), value);
        assertEq(ex.nonces(signer), 1);

        vm.expectRevert(IntentExecutor.InvalidNonce.selector);
        vm.prank(relayer);
        ex.execute(intent, signer, sig);
    }

    function testFuzz_RejectsSignatureFromAnotherKey(uint248 keySeed, uint248 otherSeed) public {
        uint256 key = uint256(keySeed) + 1;
        uint256 other = uint256(otherSeed) + 1;
        vm.assume(key != other);
        IntentExecutor.Intent memory intent = pingIntent(0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(other, digestFor(ex, intent, 1));
        vm.expectRevert(IntentExecutor.InvalidSignature.selector);
        vm.prank(relayer);
        ex.execute(intent, vm.addr(key), abi.encodePacked(r, s, v));
    }

    // --- independent reference encoding ------------------------------------------------

    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant INTENT_TYPEHASH =
        keccak256("Intent(address target,uint256 value,bytes data,uint256 nonce,uint256 deadline)");

    function refDomainSeparator(uint256 chainId, address verifying)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("IntentExecutor"), keccak256("1"), chainId, verifying
            )
        );
    }

    function refHashIntent(IntentExecutor.Intent memory i) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(INTENT_TYPEHASH, i.target, i.value, keccak256(i.data), i.nonce, i.deadline)
        );
    }
}
