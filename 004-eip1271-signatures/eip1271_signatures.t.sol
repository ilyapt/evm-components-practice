// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC1271, SignatureChecker, OwnedSigner} from "./starter.sol";

// --- Signer mocks: each models one way a contract signer can misbehave -------

/// Reverts on every call.
contract RevertingSigner1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("not today");
    }
}

/// Has code and a fallback, returns nothing.
contract EmptyReturnSigner1271 {
    fallback() external {}
}

/// Returns a well-formed 32-byte word that is not the magic value.
contract WrongValueSigner1271 is IERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

/// Returns the magic value right-aligned in the word (0x000…1626ba7e): wrong.
contract RightAlignedMagicSigner1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly {
            mstore(0, 0x1626ba7e)
            return(0, 32)
        }
    }
}

/// Returns the magic value in a 64-byte payload (first word correct): accepted.
contract PaddedMagicSigner1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly {
            mstore(0, shl(224, 0x1626ba7e))
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// Returns only the 4 magic bytes, not a full ABI word: rejected.
contract ShortMagicSigner1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly {
            mstore(0, shl(224, 0x1626ba7e))
            return(0, 4)
        }
    }
}

/// Returns the magic value but writes storage while doing so.
contract StateWritingSigner1271 {
    uint256 public validations;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        validations++;
        return IERC1271.isValidSignature.selector;
    }
}

/// Accepts everything; used to show that the checker never falls back to ECDSA.
contract AcceptAllSigner1271 is IERC1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }
}

/// Has code but no `isValidSignature` and no fallback.
contract Counter1271 {
    uint256 public n;

    function inc() external {
        n++;
    }
}

/// Tests for task 004. Expected results follow from the EIP-1271 wire format
/// and from raw `ecrecover` calls made in this file.
contract Eip1271SignaturesTest is Test {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant NOT_MAGIC = 0xffffffff;
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    bytes32 constant HASH = keccak256("the message");

    SignatureChecker checker;
    uint256 aliceKey;
    address alice;
    uint256 bobKey;
    address bob;
    OwnedSigner aliceWallet;

    function setUp() public {
        checker = new SignatureChecker();
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        aliceWallet = new OwnedSigner(alice);
    }

    function sign(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        require(uint256(s) <= HALF_N, "vm.sign produced a high s");
        return abi.encodePacked(r, s, v);
    }

    function malleated(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    // --- EOA path --------------------------------------------------------------------

    function test_EoaValidSignatureIsAccepted() public view {
        assertEq(IERC1271.isValidSignature.selector, MAGIC, "fixture: the magic is the selector");
        assertTrue(checker.isValidSignatureNow(alice, HASH, sign(aliceKey, HASH)));
    }

    function test_EoaWrongSignerIsRejected() public view {
        assertFalse(checker.isValidSignatureNow(bob, HASH, sign(aliceKey, HASH)));
        assertFalse(checker.isValidSignatureNow(alice, keccak256("other"), sign(aliceKey, HASH)));
    }

    function test_EoaRejectsWrongLength() public view {
        bytes memory good = sign(aliceKey, HASH);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = good[i];
        }
        assertFalse(checker.isValidSignatureNow(alice, HASH, ""));
        assertFalse(checker.isValidSignatureNow(alice, HASH, short));
        assertFalse(checker.isValidSignatureNow(alice, HASH, abi.encodePacked(good, uint8(0))));
    }

    function test_EoaRejectsUpperHalfS() public view {
        bytes memory twin = malleated(aliceKey, HASH);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(twin, 32))
            s := mload(add(twin, 64))
            v := byte(0, mload(add(twin, 96)))
        }
        assertEq(ecrecover(HASH, v, r, s), alice, "raw ecrecover accepts the malleated twin");
        assertFalse(checker.isValidSignatureNow(alice, HASH, twin));
    }

    function test_EoaRejectsInvalidV() public view {
        bytes memory sig = sign(aliceKey, HASH);
        sig[64] = bytes1(uint8(29));
        assertFalse(checker.isValidSignatureNow(alice, HASH, sig));
    }

    function test_EoaZeroAddressIsNeverASigner() public view {
        // r = s = 0 makes ecrecover return address(0); signer = address(0) must not match.
        bytes memory zeroSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        assertEq(ecrecover(HASH, 27, bytes32(0), bytes32(0)), address(0), "fixture");
        assertFalse(checker.isValidSignatureNow(address(0), HASH, zeroSig));
    }

    // --- contract path --------------------------------------------------------------------

    function test_ContractSignerAcceptsOwnerSignature() public view {
        assertTrue(checker.isValidSignatureNow(address(aliceWallet), HASH, sign(aliceKey, HASH)));
    }

    function test_ContractSignerRejectsOtherSignature() public {
        assertFalse(checker.isValidSignatureNow(address(aliceWallet), HASH, sign(bobKey, HASH)));
        OwnedSigner bobWallet = new OwnedSigner(bob);
        // A valid EOA signature of Alice presented for a contract that does not accept it.
        assertFalse(checker.isValidSignatureNow(address(bobWallet), HASH, sign(aliceKey, HASH)));
    }

    function test_ContractPathIsUsedEvenIfSignatureRecoversToTheAddress() public {
        bytes memory sig = sign(aliceKey, HASH);
        assertTrue(checker.isValidSignatureNow(alice, HASH, sig), "EOA path before code is set");
        // Alice's address now has code that rejects everything (an EIP-7702-style delegate,
        // or any contract): the ECDSA path must not be consulted any more.
        vm.etch(alice, address(new RevertingSigner1271()).code);
        assertFalse(checker.isValidSignatureNow(alice, HASH, sig));
        vm.etch(alice, address(new WrongValueSigner1271()).code);
        assertFalse(checker.isValidSignatureNow(alice, HASH, sig));
    }

    function test_EcdsaPathIsNotUsedForContracts() public {
        // A contract that accepts everything must be believed, even for garbage bytes.
        AcceptAllSigner1271 acceptAll = new AcceptAllSigner1271();
        assertTrue(checker.isValidSignatureNow(address(acceptAll), HASH, "garbage"));
        assertTrue(checker.isValidSignatureNow(address(acceptAll), HASH, sign(bobKey, HASH)));
    }

    function test_RevertingSignerIsFalse() public {
        address s = address(new RevertingSigner1271());
        assertFalse(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
    }

    function test_EmptyReturnSignerIsFalse() public {
        address s = address(new EmptyReturnSigner1271());
        assertFalse(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
    }

    function test_WrongValueSignerIsFalse() public {
        address s = address(new WrongValueSigner1271());
        assertFalse(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
        address ra = address(new RightAlignedMagicSigner1271());
        assertFalse(
            checker.isValidSignatureNow(ra, HASH, sign(aliceKey, HASH)), "right-aligned magic"
        );
    }

    function test_PaddedMagicIsAccepted() public {
        address s = address(new PaddedMagicSigner1271());
        assertTrue(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
    }

    function test_ShortMagicIsRejected() public {
        address s = address(new ShortMagicSigner1271());
        assertFalse(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
    }

    function test_ContractWithoutIsValidSignatureIsFalse() public {
        address s = address(new Counter1271());
        assertGt(s.code.length, 0, "fixture");
        assertFalse(checker.isValidSignatureNow(s, HASH, sign(aliceKey, HASH)));
    }

    function test_StateWritingSignerIsFalse() public {
        StateWritingSigner1271 s = new StateWritingSigner1271();
        // Called with a plain `call` it would say yes; validation must be a staticcall.
        assertFalse(checker.isValidSignatureNow(address(s), HASH, sign(aliceKey, HASH)));
        assertEq(s.validations(), 0, "no state change may survive validation");
    }

    // --- OwnedSigner ---------------------------------------------------------------------

    function test_OwnedSignerExposesOwner() public view {
        assertEq(aliceWallet.owner(), alice);
    }

    function test_OwnedSignerReturnsMagicForOwner() public view {
        assertEq(aliceWallet.isValidSignature(HASH, sign(aliceKey, HASH)), MAGIC);
    }

    function test_OwnedSignerReturnsFailureValueForOthers() public view {
        assertEq(aliceWallet.isValidSignature(HASH, sign(bobKey, HASH)), NOT_MAGIC);
        assertEq(aliceWallet.isValidSignature(keccak256("other"), sign(aliceKey, HASH)), NOT_MAGIC);
    }

    function test_OwnedSignerRejectsMalleatedAndInvalidV() public view {
        assertEq(aliceWallet.isValidSignature(HASH, malleated(aliceKey, HASH)), NOT_MAGIC);
        bytes memory sig = sign(aliceKey, HASH);
        sig[64] = bytes1(uint8(29));
        assertEq(aliceWallet.isValidSignature(HASH, sig), NOT_MAGIC);
    }

    function test_OwnedSignerDoesNotRevertOnMalformedLength() public view {
        bytes memory good = sign(aliceKey, HASH);
        assertEq(aliceWallet.isValidSignature(HASH, ""), NOT_MAGIC);
        assertEq(aliceWallet.isValidSignature(HASH, hex"1b"), NOT_MAGIC);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = good[i];
        }
        assertEq(aliceWallet.isValidSignature(HASH, short), NOT_MAGIC);
        assertEq(aliceWallet.isValidSignature(HASH, abi.encodePacked(good, uint8(0))), NOT_MAGIC);
        assertEq(aliceWallet.isValidSignature(HASH, new bytes(200)), NOT_MAGIC);
    }

    function test_OwnedSignerWithZeroOwnerAcceptsNothing() public {
        OwnedSigner nobody = new OwnedSigner(address(0));
        bytes memory zeroSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        assertEq(nobody.isValidSignature(HASH, zeroSig), NOT_MAGIC);
        assertFalse(checker.isValidSignatureNow(address(nobody), HASH, zeroSig));
    }

    // --- fuzz -------------------------------------------------------------------------------

    function testFuzz_EoaPath(uint248 keySeed, bytes32 hash, address other) public view {
        uint256 key = uint256(keySeed) + 1;
        address signer = vm.addr(key);
        vm.assume(other != signer && other.code.length == 0);
        bytes memory sig = sign(key, hash);
        assertTrue(checker.isValidSignatureNow(signer, hash, sig));
        assertFalse(checker.isValidSignatureNow(other, hash, sig));
    }

    function testFuzz_EoaRejectsArbitraryBytes(uint248 keySeed, bytes32 hash, bytes memory junk)
        public
        view
    {
        vm.assume(junk.length != 65);
        address signer = vm.addr(uint256(keySeed) + 1);
        assertFalse(checker.isValidSignatureNow(signer, hash, junk));
    }

    function testFuzz_OwnedSignerPath(uint248 ownerSeed, uint248 otherSeed, bytes32 hash) public {
        uint256 ownerKey = uint256(ownerSeed) + 1;
        uint256 otherKey = uint256(otherSeed) + 1;
        vm.assume(ownerKey != otherKey);
        OwnedSigner wallet = new OwnedSigner(vm.addr(ownerKey));
        assertEq(wallet.isValidSignature(hash, sign(ownerKey, hash)), MAGIC);
        assertEq(wallet.isValidSignature(hash, sign(otherKey, hash)), NOT_MAGIC);
        assertTrue(checker.isValidSignatureNow(address(wallet), hash, sign(ownerKey, hash)));
        assertFalse(checker.isValidSignatureNow(address(wallet), hash, sign(otherKey, hash)));
    }
}
