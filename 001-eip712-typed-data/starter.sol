// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice EIP-712 hashing for the "Ether Mail" example domain. See README.md for
/// the full requirements.
contract TypedData {
    struct Person {
        string name;
        address wallet;
    }

    struct Mail {
        Person from;
        Person to;
        string contents;
    }

    struct Group {
        string name;
        Person[] members;
        bytes32[] tags;
    }

    error InvalidSignature();

    string public constant NAME = "Ether Mail";
    string public constant VERSION = "1";

    function domainSeparator() public view returns (bytes32) {
        revert("TODO");
    }

    function hashPerson(Person calldata person) public pure returns (bytes32) {
        person;
        revert("TODO");
    }

    function hashMail(Mail calldata mail) public pure returns (bytes32) {
        mail;
        revert("TODO");
    }

    function hashGroup(Group calldata group) public pure returns (bytes32) {
        group;
        revert("TODO");
    }

    function digest(bytes32 structHash) public view returns (bytes32) {
        structHash;
        revert("TODO");
    }

    function recoverMailSigner(Mail calldata mail, bytes calldata signature)
        external
        view
        returns (address)
    {
        mail;
        signature;
        revert("TODO");
    }
}
