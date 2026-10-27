// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TypedData} from "./starter.sol";

/// Tests for task 001. Expected values come from the EIP-712 specification
/// example and from an independent encoding written out in this file.
contract Eip712TypedDataTest is Test {
    // The verifying contract and chain of the specification example.
    address constant SPEC_CONTRACT = 0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC;
    bytes32 constant SPEC_DOMAIN_SEPARATOR =
        0xf2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f;
    bytes32 constant SPEC_MAIL_DIGEST =
        0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2;

    // "cow" signs the specification mail.
    uint256 constant COW_KEY = 0xc85ef7d79691fe79573b1a7064c19c1a9819ebdbd1faaab1a8ec92344438aaf4;
    address constant COW = 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826;
    address constant BOB = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    TypedData td;

    function setUp() public {
        TypedData deployed = new TypedData();
        vm.etch(SPEC_CONTRACT, address(deployed).code);
        td = TypedData(SPEC_CONTRACT);
        vm.chainId(1);
    }

    function specMail() internal pure returns (TypedData.Mail memory) {
        return TypedData.Mail({
            from: TypedData.Person({name: "Cow", wallet: COW}),
            to: TypedData.Person({name: "Bob", wallet: BOB}),
            contents: "Hello, Bob!"
        });
    }

    function sign(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    // --- Specification vectors ------------------------------------------------

    function test_DomainSeparatorMatchesSpecVector() public view {
        assertEq(td.domainSeparator(), SPEC_DOMAIN_SEPARATOR, "domain separator");
    }

    function test_MailDigestMatchesSpecVector() public view {
        assertEq(td.digest(td.hashMail(specMail())), SPEC_MAIL_DIGEST, "digest");
    }

    function test_RecoversSpecSignature() public view {
        // The signature published in the EIP-712 example.
        bytes32 r = 0x4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d;
        bytes32 s = 0x07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b91562;
        uint8 v = 28;
        assertEq(td.recoverMailSigner(specMail(), abi.encodePacked(r, s, v)), COW, "signer");
    }

    // --- Domain binding --------------------------------------------------------

    function test_DomainSeparatorFollowsChainId() public {
        bytes32 before = td.domainSeparator();
        vm.chainId(31337);
        bytes32 after_ = td.domainSeparator();
        assertNotEq(before, after_, "domain separator must change with the chain id");
        assertEq(
            after_, expectedDomainSeparator(31337, SPEC_CONTRACT), "recomputed for the new chain"
        );
    }

    function test_SignatureForOldChainDoesNotVerifyAfterFork() public {
        bytes memory sig = sign(COW_KEY, td.digest(td.hashMail(specMail())));
        assertEq(td.recoverMailSigner(specMail(), sig), COW);
        vm.chainId(2);
        // Either recovery fails or it yields some unrelated address; never COW.
        try td.recoverMailSigner(specMail(), sig) returns (address signer) {
            assertNotEq(signer, COW, "a signature for chain 1 must not verify on chain 2");
        } catch {}
    }

    function test_DomainSeparatorBoundToContract() public {
        TypedData other = new TypedData();
        assertNotEq(td.domainSeparator(), other.domainSeparator(), "two contracts, two domains");
        assertEq(other.domainSeparator(), expectedDomainSeparator(1, address(other)));
    }

    function test_SignatureForOneContractDoesNotVerifyOnAnother() public {
        TypedData other = new TypedData();
        bytes memory sig = sign(COW_KEY, td.digest(td.hashMail(specMail())));
        try other.recoverMailSigner(specMail(), sig) returns (address signer) {
            assertNotEq(signer, COW, "a signature for one contract must not verify on another");
        } catch {}
    }

    // --- Struct hashing against an independent encoding -----------------------

    function testFuzz_HashPersonMatchesReference(string memory name, address wallet) public view {
        TypedData.Person memory p = TypedData.Person({name: name, wallet: wallet});
        assertEq(td.hashPerson(p), refHashPerson(p));
    }

    function testFuzz_HashMailMatchesReference(
        string memory fromName,
        address fromWallet,
        string memory toName,
        address toWallet,
        string memory contents
    ) public view {
        TypedData.Mail memory m = TypedData.Mail({
            from: TypedData.Person({name: fromName, wallet: fromWallet}),
            to: TypedData.Person({name: toName, wallet: toWallet}),
            contents: contents
        });
        assertEq(td.hashMail(m), refHashMail(m));
    }

    function testFuzz_HashGroupMatchesReference(
        string memory name,
        string[4] memory memberNames,
        address[4] memory memberWallets,
        uint8 memberCount,
        bytes32[] memory tags
    ) public view {
        memberCount = memberCount % 5;
        TypedData.Person[] memory members = new TypedData.Person[](memberCount);
        for (uint256 i = 0; i < memberCount; i++) {
            members[i] = TypedData.Person({name: memberNames[i], wallet: memberWallets[i]});
        }
        TypedData.Group memory g = TypedData.Group({name: name, members: members, tags: tags});
        assertEq(td.hashGroup(g), refHashGroup(g));
    }

    function test_EmptyArraysAndStringsHashToKeccakOfEmpty() public view {
        TypedData.Group memory g =
            TypedData.Group({name: "", members: new TypedData.Person[](0), tags: new bytes32[](0)});
        bytes32 expected =
            keccak256(abi.encode(GROUP_TYPEHASH, keccak256(""), keccak256(""), keccak256("")));
        assertEq(td.hashGroup(g), expected);
    }

    function test_ArrayOfStructsIsNotHashedAsRawFields() public view {
        // A common mistake: concatenating the members' encodeData instead of their hashStruct.
        TypedData.Person[] memory members = new TypedData.Person[](1);
        members[0] = TypedData.Person({name: "Cow", wallet: COW});
        TypedData.Group memory g =
            TypedData.Group({name: "g", members: members, tags: new bytes32[](0)});
        bytes32 wrong = keccak256(
            abi.encode(
                GROUP_TYPEHASH,
                keccak256("g"),
                keccak256(abi.encode(keccak256("Cow"), COW)),
                keccak256("")
            )
        );
        assertNotEq(td.hashGroup(g), wrong, "members must be hashed as structs, not as raw fields");
        assertEq(td.hashGroup(g), refHashGroup(g));
    }

    function test_StringsAreHashedNotPadded() public view {
        // Short strings must not be left-aligned into a word as bytes32(name) would do.
        TypedData.Person memory p = TypedData.Person({name: "Cow", wallet: COW});
        bytes32 padded = keccak256(abi.encode(PERSON_TYPEHASH, bytes32("Cow"), COW));
        assertNotEq(td.hashPerson(p), padded);
    }

    // --- Recovery --------------------------------------------------------------

    function testFuzz_SignAndRecover(uint248 keySeed, string memory contents) public view {
        uint256 key = uint256(keySeed) + 1;
        address signer = vm.addr(key);
        TypedData.Mail memory m = specMail();
        m.contents = contents;
        bytes memory sig = sign(key, td.digest(td.hashMail(m)));
        assertEq(td.recoverMailSigner(m, sig), signer);
    }

    function test_RecoverRejectsWrongLength() public {
        bytes memory sig = sign(COW_KEY, td.digest(td.hashMail(specMail())));
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        vm.expectRevert(TypedData.InvalidSignature.selector);
        td.recoverMailSigner(specMail(), short);

        bytes memory long = abi.encodePacked(sig, uint8(0));
        vm.expectRevert(TypedData.InvalidSignature.selector);
        td.recoverMailSigner(specMail(), long);
    }

    function test_RecoverRejectsZeroAddress() public {
        // An invalid v makes ecrecover return address(0); that must not be reported as a signer.
        bytes memory sig = sign(COW_KEY, td.digest(td.hashMail(specMail())));
        sig[64] = bytes1(uint8(29));
        vm.expectRevert(TypedData.InvalidSignature.selector);
        td.recoverMailSigner(specMail(), sig);
    }

    function test_RecoverOfTamperedMailGivesOtherSigner() public view {
        bytes memory sig = sign(COW_KEY, td.digest(td.hashMail(specMail())));
        TypedData.Mail memory m = specMail();
        m.contents = "Hello, Bob! Send me 1 ETH.";
        try td.recoverMailSigner(m, sig) returns (address signer) {
            assertNotEq(signer, COW, "tampered contents must not recover the original signer");
        } catch {}
    }

    // --- Independent reference encoding ----------------------------------------

    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant PERSON_TYPEHASH = keccak256("Person(string name,address wallet)");
    bytes32 constant MAIL_TYPEHASH =
        keccak256("Mail(Person from,Person to,string contents)Person(string name,address wallet)");
    bytes32 constant GROUP_TYPEHASH = keccak256(
        "Group(string name,Person[] members,bytes32[] tags)Person(string name,address wallet)"
    );

    function expectedDomainSeparator(uint256 chainId, address verifying)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Ether Mail"), keccak256("1"), chainId, verifying)
        );
    }

    function refHashPerson(TypedData.Person memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(PERSON_TYPEHASH, keccak256(bytes(p.name)), p.wallet));
    }

    function refHashMail(TypedData.Mail memory m) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MAIL_TYPEHASH,
                refHashPerson(m.from),
                refHashPerson(m.to),
                keccak256(bytes(m.contents))
            )
        );
    }

    function refHashGroup(TypedData.Group memory g) internal pure returns (bytes32) {
        bytes memory members;
        for (uint256 i = 0; i < g.members.length; i++) {
            members = abi.encodePacked(members, refHashPerson(g.members[i]));
        }
        bytes memory tags;
        for (uint256 i = 0; i < g.tags.length; i++) {
            tags = abi.encodePacked(tags, g.tags[i]);
        }
        return keccak256(
            abi.encode(
                GROUP_TYPEHASH, keccak256(bytes(g.name)), keccak256(members), keccak256(tags)
            )
        );
    }
}
