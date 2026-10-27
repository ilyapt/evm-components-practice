// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Erc7739Account} from "./starter.sol";

/// An application with its own EIP-712 domain. Its `Order` is the signed struct
/// (implicit mode); `Listing` references `Asset`, which forces explicit mode in
/// ERC-7739 because EIP-712 sorts referenced types by name.
contract MarketplaceMock {
    struct Order {
        address maker;
        uint256 price;
        uint256 nonce;
    }

    struct Asset {
        address token;
        uint256 id;
    }

    struct Listing {
        Asset asset;
        address maker;
        uint256 price;
    }

    bytes4 constant ERC1271_MAGIC = 0x1626ba7e;
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant ORDER_TYPEHASH = keccak256("Order(address maker,uint256 price,uint256 nonce)");
    bytes32 constant ASSET_TYPEHASH = keccak256("Asset(address token,uint256 id)");
    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(Asset asset,address maker,uint256 price)Asset(address token,uint256 id)"
    );

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("Marketplace"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function hashOrder(Order memory o) public pure returns (bytes32) {
        return keccak256(abi.encode(ORDER_TYPEHASH, o.maker, o.price, o.nonce));
    }

    function hashListing(Listing memory l) public pure returns (bytes32) {
        bytes32 assetHash = keccak256(abi.encode(ASSET_TYPEHASH, l.asset.token, l.asset.id));
        return keccak256(abi.encode(LISTING_TYPEHASH, assetHash, l.maker, l.price));
    }

    function digest(bytes32 structHash) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// The application-side check: EIP-1271 against the maker's account.
    function isOrderSigned(address account, Order memory o, bytes memory sig)
        external
        view
        returns (bool)
    {
        return Erc7739Account(account).isValidSignature(digest(hashOrder(o)), sig) == ERC1271_MAGIC;
    }
}

contract Erc7739RehashingTest is Test {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant FAIL = 0xffffffff;
    bytes4 constant ERC7739_MAGIC = 0x77390001;
    bytes32 constant DETECTION_HASH =
        0x7739773977397739773977397739773977397739773977397739773977397739;
    uint256 constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    string constant ORDER_TYPE = "Order(address maker,uint256 price,uint256 nonce)";
    // The TypedDataSign type string references Listing and Asset, sorted by name: Asset first.
    string constant LISTING_SORTED_TYPES =
        "Asset(address token,uint256 id)Listing(Asset asset,address maker,uint256 price)";

    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant PERSONAL_SIGN_TYPEHASH = keccak256("PersonalSign(bytes prefixed)");

    address ownerAddr;
    uint256 ownerKey;
    address strangerAddr;
    uint256 strangerKey;

    Erc7739Account accountA;
    Erc7739Account accountB;
    MarketplaceMock market;

    function setUp() public {
        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
        (strangerAddr, strangerKey) = makeAddrAndKey("stranger");
        accountA = new Erc7739Account(ownerAddr);
        accountB = new Erc7739Account(ownerAddr);
        market = new MarketplaceMock();
    }

    // --- Independent reference encoding (hand-written from the ERC-7739 text) --------

    function accountDomainSeparator(address account) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("Erc7739Account"), keccak256("1"), block.chainid, account
            )
        );
    }

    /// keccak256("TypedDataSign(<name> contents,string name,string version,uint256 chainId,
    /// address verifyingContract,bytes32 salt)<contentsType>")
    function typedDataSignTypehash(string memory contentsName, string memory contentsType)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "TypedDataSign(",
                contentsName,
                " contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                contentsType
            )
        );
    }

    /// Final TypedDataSign digest: outer domain is the app's, the account's domain fields
    /// are flattened inside the struct, salt included as bytes32(0).
    function typedDataSignDigest(
        address account,
        bytes32 appDomainSeparator,
        bytes32 contentsHash,
        string memory contentsName,
        string memory contentsType
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                typedDataSignTypehash(contentsName, contentsType),
                contentsHash,
                keccak256("Erc7739Account"),
                keccak256("1"),
                block.chainid,
                account,
                bytes32(0)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", appDomainSeparator, structHash));
    }

    function personalSignDigest(address account, bytes32 hash) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                accountDomainSeparator(account),
                keccak256(abi.encode(PERSONAL_SIGN_TYPEHASH, hash))
            )
        );
    }

    function sign(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    /// originalSignature ‖ APP_DOMAIN_SEPARATOR ‖ contentsHash ‖ contentsDescr ‖ uint16(len)
    function withSuffix(
        bytes memory originalSignature,
        bytes32 appDomainSeparator,
        bytes32 contentsHash,
        string memory contentsDescr
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            originalSignature,
            appDomainSeparator,
            contentsHash,
            contentsDescr,
            uint16(bytes(contentsDescr).length)
        );
    }

    /// Full ERC-7739 signature by `key` for `account`, implicit mode, where `contentsDescr`
    /// is both the description and the type and `contentsName` is given separately so the
    /// tests can deliberately sign malformed names.
    function erc7739Sign(
        uint256 key,
        address account,
        bytes32 appDomainSeparator,
        bytes32 contentsHash,
        string memory contentsName,
        string memory contentsType,
        string memory contentsDescr
    ) internal view returns (bytes memory) {
        bytes32 d = typedDataSignDigest(
            account, appDomainSeparator, contentsHash, contentsName, contentsType
        );
        return withSuffix(sign(key, d), appDomainSeparator, contentsHash, contentsDescr);
    }

    function sampleOrder() internal pure returns (MarketplaceMock.Order memory) {
        return MarketplaceMock.Order({maker: address(0xA11CE), price: 1 ether, nonce: 7});
    }

    /// Owner's ERC-7739 signature for `order` on `account` (implicit mode).
    function signOrderFor(address account, MarketplaceMock.Order memory order)
        internal
        view
        returns (bytes memory)
    {
        return erc7739Sign(
            ownerKey,
            account,
            market.domainSeparator(),
            market.hashOrder(order),
            "Order",
            ORDER_TYPE,
            ORDER_TYPE
        );
    }

    function orderHash(MarketplaceMock.Order memory order) internal view returns (bytes32) {
        return market.digest(market.hashOrder(order));
    }

    /// Low-level call so that a revert shows up as `ok == false` instead of failing the test.
    function callIsValid(Erc7739Account account, bytes32 hash, bytes memory sig)
        internal
        view
        returns (bool ok, bytes4 result)
    {
        bytes memory ret;
        (ok, ret) = address(account)
            .staticcall(abi.encodeWithSelector(Erc7739Account.isValidSignature.selector, hash, sig));
        if (ok && ret.length >= 32) result = abi.decode(ret, (bytes4));
    }

    // --- Constructor and domain ------------------------------------------------------

    function test_OwnerIsStored() public view {
        assertEq(accountA.owner(), ownerAddr);
        assertEq(accountB.owner(), ownerAddr);
    }

    function test_Eip712DomainReportsNameVersionChainAndContract() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = accountA.eip712Domain();
        assertEq(uint8(fields), 0x0f, "fields");
        assertEq(name, "Erc7739Account", "name");
        assertEq(version, "1", "version");
        assertEq(chainId, block.chainid, "chainId");
        assertEq(verifyingContract, address(accountA), "verifyingContract");
        assertEq(salt, bytes32(0), "salt");
        assertEq(extensions.length, 0, "extensions");
    }

    function test_Eip712DomainFollowsLiveChainId() public {
        vm.chainId(8453);
        (,,, uint256 chainId,,,) = accountA.eip712Domain();
        assertEq(chainId, 8453);
    }

    // --- Detection -------------------------------------------------------------------

    function test_DetectionSentinelReturnsErc7739Magic() public view {
        assertEq(accountA.isValidSignature(DETECTION_HASH, ""), ERC7739_MAGIC);
    }

    function test_DetectionNeedsExactHashAndEmptySignature() public view {
        assertEq(accountA.isValidSignature(DETECTION_HASH, hex"00"), FAIL, "non-empty signature");
        assertEq(
            accountA.isValidSignature(bytes32(uint256(DETECTION_HASH) + 1), ""), FAIL, "other hash"
        );
        assertEq(accountA.isValidSignature(keccak256("x"), ""), FAIL, "empty signature, other hash");
    }

    // --- TypedDataSign: happy paths -------------------------------------------------

    function test_TypedDataSignImplicitModeAcceptsOwner() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        assertEq(accountA.isValidSignature(orderHash(order), sig), MAGIC, "direct");
        assertTrue(market.isOrderSigned(address(accountA), order, sig), "through the application");
    }

    function test_TypedDataSignExplicitModeAcceptsOwner() public view {
        MarketplaceMock.Listing memory listing = MarketplaceMock.Listing({
            asset: MarketplaceMock.Asset({token: address(0xBEEF), id: 42}),
            maker: address(0xA11CE),
            price: 3 ether
        });
        bytes32 contents = market.hashListing(listing);
        // contentsDescr = contentsType ‖ contentsName because "Listing" is not first in the
        // sorted type string.
        string memory descr = string.concat(LISTING_SORTED_TYPES, "Listing");
        bytes memory sig = erc7739Sign(
            ownerKey,
            address(accountA),
            market.domainSeparator(),
            contents,
            "Listing",
            LISTING_SORTED_TYPES,
            descr
        );
        assertEq(accountA.isValidSignature(market.digest(contents), sig), MAGIC);
    }

    function testFuzz_TypedDataSignRoundTrip(address maker, uint256 price, uint256 nonce)
        public
        view
    {
        MarketplaceMock.Order memory order =
            MarketplaceMock.Order({maker: maker, price: price, nonce: nonce});
        bytes memory sig = signOrderFor(address(accountA), order);
        assertEq(accountA.isValidSignature(orderHash(order), sig), MAGIC, "account A");
        assertEq(accountB.isValidSignature(orderHash(order), sig), FAIL, "account B");
    }

    // --- TypedDataSign: the replay the standard exists for ---------------------------

    function test_TypedDataSignatureForAccountAIsRejectedByAccountB() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        assertEq(accountA.isValidSignature(orderHash(order), sig), MAGIC, "sanity: valid on A");
        assertEq(accountB.isValidSignature(orderHash(order), sig), FAIL, "replayed on B");
        assertFalse(market.isOrderSigned(address(accountB), order, sig));
    }

    function test_RawSignatureOverApplicationDigestIsRejected() public view {
        // The naive EIP-1271: owner signs the app digest directly. Valid on every account
        // the owner controls, so ERC-7739 must reject it.
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory raw = sign(ownerKey, orderHash(order));
        assertEq(accountA.isValidSignature(orderHash(order), raw), FAIL);
        assertEq(accountB.isValidSignature(orderHash(order), raw), FAIL);
    }

    function test_RawSignatureWithSuffixIsRejected() public view {
        // Owner signed the app digest, but the signature carries a correct suffix.
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = withSuffix(
            sign(ownerKey, orderHash(order)),
            market.domainSeparator(),
            market.hashOrder(order),
            ORDER_TYPE
        );
        assertEq(accountA.isValidSignature(orderHash(order), sig), FAIL);
    }

    function test_TypedDataSignRejectsNonOwner() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = erc7739Sign(
            strangerKey,
            address(accountA),
            market.domainSeparator(),
            market.hashOrder(order),
            "Order",
            ORDER_TYPE,
            ORDER_TYPE
        );
        assertEq(accountA.isValidSignature(orderHash(order), sig), FAIL);
    }

    // --- TypedDataSign: tampering ----------------------------------------------------

    function test_TamperedContentsHashInSuffixIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        // Flip one byte of `contentsHash` (bytes [97..129) of the signature).
        sig[100] ^= 0x01;
        assertEq(
            accountA.isValidSignature(orderHash(order), sig), FAIL, "suffix no longer rebuilds hash"
        );

        // Tamper consistently: a different order with the same suffix layout and a
        // matching `hash`. The owner never signed that order.
        MarketplaceMock.Order memory other = sampleOrder();
        other.price = 2 ether;
        bytes memory moved = withSuffix(
            slice(sig, 0, 65), market.domainSeparator(), market.hashOrder(other), ORDER_TYPE
        );
        assertEq(accountA.isValidSignature(orderHash(other), moved), FAIL, "different contents");
    }

    function test_WrongAppDomainSeparatorIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory original = slice(signOrderFor(address(accountA), order), 0, 65);
        bytes32 otherDomain = keccak256("not the marketplace");

        // Suffix carries another domain: `hash` does not reconstruct, so no TypedDataSign.
        bytes memory sig = withSuffix(original, otherDomain, market.hashOrder(order), ORDER_TYPE);
        assertEq(accountA.isValidSignature(orderHash(order), sig), FAIL, "suffix with other domain");

        // Suffix and `hash` agree on the other domain, but the owner signed the marketplace one.
        bytes32 otherHash =
            keccak256(abi.encodePacked("\x19\x01", otherDomain, market.hashOrder(order)));
        assertEq(
            accountA.isValidSignature(otherHash, sig), FAIL, "signature bound to the app domain"
        );
    }

    function test_WrongContentsTypeInSuffixIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory original = slice(signOrderFor(address(accountA), order), 0, 65);
        bytes memory sig = withSuffix(
            original,
            market.domainSeparator(),
            market.hashOrder(order),
            "Order(address maker,uint256 price,uint256 deadline)"
        );
        assertEq(accountA.isValidSignature(orderHash(order), sig), FAIL);
    }

    function test_HashNotMatchingSuffixFallsToPersonalSignAndFails() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        MarketplaceMock.Order memory other = sampleOrder();
        other.nonce = 8;
        // `hash` is for a different order than the suffix describes.
        assertEq(accountA.isValidSignature(orderHash(other), sig), FAIL);
    }

    function testFuzz_TruncatedSignatureIsRejectedWithoutRevert(uint8 cut) public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        uint256 drop = 1 + (uint256(cut) % (sig.length - 1));
        bytes memory truncated = slice(sig, 0, sig.length - drop);
        (bool ok, bytes4 result) = callIsValid(accountA, orderHash(order), truncated);
        assertTrue(ok, "must not revert");
        assertEq(result, FAIL);
    }

    function test_LengthFieldPointingPastStartIsRejectedWithoutRevert() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory original = slice(signOrderFor(address(accountA), order), 0, 65);
        bytes memory sig = abi.encodePacked(
            original, market.domainSeparator(), market.hashOrder(order), ORDER_TYPE, uint16(0xffff)
        );
        (bool ok, bytes4 result) = callIsValid(accountA, orderHash(order), sig);
        assertTrue(ok, "must not revert");
        assertEq(result, FAIL);
    }

    function test_ChainIdChangeInvalidatesTypedDataSign() public {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = signOrderFor(address(accountA), order);
        bytes32 h = orderHash(order);
        assertEq(accountA.isValidSignature(h, sig), MAGIC);
        vm.chainId(block.chainid + 1);
        // Same `hash` (the app's domain is fixed in the test), the account's chain id moved.
        assertEq(accountA.isValidSignature(h, sig), FAIL);
    }

    // --- TypedDataSign: contents name sanitization -----------------------------------

    function test_EmptyContentsDescriptionIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory sig = erc7739Sign(
            ownerKey,
            address(accountA),
            market.domainSeparator(),
            market.hashOrder(order),
            "",
            "",
            ""
        );
        (bool ok, bytes4 result) = callIsValid(accountA, orderHash(order), sig);
        assertTrue(ok, "must not revert");
        assertEq(result, FAIL);
    }

    function test_ForbiddenContentsNamesAreRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        // Each row: (name the account would parse, contentsType, contentsDescr). The owner
        // signs the digest built with exactly that name and type, so the only reason to
        // reject is the sanitization rule.
        string[3][7] memory rows = [
            // empty name (implicit mode)
            [
                "",
                "(address maker,uint256 price,uint256 nonce)",
                "(address maker,uint256 price,uint256 nonce)"
            ],
            // starts with a lowercase letter
            [
                "order",
                "order(address maker,uint256 price,uint256 nonce)",
                "order(address maker,uint256 price,uint256 nonce)"
            ],
            // starts with "(" (explicit mode: name after the last ")")
            ["(Order", ORDER_TYPE, "Order(address maker,uint256 price,uint256 nonce)(Order"],
            // contains a space
            [
                "Or der",
                "Or der(address maker,uint256 price,uint256 nonce)",
                "Or der(address maker,uint256 price,uint256 nonce)"
            ],
            // contains a comma
            [
                "Or,der",
                "Or,der(address maker,uint256 price,uint256 nonce)",
                "Or,der(address maker,uint256 price,uint256 nonce)"
            ],
            // contains ")"
            [
                "Or)der",
                "Or)der(address maker,uint256 price,uint256 nonce)",
                "Or)der(address maker,uint256 price,uint256 nonce)"
            ],
            // contains NUL
            [
                "Or\x00der",
                "Or\x00der(address maker,uint256 price,uint256 nonce)",
                "Or\x00der(address maker,uint256 price,uint256 nonce)"
            ]
        ];
        for (uint256 i = 0; i < rows.length; i++) {
            bytes memory sig = erc7739Sign(
                ownerKey,
                address(accountA),
                market.domainSeparator(),
                market.hashOrder(order),
                rows[i][0],
                rows[i][1],
                rows[i][2]
            );
            (bool ok, bytes4 result) = callIsValid(accountA, orderHash(order), sig);
            assertTrue(ok, string.concat("row ", vm.toString(i), " must not revert"));
            assertEq(result, FAIL, string.concat("row ", vm.toString(i)));
        }
    }

    function test_ExplicitModeWithoutClosingParenIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory original = slice(signOrderFor(address(accountA), order), 0, 65);
        bytes memory sig =
            withSuffix(original, market.domainSeparator(), market.hashOrder(order), "Order");
        (bool ok, bytes4 result) = callIsValid(accountA, orderHash(order), sig);
        assertTrue(ok, "must not revert");
        assertEq(result, FAIL);
    }

    // --- PersonalSign ---------------------------------------------------------------

    function eip191Hash(bytes memory message) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", vm.toString(message.length), message)
        );
    }

    function test_PersonalSignAcceptsOwner() public view {
        bytes32 h = eip191Hash("log in to Marketplace");
        bytes memory sig = sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, sig), MAGIC);
    }

    function test_PersonalSignatureForAccountAIsRejectedByAccountB() public view {
        bytes32 h = eip191Hash("log in to Marketplace");
        bytes memory sig = sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, sig), MAGIC, "sanity: valid on A");
        assertEq(accountB.isValidSignature(h, sig), FAIL, "replayed on B");
    }

    function test_PersonalSignRejectsRawSignatureOverHash() public view {
        bytes32 h = eip191Hash("log in to Marketplace");
        assertEq(accountA.isValidSignature(h, sign(ownerKey, h)), FAIL);
    }

    function test_PersonalSignRejectsNonOwner() public view {
        bytes32 h = eip191Hash("log in to Marketplace");
        bytes memory sig = sign(strangerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, sig), FAIL);
    }

    function test_ChainIdChangeInvalidatesPersonalSign() public {
        bytes32 h = eip191Hash("log in to Marketplace");
        bytes memory sig = sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, sig), MAGIC);
        vm.chainId(block.chainid + 1);
        assertEq(accountA.isValidSignature(h, sig), FAIL);
    }

    function testFuzz_PersonalSignRoundTrip(bytes memory message) public view {
        bytes32 h = eip191Hash(message);
        bytes memory sig = sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, sig), MAGIC, "account A");
        assertEq(accountB.isValidSignature(h, sig), FAIL, "account B");
    }

    // --- ECDSA rules ---------------------------------------------------------------

    function test_MalleableSignatureIsRejected() public view {
        bytes32 h = eip191Hash("hello");
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, abi.encodePacked(r, s, v)), MAGIC, "sanity");
        // The other valid (r, s', v') for the same key and digest.
        bytes32 s2 = bytes32(SECP256K1_N - uint256(s));
        uint8 v2 = v == 27 ? 28 : 27;
        assertEq(
            ecrecover(personalSignDigest(address(accountA), h), v2, r, s2),
            ownerAddr,
            "sanity: malleable"
        );
        assertEq(accountA.isValidSignature(h, abi.encodePacked(r, s2, v2)), FAIL, "upper-half s");
    }

    function test_SignatureWithInvalidVIsRejected() public view {
        bytes32 h = eip191Hash("hello");
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(
            accountA.isValidSignature(h, abi.encodePacked(r, s, uint8(v - 27))), FAIL, "v in {0,1}"
        );
        assertEq(accountA.isValidSignature(h, abi.encodePacked(r, s, uint8(29))), FAIL, "v = 29");
    }

    function test_OriginalSignatureOfWrongLengthIsRejected() public view {
        MarketplaceMock.Order memory order = sampleOrder();
        bytes memory full = signOrderFor(address(accountA), order);
        bytes memory original = slice(full, 0, 65);
        bytes32 ds = market.domainSeparator();
        bytes32 c = market.hashOrder(order);
        // 64-byte original (v dropped) and 66-byte original (one byte appended): both wrong.
        assertEq(
            accountA.isValidSignature(
                orderHash(order), withSuffix(slice(original, 0, 64), ds, c, ORDER_TYPE)
            ),
            FAIL,
            "64"
        );
        assertEq(
            accountA.isValidSignature(
                orderHash(order),
                withSuffix(abi.encodePacked(original, uint8(0)), ds, c, ORDER_TYPE)
            ),
            FAIL,
            "66"
        );
        // PersonalSign with 64 and 66 bytes.
        bytes32 h = eip191Hash("hello");
        bytes memory p = sign(ownerKey, personalSignDigest(address(accountA), h));
        assertEq(accountA.isValidSignature(h, slice(p, 0, 64)), FAIL, "personal 64");
        assertEq(accountA.isValidSignature(h, abi.encodePacked(p, uint8(0))), FAIL, "personal 66");
    }

    function test_ZeroOwnerNeverMatches() public {
        Erc7739Account zero = new Erc7739Account(address(0));
        bytes32 h = eip191Hash("hello");
        // A garbage signature makes ecrecover return address(0), which equals the owner.
        bytes memory garbage = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(27));
        assertEq(zero.isValidSignature(h, garbage), FAIL);
    }

    function testFuzz_GarbageNeverReverts(bytes32 hash, bytes memory signature) public view {
        vm.assume(!(signature.length == 0 && hash == DETECTION_HASH));
        (bool ok, bytes4 result) = callIsValid(accountA, hash, signature);
        assertTrue(ok, "must not revert");
        assertEq(result, FAIL);
    }

    // --- Helpers ---------------------------------------------------------------------

    function slice(bytes memory b, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = b[i];
        }
    }
}
