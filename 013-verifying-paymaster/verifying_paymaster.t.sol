// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {IStakeManager} from "account-abstraction/interfaces/IStakeManager.sol";
import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {IPaymaster} from "account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SponsorPaymaster} from "./starter.sol";

/// A minimal account used as the sender: one ECDSA owner signing the user operation hash.
contract HarnessAccount is IAccount {
    IEntryPoint immutable entryPoint;
    address immutable owner;

    constructor(IEntryPoint entryPoint_, address owner_) {
        entryPoint = entryPoint_;
        owner = owner_;
    }

    receive() external payable {}

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missing
    ) external returns (uint256) {
        require(msg.sender == address(entryPoint), "harness: not EntryPoint");
        if (missing != 0) {
            (bool ok,) = msg.sender.call{value: missing}("");
            (ok);
        }
        if (userOp.signature.length != 65) return 1;
        bytes32 r = bytes32(userOp.signature[0:32]);
        bytes32 s = bytes32(userOp.signature[32:64]);
        uint8 v = uint8(userOp.signature[64]);
        return ecrecover(userOpHash, v, r, s) == owner ? 0 : 1;
    }

    function execute(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == address(entryPoint), "harness: not EntryPoint");
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }

    function fail() external pure {
        revert("nope");
    }
}

/// Tests for task 013. Every sponsored operation goes through the real EntryPoint v0.8.
contract VerifyingPaymasterTest is Test {
    uint256 constant SIGNER_KEY = 0x5161;
    uint256 constant OTHER_KEY = 0x07E6;
    uint256 constant ACCOUNT_OWNER_KEY = 0xACC;

    uint128 constant VERIFICATION_GAS = 150_000;
    uint128 constant CALL_GAS = 100_000;
    uint256 constant PRE_VERIFICATION_GAS = 50_000;
    uint128 constant MAX_FEE = 1 gwei;
    uint128 constant PM_VERIFICATION_GAS = 100_000;
    uint128 constant PM_POSTOP_GAS = 50_000;

    uint48 constant NO_EXPIRY = 0;
    uint48 constant FROM_GENESIS = 0;

    EntryPoint entryPoint;
    SponsorPaymaster pm;
    HarnessAccount account;
    Counter counter;

    address signer = vm.addr(SIGNER_KEY);
    address other = vm.addr(OTHER_KEY);
    address accountOwner = vm.addr(ACCOUNT_OWNER_KEY);
    address pmOwner = makeAddr("pmOwner");
    address stranger = makeAddr("stranger");
    address payable beneficiary = payable(makeAddr("beneficiary"));

    function setUp() public {
        vm.warp(1_000_000);
        entryPoint = new EntryPoint();
        pm = new SponsorPaymaster(entryPoint, pmOwner, signer);
        pm.deposit{value: 10 ether}();
        account = new HarnessAccount(entryPoint, accountOwner);
        counter = new Counter();
        // The sender holds nothing: without a paymaster its operations could not be paid for.
        assertEq(address(account).balance, 0);
        assertEq(entryPoint.balanceOf(address(account)), 0);
    }

    // --- Helpers ---------------------------------------------------------------

    function pack(uint128 high, uint128 low) internal pure returns (bytes32) {
        return bytes32((uint256(high) << 128) | uint256(low));
    }

    function incrementCall() internal view returns (bytes memory) {
        return abi.encodeCall(
            HarnessAccount.execute, (address(counter), 0, abi.encodeCall(Counter.increment, ()))
        );
    }

    function buildOp(bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: entryPoint.getNonce(address(account), 0),
            initCode: "",
            callData: callData,
            accountGasLimits: pack(VERIFICATION_GAS, CALL_GAS),
            preVerificationGas: PRE_VERIFICATION_GAS,
            gasFees: pack(MAX_FEE, MAX_FEE),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// The first 52 bytes of paymasterAndData: paymaster, verification gas limit, postOp gas limit.
    function pmPrefix(address paymaster) internal pure returns (bytes memory) {
        return abi.encodePacked(paymaster, PM_VERIFICATION_GAS, PM_POSTOP_GAS);
    }

    function ethSigned(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function signHash(uint256 key, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    /// The sponsor's signature for `op` under `paymaster`, computed before the signature (and
    /// the user's signature) exist: `getHash` only sees the 64-byte prefix.
    function sponsorSignature(
        PackedUserOperation memory op,
        SponsorPaymaster paymaster,
        uint48 validUntil,
        uint48 validAfter,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes memory saved = op.paymasterAndData;
        op.paymasterAndData = abi.encodePacked(pmPrefix(address(paymaster)), validUntil, validAfter);
        bytes32 h = paymaster.getHash(op, validUntil, validAfter);
        op.paymasterAndData = saved;
        return signHash(key, ethSigned(h));
    }

    function sponsorWith(
        PackedUserOperation memory op,
        SponsorPaymaster paymaster,
        uint48 validUntil,
        uint48 validAfter,
        uint256 key
    ) internal view {
        bytes memory sig = sponsorSignature(op, paymaster, validUntil, validAfter, key);
        op.paymasterAndData =
            abi.encodePacked(pmPrefix(address(paymaster)), validUntil, validAfter, sig);
    }

    function sponsor(PackedUserOperation memory op, uint48 validUntil, uint48 validAfter)
        internal
        view
    {
        sponsorWith(op, pm, validUntil, validAfter, SIGNER_KEY);
    }

    function userSign(PackedUserOperation memory op) internal view {
        op.signature = signHash(ACCOUNT_OWNER_KEY, entryPoint.getUserOpHash(op));
    }

    /// A fully prepared sponsored op: sponsor signs first, then the user.
    function sponsoredOp(uint48 validUntil, uint48 validAfter)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = buildOp(incrementCall());
        sponsor(op, validUntil, validAfter);
        userSign(op);
    }

    function handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function expectFailedOp(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason));
    }

    function expectAA33(bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOpWithRevert.selector, 0, "AA33 reverted", inner
            )
        );
    }

    function window(uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return (uint256(validAfter) << 208) | (uint256(validUntil) << 160);
    }

    function findLog(Vm.Log[] memory logs, bytes32 topic0, address emitter)
        internal
        pure
        returns (bool found, Vm.Log memory log)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic0 && logs[i].emitter == emitter) return (true, logs[i]);
        }
    }

    // --- Construction and configuration -----------------------------------------

    function test_ExposesEntryPointOwnerAndSigner() public view {
        assertEq(address(pm.entryPoint()), address(entryPoint));
        assertEq(pm.owner(), pmOwner);
        assertEq(pm.signer(), signer);
    }

    function test_SetSignerIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotOwner.selector);
        pm.setSigner(other);
        assertEq(pm.signer(), signer);

        vm.prank(pmOwner);
        pm.setSigner(other);
        assertEq(pm.signer(), other);
    }

    // --- Sponsoring through the EntryPoint ---------------------------------------

    function test_SponsoredOpExecutesAndThePaymasterPaysExactlyTheGasCost() public {
        uint256 pmDepositBefore = entryPoint.balanceOf(address(pm));
        uint256 beneficiaryBefore = beneficiary.balance;

        handle(sponsoredOp(NO_EXPIRY, FROM_GENESIS));

        uint256 actualGasCost = beneficiary.balance - beneficiaryBefore;
        assertEq(counter.count(), 1, "executed");
        assertGt(actualGasCost, 0);
        assertEq(address(account).balance, 0, "sender balance unchanged");
        assertEq(entryPoint.balanceOf(address(account)), 0, "sender deposit unchanged");
        assertEq(
            pmDepositBefore - entryPoint.balanceOf(address(pm)), actualGasCost, "paymaster paid"
        );
    }

    function test_SenderWithItsOwnDepositIsNotCharged() public {
        entryPoint.depositTo{value: 1 ether}(address(account));
        handle(sponsoredOp(NO_EXPIRY, FROM_GENESIS));
        assertEq(
            entryPoint.balanceOf(address(account)), 1 ether, "the sponsor pays, not the sender"
        );
    }

    function test_SponsoredEmitsEventWithUserOpHashAndSender() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        uint256 beneficiaryBefore = beneficiary.balance;

        vm.recordLogs();
        handle(op);

        (bool found, Vm.Log memory log) = findLog(
            vm.getRecordedLogs(), keccak256("Sponsored(bytes32,address,uint256)"), address(pm)
        );
        assertTrue(found, "Sponsored emitted by the paymaster");
        assertEq(log.topics[1], userOpHash, "userOpHash");
        assertEq(address(uint160(uint256(log.topics[2]))), address(account), "sender");
        uint256 reported = abi.decode(log.data, (uint256));
        assertGt(reported, 0);
        assertLe(reported, beneficiary.balance - beneficiaryBefore, "cost so far, before postOp");
    }

    function test_RevertingOpIsStillPaidByThePaymasterAndReportedInPostOp() public {
        PackedUserOperation memory op = buildOp(
            abi.encodeCall(
                HarnessAccount.execute, (address(counter), 0, abi.encodeCall(Counter.fail, ()))
            )
        );
        sponsor(op, NO_EXPIRY, FROM_GENESIS);
        userSign(op);
        uint256 pmDepositBefore = entryPoint.balanceOf(address(pm));

        vm.expectEmit(true, true, false, false, address(pm));
        emit SponsorPaymaster.Sponsored(entryPoint.getUserOpHash(op), address(account), 0);
        handle(op);

        assertEq(counter.count(), 0);
        assertLt(
            entryPoint.balanceOf(address(pm)),
            pmDepositBefore,
            "gas is paid even when the call reverts"
        );
    }

    // --- Signature checks --------------------------------------------------------

    function test_WrongSignerIsAA34() public {
        PackedUserOperation memory op = buildOp(incrementCall());
        sponsorWith(op, pm, NO_EXPIRY, FROM_GENESIS, OTHER_KEY);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
        assertEq(counter.count(), 0);
    }

    function test_SignatureOverTheRawHashIsRejected() public {
        // The sponsor must sign the EIP-191 digest of getHash, not getHash itself.
        PackedUserOperation memory op = buildOp(incrementCall());
        op.paymasterAndData = abi.encodePacked(pmPrefix(address(pm)), NO_EXPIRY, FROM_GENESIS);
        bytes memory sig = signHash(SIGNER_KEY, pm.getHash(op, NO_EXPIRY, FROM_GENESIS));
        op.paymasterAndData = abi.encodePacked(op.paymasterAndData, sig);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_GarbageSignatureIsAA34NotAA33() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData[128] = bytes1(uint8(29)); // invalid v: ecrecover returns address(0)
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_ZeroAddressSignerNeverValidates() public {
        vm.prank(pmOwner);
        pm.setSigner(address(0));
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData[128] = bytes1(uint8(29));
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_RotatedSignerInvalidatesOldSignatures() public {
        PackedUserOperation memory signedByOld = sponsoredOp(NO_EXPIRY, FROM_GENESIS);

        vm.prank(pmOwner);
        pm.setSigner(other);

        expectFailedOp("AA34 signature error");
        handle(signedByOld);

        PackedUserOperation memory op = buildOp(incrementCall());
        sponsorWith(op, pm, NO_EXPIRY, FROM_GENESIS, OTHER_KEY);
        userSign(op);
        handle(op);
        assertEq(counter.count(), 1);
    }

    // --- What the sponsor signature is bound to ---------------------------------

    function test_SignatureIsBoundToCallData() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.callData = abi.encodeCall(
            HarnessAccount.execute, (address(counter), 0, abi.encodeCall(Counter.fail, ()))
        );
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToNonce() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        handle(op);
        assertEq(counter.count(), 1);

        // Reuse the sponsor's approval for the next operation of the same account.
        PackedUserOperation memory next = buildOp(incrementCall());
        next.paymasterAndData = op.paymasterAndData;
        userSign(next);
        expectFailedOp("AA34 signature error");
        handle(next);
        assertEq(counter.count(), 1);
    }

    function test_SignatureIsBoundToSender() public {
        HarnessAccount second = new HarnessAccount(entryPoint, accountOwner);
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.sender = address(second);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToGasParameters() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.accountGasLimits = pack(VERIFICATION_GAS, CALL_GAS + 1);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);

        op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.gasFees = pack(MAX_FEE, MAX_FEE + 1);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);

        op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.preVerificationGas += 1;
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToPaymasterGasLimits() public {
        // The user controls bytes 20..52 of paymasterAndData. Raising them raises what the
        // sponsor may be charged, so they must be part of what the sponsor signed.
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData[35] = bytes1(uint8(op.paymasterAndData[35]) ^ 0x01); // verification gas
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);

        op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData[51] = bytes1(uint8(op.paymasterAndData[51]) ^ 0x01); // postOp gas
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToTheWindow() public {
        PackedUserOperation memory op = sponsoredOp(uint48(block.timestamp + 100), FROM_GENESIS);
        // Stretch validUntil after signing.
        op.paymasterAndData[56] = bytes1(uint8(op.paymasterAndData[56]) ^ 0x01);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToChainId() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        vm.chainId(999);
        userSign(op); // the user re-signs for the new chain; the sponsor did not
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SignatureIsBoundToThePaymasterAddress() public {
        SponsorPaymaster second = new SponsorPaymaster(entryPoint, pmOwner, signer);
        second.deposit{value: 10 ether}();

        PackedUserOperation memory op = buildOp(incrementCall());
        bytes memory sigForFirst = sponsorSignature(op, pm, NO_EXPIRY, FROM_GENESIS, SIGNER_KEY);
        op.paymasterAndData =
            abi.encodePacked(pmPrefix(address(second)), NO_EXPIRY, FROM_GENESIS, sigForFirst);
        userSign(op);
        expectFailedOp("AA34 signature error");
        handle(op);
    }

    function test_SponsorSignatureIsIndependentOfTheAccountSignature() public {
        // sponsoredOp() already sponsors with an empty user signature and signs afterwards; here
        // the user signature is additionally swapped for another valid encoding of the same key.
        PackedUserOperation memory op = buildOp(incrementCall());
        op.signature = hex"deadbeef"; // whatever the wallet shows before signing
        sponsor(op, NO_EXPIRY, FROM_GENESIS);
        userSign(op);
        handle(op);
        assertEq(counter.count(), 1);
    }

    function test_GetHashIgnoresTheSignatureBytesOfPaymasterAndData() public view {
        PackedUserOperation memory op = buildOp(incrementCall());
        op.paymasterAndData = abi.encodePacked(pmPrefix(address(pm)), NO_EXPIRY, FROM_GENESIS);
        bytes32 withoutSig = pm.getHash(op, NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData = abi.encodePacked(op.paymasterAndData, new bytes(65));
        bytes32 withZeroSig = pm.getHash(op, NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData[100] = 0xff;
        bytes32 withOtherSig = pm.getHash(op, NO_EXPIRY, FROM_GENESIS);
        assertEq(withoutSig, withZeroSig);
        assertEq(withoutSig, withOtherSig);
    }

    function testFuzz_GetHashMatchesReferenceEncoding(
        uint256 nonce,
        bytes memory initCode,
        bytes memory callData,
        bytes32 accountGasLimits,
        uint256 preVerificationGas,
        bytes32 gasFees,
        bytes32 paymasterGasLimits,
        uint48 validUntil,
        uint48 validAfter
    ) public view {
        PackedUserOperation memory op = PackedUserOperation({
            sender: address(account),
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            accountGasLimits: accountGasLimits,
            preVerificationGas: preVerificationGas,
            gasFees: gasFees,
            paymasterAndData: abi.encodePacked(
                address(pm), paymasterGasLimits, validUntil, validAfter
            ),
            signature: ""
        });
        bytes32 expected = keccak256(
            abi.encode(
                address(account),
                nonce,
                keccak256(initCode),
                keccak256(callData),
                accountGasLimits,
                preVerificationGas,
                gasFees,
                paymasterGasLimits,
                block.chainid,
                address(pm),
                validUntil,
                validAfter
            )
        );
        assertEq(pm.getHash(op, validUntil, validAfter), expected);
    }

    // --- Validity window -----------------------------------------------------------

    function test_ExpiredWindowIsAA32() public {
        PackedUserOperation memory op = sponsoredOp(uint48(block.timestamp - 1), FROM_GENESIS);
        expectFailedOp("AA32 paymaster expired or not due");
        handle(op);
    }

    function test_NotYetDueWindowIsAA32() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, uint48(block.timestamp + 100));
        expectFailedOp("AA32 paymaster expired or not due");
        handle(op);

        vm.warp(block.timestamp + 101);
        op = sponsoredOp(NO_EXPIRY, uint48(block.timestamp - 1));
        handle(op);
        assertEq(counter.count(), 1);
    }

    function test_WindowBoundaries() public {
        uint48 now_ = uint48(block.timestamp);
        // validUntil is inclusive, validAfter is exclusive (EntryPoint semantics).
        handle(sponsoredOp(now_, now_ - 1));
        assertEq(counter.count(), 1);

        PackedUserOperation memory op = sponsoredOp(now_ + 10, now_);
        expectFailedOp("AA32 paymaster expired or not due");
        handle(op);
    }

    function test_ZeroValidUntilMeansNoExpiry() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        vm.warp(type(uint48).max - 1);
        handle(op);
        assertEq(counter.count(), 1);
    }

    function test_ValidationDataPacksWindowAndSignatureResult() public {
        uint48 validUntil = 123_456;
        uint48 validAfter = 7;
        PackedUserOperation memory op = buildOp(incrementCall());
        sponsor(op, validUntil, validAfter);
        bytes32 userOpHash = entryPoint.getUserOpHash(op);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) =
            pm.validatePaymasterUserOp(op, userOpHash, 0);
        assertEq(validationData, window(validUntil, validAfter), "sigFailed = 0, window packed");
        assertEq(context, abi.encode(userOpHash, address(account)), "context");

        sponsorWith(op, pm, validUntil, validAfter, OTHER_KEY);
        vm.prank(address(entryPoint));
        (, validationData) = pm.validatePaymasterUserOp(op, userOpHash, 0);
        assertEq(validationData, 1 | window(validUntil, validAfter), "sigFailed = 1, window kept");
    }

    function testFuzz_ValidityWindow(uint48 validUntil, uint48 validAfter, uint48 timestamp)
        public
    {
        vm.warp(timestamp);
        PackedUserOperation memory op = sponsoredOp(validUntil, validAfter);

        bool accepted;
        if (window(validUntil, validAfter) == 0) {
            accepted = true; // zero validation data: the EntryPoint skips the time check
        } else {
            uint256 until = validUntil == 0 ? type(uint48).max : validUntil;
            accepted = timestamp > validAfter && timestamp <= until;
        }

        if (!accepted) expectFailedOp("AA32 paymaster expired or not due");
        handle(op);
        assertEq(counter.count(), accepted ? 1 : 0);
    }

    // --- paymasterAndData parsing -----------------------------------------------

    function test_MalformedPaymasterDataIsAA33WithInvalidPaymasterData() public {
        bytes memory inner = abi.encodeWithSelector(SponsorPaymaster.InvalidPaymasterData.selector);
        PackedUserOperation memory op;

        op = buildOp(incrementCall());
        op.paymasterAndData = pmPrefix(address(pm)); // 52 bytes: no window, no signature
        userSign(op);
        expectAA33(inner);
        handle(op);

        op = buildOp(incrementCall());
        op.paymasterAndData = abi.encodePacked(pmPrefix(address(pm)), NO_EXPIRY, FROM_GENESIS); // 64
        userSign(op);
        expectAA33(inner);
        handle(op);

        op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        bytes memory short = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            short[i] = op.paymasterAndData[i];
        }
        op.paymasterAndData = short; // 64-byte signature
        userSign(op);
        expectAA33(inner);
        handle(op);

        op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        op.paymasterAndData = abi.encodePacked(op.paymasterAndData, uint8(0)); // 130
        userSign(op);
        expectAA33(inner);
        handle(op);
    }

    // --- Access control ----------------------------------------------------------

    function test_ValidatePaymasterUserOpFromStrangerReverts() public {
        PackedUserOperation memory op = sponsoredOp(NO_EXPIRY, FROM_GENESIS);
        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotEntryPoint.selector);
        pm.validatePaymasterUserOp(op, bytes32(0), 0);

        vm.prank(pmOwner);
        vm.expectRevert(SponsorPaymaster.NotEntryPoint.selector);
        pm.validatePaymasterUserOp(op, bytes32(0), 0);
    }

    function test_PostOpFromStrangerReverts() public {
        bytes memory context = abi.encode(bytes32(uint256(1)), address(account));
        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotEntryPoint.selector);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, context, 1, 1);
    }

    // --- Deposit and stake -------------------------------------------------------

    function test_AnyoneCanDeposit() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        pm.deposit{value: 1 ether}();
        assertEq(entryPoint.balanceOf(address(pm)), 11 ether);
    }

    function test_WithdrawToIsOwnerOnly() public {
        address payable to = payable(makeAddr("treasury"));

        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotOwner.selector);
        pm.withdrawTo(to, 3 ether);

        vm.prank(pmOwner);
        pm.withdrawTo(to, 3 ether);
        assertEq(to.balance, 3 ether);
        assertEq(entryPoint.balanceOf(address(pm)), 7 ether);
    }

    function test_StakeLifecycleIsOwnerOnly() public {
        address payable to = payable(makeAddr("treasury"));
        vm.deal(pmOwner, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotOwner.selector);
        pm.addStake(1 days);

        vm.prank(pmOwner);
        pm.addStake{value: 1 ether}(1 days);
        IStakeManager.DepositInfo memory info = entryPoint.getDepositInfo(address(pm));
        assertTrue(info.staked);
        assertEq(info.stake, 1 ether);
        assertEq(info.unstakeDelaySec, 1 days);
        assertEq(info.deposit, 10 ether, "stake is separate from the deposit");

        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotOwner.selector);
        pm.unlockStake();

        vm.prank(pmOwner);
        pm.unlockStake();
        info = entryPoint.getDepositInfo(address(pm));
        assertFalse(info.staked);
        assertEq(info.withdrawTime, block.timestamp + 1 days);

        vm.prank(pmOwner);
        vm.expectRevert("Stake withdrawal is not due");
        pm.withdrawStake(to);

        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        vm.expectRevert(SponsorPaymaster.NotOwner.selector);
        pm.withdrawStake(to);

        vm.prank(pmOwner);
        pm.withdrawStake(to);
        assertEq(to.balance, 1 ether);
        assertEq(entryPoint.getDepositInfo(address(pm)).stake, 0);
    }
}
