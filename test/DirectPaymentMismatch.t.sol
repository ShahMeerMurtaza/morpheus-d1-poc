// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] calldata tags_) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function getSession(bytes32 sessionId_) external view returns (bytes memory);
    function getProvider(address provider_) external view returns (
        string memory endpoint, uint256 stake, uint128 createdAt,
        uint128 limitPeriodEnd, uint256 limitPeriodEarned, bool isDeleted
    );
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256 available_, uint256 hold_);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
}

/// @notice PoC for Lane D lead D-1: direct-payment debit/credit asymmetry.
/// In closeSession, _rewardUserAfterClose debits the user the FULL (uncapped)
/// provider reward, while _rewardProviderAfterClose -> _claimForProvider credits
/// the provider only up to (stake - limitPeriodEarned). The spread is bricked
/// in the diamond: not returned to the user, not paid to the provider.
contract DirectPaymentMismatchTest is Test {
    IDiamond constant DIAMOND = IDiamond(0x6aBE1d282f72B474E54527D93b979A4f64d3030a);
    IERC20 constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    uint256 constant PROVIDER_PK = 0xA11CE;
    uint256 constant USER_PK = 0xB0B;
    uint256 constant PRICE_PER_SECOND = 1e13; // 0.00001 MOR/s, within [1e10, 1e16]
    uint256 constant PROVIDER_STAKE = 0.2 ether; // live minimum
    uint256 constant USER_STAKE = 1000 ether;

    address provider;
    address user;
    bytes32 bidId;

    function setUp() public {
        provider = vm.addr(PROVIDER_PK);
        user = vm.addr(USER_PK);

        // fund with ETH so pranked calls succeed on the fork
        vm.deal(provider, 10 ether);
        vm.deal(user, 10 ether);
        // fund both with MOR (local fork: free)
        deal(address(MOR), provider, 2 ether);
        deal(address(MOR), user, USER_STAKE);

        // --- provider registers with minimum stake ---
        vm.startPrank(provider);
        MOR.approve(address(DIAMOND), type(uint256).max);
        DIAMOND.providerRegister(provider, PROVIDER_STAKE, "endpoint");
        // --- provider registers a model (0.1 MOR min) ---
        bytes32 baseModelId = keccak256("model");
        string[] memory tags = new string[](0);
        DIAMOND.modelRegister(provider, baseModelId, keccak256("ipfs"), 0, 0.1 ether, "m", tags);
        bytes32 modelId = DIAMOND.getModelId(provider, baseModelId);
        // --- provider posts a bid ---
        bidId = DIAMOND.postModelBid(provider, modelId, PRICE_PER_SECOND);
        vm.stopPrank();

        // --- user approves the diamond ---
        vm.prank(user);
        MOR.approve(address(DIAMOND), type(uint256).max);
    }

    function _providerApproval(bytes32 bidId_) internal view returns (bytes memory approval, bytes memory sig) {
        approval = abi.encode(bidId_, block.chainid, address(0), uint128(block.timestamp));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(approval)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_PK, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _providerReceipt(bytes32 sessionId_) internal view returns (bytes memory receipt, bytes memory sig) {
        receipt = abi.encode(sessionId_, block.chainid, uint128(block.timestamp), uint32(0), uint32(0));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(receipt)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROVIDER_PK, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_directPayment_debitCreditMismatch() public {
        uint256 userBalInitial = MOR.balanceOf(user); // before openSession: USER_STAKE
        // --- user opens a DIRECT-payment session ---
        (bytes memory approval, bytes memory approvalSig) = _providerApproval(bidId);
        vm.prank(user);
        bytes32 sessionId = DIAMOND.openSession(user, USER_STAKE, true, approval, approvalSig);

        uint256 providerBalBefore = MOR.balanceOf(provider);

        // --- let ~2 days elapse, then close (provider served; receipt is provider-signed) ---
        vm.warp(block.timestamp + 2 days);
        (bytes memory receipt, bytes memory receiptSig) = _providerReceipt(sessionId);
        vm.prank(user);
        DIAMOND.closeSession(receipt, receiptSig);

        uint256 expectedReward = 2 days * PRICE_PER_SECOND; // (closedAt-openedAt)*pps
        emit log_named_uint("provider reward earned (wei)", expectedReward);

        uint256 providerGot = MOR.balanceOf(provider) - providerBalBefore;
        emit log_named_uint("provider actually received (wei)", providerGot);
        // provider is capped at stake - earned = 0.2 MOR for the 365-day window
        assertEq(providerGot, PROVIDER_STAKE, "provider should be capped at stake");

        uint256 spread = expectedReward - providerGot;
        emit log_named_uint("bricked spread (wei)", spread);
        assertGt(spread, 1 ether, "spread is material (>1 MOR)");

        // --- after the day-lock expires the user reclaims the lock, but NEVER the spread ---
        (, uint256 hold) = DIAMOND.getUserStakesOnHold(user, 20);
        emit log_named_uint("on hold after close (wei)", hold);
        vm.warp(block.timestamp + 2 days); // past releaseAt
        vm.prank(user);
        DIAMOND.withdrawUserStakes(user, 20);

        // user staked USER_STAKE; total ever returned to the user:
        uint256 userTotalBack = MOR.balanceOf(user) - (userBalInitial - USER_STAKE);
        emit log_named_uint("user total returned (wei)", userTotalBack);
        uint256 userShortfall = USER_STAKE - userTotalBack;
        emit log_named_uint("user permanent shortfall (wei)", userShortfall);
        assertGe(userShortfall, spread - 0.01 ether, "shortfall must cover the bricked spread");
        // NOTE: provider's limitPeriodEarned is now 0.2 MOR (proven by the 0.2 cap above);
        // any further claim in this 365-day window returns 0, so the 1.528 MOR spread
        // is not recoverable by the provider either. It sits ownerless in the diamond.

        // --- provider drip: after 365d the limiter resets, provider can claim 0.2/year ---
        vm.warp(block.timestamp + 366 days);
        uint256 providerBalPreDrip = MOR.balanceOf(provider);
        vm.prank(provider);
        // claimForProvider has no active-session requirement; delegatee check passes for provider
        (bool dripOk,) = address(DIAMOND).call(
            abi.encodeWithSignature("claimForProvider(bytes32)", sessionId)
        );
        uint256 dripGot = MOR.balanceOf(provider) - providerBalPreDrip;
        emit log_named_string("drip claim ok", dripOk ? "true" : "false");
        emit log_named_uint("provider drip after 366d (wei)", dripGot);
    }
}
