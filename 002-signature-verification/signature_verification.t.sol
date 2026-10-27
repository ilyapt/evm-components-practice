// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SignatureVerifier} from "./starter.sol";

/// Tests for task 002. Expected values are hand-written encodings, known EIP-191
/// vectors, and raw `ecrecover` calls made from this file; the starter is never
/// used to compute an expectation.
contract SignatureVerificationTest is Test {
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // keccak256("\x19Ethereum Signed Message:\n11hello world")
    bytes32 constant HELLO_WORLD_191 =
        0xd9eba16ed0ecae432b71fe008c98cc872bb4cc214d3220a36f365326cf807d68;
    // keccak256("\x19Ethereum Signed Message:\n32" ‖ keccak256("hello"))
    bytes32 constant HELLO_HASH_191 =
        0x456e9aea5e197a1f1af7a3e85a3212fa4049a3ba34c2289b4c860fc0b0c64ef3;

    SignatureVerifier sv;
    uint256 aliceKey;
    address alice;
    bytes32 constant DIGEST = keccak256("some digest");

    function setUp() public {
        sv = new SignatureVerifier();
        (alice, aliceKey) = makeAddrAndKey("alice");
    }

    // --- helpers (independent of the starter) ----------------------------------

    function parts(uint256 key, bytes32 digest)
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(key, digest);
        // Foundry produces canonical (low-s) signatures; the tests rely on it.
        require(uint256(s) <= HALF_N, "vm.sign produced a high s");
    }

    function sig65(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = parts(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function compact(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        return abi.encodePacked(r, vs);
    }

    function malleate(uint8 v, bytes32 s) internal pure returns (uint8, bytes32) {
        return (v == 27 ? 28 : 27, bytes32(N - uint256(s)));
    }

    function expectInvalid65(bytes32 digest, bytes memory signature) internal {
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(digest, signature);
    }

    // --- happy paths -------------------------------------------------------------

    function test_RecoversSignerFrom65ByteSignature() public view {
        assertEq(sv.recover(DIGEST, sig65(aliceKey, DIGEST)), alice);
    }

    function test_RecoversSignerFromSplitSignature() public view {
        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        assertEq(sv.recover(DIGEST, v, r, s), alice);
    }

    function test_RecoversSignerFromCompactSignature() public view {
        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        assertEq(sv.recover(DIGEST, compact(v, r, s)), alice);
    }

    function test_CompactAndFullFormsAgreeForBothParities() public view {
        bool seen27;
        bool seen28;
        for (uint256 i = 0; i < 16; i++) {
            bytes32 d = keccak256(abi.encode("parity", i));
            (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, d);
            if (v == 27) seen27 = true;
            if (v == 28) seen28 = true;
            assertEq(sv.recover(d, abi.encodePacked(r, s, v)), alice, "65-byte form");
            assertEq(sv.recover(d, compact(v, r, s)), alice, "compact form");
        }
        assertTrue(seen27 && seen28, "sixteen signatures must cover both parities");
    }

    function test_AcceptsVZeroAndOne() public view {
        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        uint8 lowV = v - 27;
        assertEq(sv.recover(DIGEST, lowV, r, s), alice, "split form with v in {0,1}");
        assertEq(
            sv.recover(DIGEST, abi.encodePacked(r, s, lowV)), alice, "65-byte form with v in {0,1}"
        );
    }

    function test_IsValidTrueForMatchingSigner() public view {
        assertTrue(sv.isValid(DIGEST, sig65(aliceKey, DIGEST), alice));
        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        assertTrue(sv.isValid(DIGEST, compact(v, r, s), alice));
    }

    // --- rejections ------------------------------------------------------------

    function test_RejectsWrongLength() public {
        bytes memory good = sig65(aliceKey, DIGEST);
        expectInvalid65(DIGEST, "");
        expectInvalid65(DIGEST, hex"1b");
        bytes memory short63 = new bytes(63);
        for (uint256 i = 0; i < 63; i++) {
            short63[i] = good[i];
        }
        expectInvalid65(DIGEST, short63);
        expectInvalid65(DIGEST, abi.encodePacked(good, uint8(0)));
        expectInvalid65(DIGEST, abi.encodePacked(good, good));
    }

    function test_RejectsOtherVValues() public {
        (, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        uint8[5] memory bad = [2, 26, 29, 30, 255];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
            sv.recover(DIGEST, bad[i], r, s);
            expectInvalid65(DIGEST, abi.encodePacked(r, s, bad[i]));
        }
    }

    function test_MalleatedSignatureRecoversSameSignerRawButIsRejected() public {
        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        (uint8 v2, bytes32 s2) = malleate(v, s);
        assertGt(uint256(s2), HALF_N, "twin lives in the upper half");
        // The EVM accepts the twin: this is why the check is needed.
        assertEq(ecrecover(DIGEST, v2, r, s2), alice, "raw ecrecover accepts the malleated twin");

        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(DIGEST, v2, r, s2);
        expectInvalid65(DIGEST, abi.encodePacked(r, s2, v2));
        assertFalse(sv.isValid(DIGEST, abi.encodePacked(r, s2, v2), alice));
    }

    function test_RejectsUpperHalfSInCompactForm() public {
        // A compact signature can only carry s < 2^255, so build one just above n/2
        // with a real r. Raw ecrecover still yields an address for it.
        (uint8 v, bytes32 r,) = parts(aliceKey, DIGEST);
        bytes32 s = bytes32(HALF_N + 1);
        assertNotEq(ecrecover(DIGEST, v, r, s), address(0), "raw ecrecover yields an address");
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(DIGEST, compact(v, r, s));
        assertFalse(sv.isValid(DIGEST, compact(v, r, s), alice));
    }

    function test_AcceptsSExactlyAtHalfOrder() public view {
        // The boundary belongs to the lower half: s == n/2 is canonical.
        (uint8 v, bytes32 r,) = parts(aliceKey, DIGEST);
        bytes32 s = bytes32(HALF_N);
        address raw = ecrecover(DIGEST, v, r, s);
        assertNotEq(raw, address(0), "fixture: raw recovery must succeed");
        assertEq(sv.recover(DIGEST, v, r, s), raw);
        assertEq(sv.recover(DIGEST, compact(v, r, s)), raw);
    }

    function test_RejectsSAboveCurveOrder() public {
        (uint8 v, bytes32 r,) = parts(aliceKey, DIGEST);
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(DIGEST, v, r, bytes32(N));
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(DIGEST, v, r, bytes32(type(uint256).max));
    }

    function test_RejectsZeroAddressRecovery() public {
        // r = s = 0 is not a point on the curve: ecrecover returns address(0).
        assertEq(ecrecover(DIGEST, 27, bytes32(0), bytes32(0)), address(0), "fixture");
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(DIGEST, 27, bytes32(0), bytes32(0));
        expectInvalid65(DIGEST, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        expectInvalid65(DIGEST, abi.encodePacked(bytes32(0), bytes32(0)));
    }

    function test_IsValidReturnsFalseInsteadOfReverting() public view {
        bytes memory good = sig65(aliceKey, DIGEST);
        assertFalse(sv.isValid(DIGEST, "", alice), "empty");
        assertFalse(sv.isValid(DIGEST, abi.encodePacked(good, uint8(0)), alice), "66 bytes");
        assertFalse(sv.isValid(DIGEST, good, address(0xBEEF)), "wrong expected");
        assertFalse(sv.isValid(keccak256("other"), good, alice), "wrong digest");

        bytes memory zeroSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        assertFalse(
            sv.isValid(DIGEST, zeroSig, address(0)), "zero recovery must not match expected=0"
        );

        (uint8 v, bytes32 r, bytes32 s) = parts(aliceKey, DIGEST);
        (uint8 v2, bytes32 s2) = malleate(v, s);
        assertFalse(sv.isValid(DIGEST, abi.encodePacked(r, s2, v2), alice), "malleated");
    }

    // --- EIP-191 -----------------------------------------------------------------

    function test_EthSignedMessageHashOfBytes32MatchesKnownVector() public view {
        assertEq(sv.toEthSignedMessageHash(keccak256("hello")), HELLO_HASH_191);
    }

    function test_EthSignedMessageHashOfBytes32IsPackedPrefix() public view {
        bytes32 h = keccak256("anything");
        bytes32 expected = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
        assertEq(sv.toEthSignedMessageHash(h), expected);
        bytes32 padded = keccak256(abi.encode("\x19Ethereum Signed Message:\n32", h));
        assertNotEq(sv.toEthSignedMessageHash(h), padded, "prefix must be packed, not abi.encode'd");
    }

    function test_EthSignedMessageHashOfBytesMatchesKnownVector() public view {
        bytes memory message = "hello world";
        assertEq(sv.toEthSignedMessageHash(message), HELLO_WORLD_191);
    }

    function checkLength(uint256 length, string memory decimal) internal view {
        bytes memory message = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            message[i] = bytes1(uint8(0x41 + (i % 26)));
        }
        bytes32 expected =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", decimal, message));
        assertEq(sv.toEthSignedMessageHash(message), expected, decimal);
    }

    function test_EthSignedMessageHashUsesDecimalLength() public view {
        checkLength(0, "0");
        checkLength(1, "1");
        checkLength(9, "9");
        checkLength(10, "10");
        checkLength(99, "99");
        checkLength(100, "100");
        checkLength(1000, "1000");
        checkLength(1023, "1023");
    }

    function test_EthSignedMessageHashOfBytesAgreesWithBytes32ForThirtyTwoByteMessage()
        public
        view
    {
        bytes32 h = keccak256("thirty-two");
        bytes memory asBytes = abi.encodePacked(h);
        assertEq(sv.toEthSignedMessageHash(asBytes), sv.toEthSignedMessageHash(h));
    }

    function test_RecoversPersonalSignSignature() public view {
        bytes memory message = "hello world";
        // What a wallet signs for personal_sign, computed here, not by the starter.
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n11", message));
        assertEq(digest, HELLO_WORLD_191);
        bytes memory signature = sig65(aliceKey, digest);
        assertEq(sv.recover(sv.toEthSignedMessageHash(message), signature), alice);
        assertTrue(sv.isValid(sv.toEthSignedMessageHash(message), signature, alice));
    }

    // --- fuzz ------------------------------------------------------------------------

    function testFuzz_SignAndRecover(uint248 keySeed, bytes32 digest) public view {
        uint256 key = uint256(keySeed) + 1;
        address signer = vm.addr(key);
        (uint8 v, bytes32 r, bytes32 s) = parts(key, digest);
        assertEq(sv.recover(digest, abi.encodePacked(r, s, v)), signer, "65-byte");
        assertEq(sv.recover(digest, v, r, s), signer, "split");
        assertEq(sv.recover(digest, compact(v, r, s)), signer, "compact");
        assertEq(sv.recover(digest, abi.encodePacked(r, s, v - 27)), signer, "v in {0,1}");
        assertTrue(sv.isValid(digest, abi.encodePacked(r, s, v), signer));
    }

    function testFuzz_MalleatedTwinIsRejected(uint248 keySeed, bytes32 digest) public {
        uint256 key = uint256(keySeed) + 1;
        (uint8 v, bytes32 r, bytes32 s) = parts(key, digest);
        (uint8 v2, bytes32 s2) = malleate(v, s);
        assertEq(ecrecover(digest, v2, r, s2), vm.addr(key), "raw ecrecover accepts the twin");
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(digest, v2, r, s2);
        assertFalse(sv.isValid(digest, abi.encodePacked(r, s2, v2), vm.addr(key)));
    }

    function testFuzz_IsValidAgreesWithRecover(uint248 keySeed, bytes32 digest, address expected)
        public
        view
    {
        uint256 key = uint256(keySeed) + 1;
        bytes memory signature = sig65(key, digest);
        assertEq(sv.isValid(digest, signature, expected), expected == vm.addr(key));
    }

    function testFuzz_WrongLengthIsRejected(bytes32 digest, bytes memory signature) public {
        vm.assume(signature.length != 64 && signature.length != 65);
        assertFalse(sv.isValid(digest, signature, alice));
        vm.expectRevert(SignatureVerifier.InvalidSignature.selector);
        sv.recover(digest, signature);
    }

    function testFuzz_EthSignedMessageHashMatchesReference(bytes memory message) public view {
        bytes32 expected = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(message.length), message)
        );
        assertEq(sv.toEthSignedMessageHash(message), expected);
    }
}
