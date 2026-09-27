// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeadMansSwitch} from "../src/DeadMansSwitch.sol";

contract RejectingReceiver {
    bool public rejecting = true;

    function acceptEther() external {
        rejecting = false;
    }

    receive() external payable {
        require(!rejecting, "receiver rejects ETH");
    }
}

contract DeadMansSwitchTest is Test {
    DeadMansSwitch private switches;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    uint256 private constant START = 100 days;

    event Created(
        uint256 indexed id,
        address indexed depositor,
        address indexed beneficiary,
        uint256 balance,
        uint256 period,
        uint256 lastPing
    );
    event Pinged(uint256 indexed id, address indexed depositor, uint256 lastPing);
    event Deposited(uint256 indexed id, address indexed depositor, uint256 amount, uint256 lastPing);
    event Withdrawn(uint256 indexed id, address indexed depositor, uint256 amount, uint256 lastPing);
    event BeneficiaryChanged(uint256 indexed id, address indexed depositor, address indexed newBeneficiary);
    event PeriodChanged(uint256 indexed id, address indexed depositor, uint256 period, uint256 lastPing);
    event Claimed(uint256 indexed id, address indexed beneficiary, address to, uint256 amount);
    event Reclaimed(uint256 indexed id, address indexed depositor, address to, uint256 amount);

    function setUp() public {
        vm.warp(START);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CAROL, 100 ether);
        switches = new DeadMansSwitch();
    }

    function test_createFundedAndEmptySwitchesWithSequentialIds() public {
        vm.expectEmit(true, true, true, true, address(switches));
        emit Created(1, ALICE, BOB, 2 ether, 1 days, START);
        assertEq(_create(ALICE, BOB, 2 ether, 1 days), 1);
        assertEq(_create(CAROL, ALICE, 0, 365 days), 2);
        assertEq(switches.switchCount(), 2);
        _assertInfo(1, ALICE, BOB, 2 ether, 1 days, START, false);
        _assertInfo(2, CAROL, ALICE, 0, 365 days, START, false);
        assertEq(switches.timeLeft(1), 1 days);
        _assertConserved();
    }

    function testFuzz_validPeriod(uint256 period) public {
        period = bound(period, 1 days, 365 days);
        uint256 id = _create(ALICE, BOB, 0, period);
        assertEq(switches.timeLeft(id), period);
    }

    function test_invalidPeriodsAndBeneficiariesDoNotCreateSwitch() public {
        uint256[4] memory invalid = [uint256(0), 1 days - 1, 365 days + 1, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(DeadMansSwitch.InvalidPeriod.selector);
            _create(ALICE, BOB, 1 ether, invalid[i]);
        }
        vm.expectRevert(DeadMansSwitch.InvalidBeneficiary.selector);
        _create(ALICE, address(0), 1 ether, 1 days);
        vm.expectRevert(DeadMansSwitch.InvalidBeneficiary.selector);
        _create(ALICE, ALICE, 1 ether, 1 days);
        assertEq(switches.switchCount(), 0);
        assertEq(ALICE.balance, 100 ether);
        _assertConserved();
    }

    function test_pingOneSecondBeforeLapseResetsDeadlineAndDefeatsOldClaim() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 1 days - 1);
        assertEq(switches.timeLeft(id), 1);
        vm.expectEmit(true, true, false, true, address(switches));
        emit Pinged(id, ALICE, START + 1 days - 1);
        vm.prank(ALICE);
        switches.ping(id);
        assertEq(switches.timeLeft(id), 1 days);
        vm.warp(START + 1 days);
        _reverts(
            BOB, abi.encodeCall(switches.claim, (id, BOB)), 0, abi.encodeWithSelector(DeadMansSwitch.NotLapsed.selector)
        );
        vm.warp(START + 2 days - 1);
        _reverts(
            ALICE, abi.encodeCall(switches.ping, (id)), 0, abi.encodeWithSelector(DeadMansSwitch.AlreadyLapsed.selector)
        );
        vm.prank(BOB);
        switches.claim(id, BOB);
        assertEq(BOB.balance, 101 ether);
        _assertConserved();
    }

    function test_atExactLapseAllDepositorMutationsRevertAndBeneficiaryClaims() public {
        uint256 id = _create(ALICE, BOB, 3 ether, 1 days);
        vm.warp(START + 1 days);
        assertEq(switches.timeLeft(id), 0);
        _depositorCallsRevert(id, ALICE, abi.encodeWithSelector(DeadMansSwitch.AlreadyLapsed.selector));
        vm.expectEmit(true, true, false, true, address(switches));
        emit Claimed(id, BOB, CAROL, 3 ether);
        vm.prank(BOB);
        switches.claim(id, CAROL);
        assertEq(CAROL.balance, 103 ether);
        assertEq(BOB.balance, 100 ether);
        _assertInfo(id, ALICE, BOB, 0, 1 days, START, true);
        _assertConserved();
    }

    function test_earlyClaimAndReclaimRevert() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 1 days - 1);
        _reverts(
            BOB, abi.encodeCall(switches.claim, (id, BOB)), 0, abi.encodeWithSelector(DeadMansSwitch.NotLapsed.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.reclaim, (id, ALICE)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.RecoveryNotAvailable.selector)
        );
        _assertConserved();
    }

    function test_thirdPartiesCannotKeepAliveWithdrawChangeOrClaim() public {
        uint256 id = _create(ALICE, BOB, 2 ether, 1 days);
        vm.warp(START + 12 hours);
        _depositorCallsRevert(id, CAROL, abi.encodeWithSelector(DeadMansSwitch.UnauthorizedDepositor.selector));
        _depositorCallsRevert(id, BOB, abi.encodeWithSelector(DeadMansSwitch.UnauthorizedDepositor.selector));
        _assertInfo(id, ALICE, BOB, 2 ether, 1 days, START, false);
        vm.warp(START + 1 days);
        _reverts(
            CAROL,
            abi.encodeCall(switches.claim, (id, CAROL)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedBeneficiary.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.claim, (id, ALICE)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedBeneficiary.selector)
        );
        vm.warp(START + 366 days);
        _reverts(
            BOB,
            abi.encodeCall(switches.reclaim, (id, BOB)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedDepositor.selector)
        );
        _reverts(
            CAROL,
            abi.encodeCall(switches.reclaim, (id, CAROL)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedDepositor.selector)
        );
        _assertConserved();
    }

    function test_depositLaterResetsClockAndRequiresPositiveValue() public {
        uint256 id = _create(ALICE, BOB, 0, 1 days);
        vm.warp(START + 12 hours);
        _reverts(
            ALICE,
            abi.encodeCall(switches.deposit, (id)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidAmount.selector)
        );
        _assertInfo(id, ALICE, BOB, 0, 1 days, START, false);
        vm.expectEmit(true, true, false, true, address(switches));
        emit Deposited(id, ALICE, 4 ether, START + 12 hours);
        vm.prank(ALICE);
        switches.deposit{value: 4 ether}(id);
        _assertInfo(id, ALICE, BOB, 4 ether, 1 days, START + 12 hours, false);
        _assertConserved();
    }

    function test_partialAndFullWithdrawResetClockAndAllowRefunding() public {
        uint256 id = _create(ALICE, BOB, 4 ether, 1 days);
        vm.warp(START + 12 hours);
        vm.expectEmit(true, true, false, true, address(switches));
        emit Withdrawn(id, ALICE, 1 ether, START + 12 hours);
        vm.prank(ALICE);
        switches.withdraw(id, 1 ether);
        _assertInfo(id, ALICE, BOB, 3 ether, 1 days, START + 12 hours, false);
        assertEq(ALICE.balance, 97 ether);
        vm.warp(START + 1 days);
        vm.prank(ALICE);
        switches.withdraw(id, 3 ether);
        _assertInfo(id, ALICE, BOB, 0, 1 days, START + 1 days, false);
        assertEq(ALICE.balance, 100 ether);
        vm.prank(ALICE);
        switches.deposit{value: 2 ether}(id);
        _assertConserved();
    }

    function test_invalidWithdrawAmountsDoNotResetClock() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 12 hours);
        _reverts(
            ALICE,
            abi.encodeCall(switches.withdraw, (id, 0)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidAmount.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.withdraw, (id, 1 ether + 1)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidAmount.selector)
        );
        _assertInfo(id, ALICE, BOB, 1 ether, 1 days, START, false);
        _assertConserved();
    }

    function test_beneficiaryChangeResetsClockAndRevokesOldBeneficiary() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 12 hours);
        vm.expectEmit(true, true, true, true, address(switches));
        emit BeneficiaryChanged(id, ALICE, CAROL);
        vm.prank(ALICE);
        switches.setBeneficiary(id, CAROL);
        _assertInfo(id, ALICE, CAROL, 1 ether, 1 days, START + 12 hours, false);
        vm.warp(START + 1 days);
        _reverts(
            CAROL,
            abi.encodeCall(switches.claim, (id, CAROL)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.NotLapsed.selector)
        );
        vm.warp(START + 36 hours);
        _reverts(
            BOB,
            abi.encodeCall(switches.claim, (id, BOB)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedBeneficiary.selector)
        );
        vm.prank(CAROL);
        switches.claim(id, CAROL);
        _assertConserved();
    }

    function test_periodChangeResetsClockIncludingShorteningAndSameValue() public {
        uint256 id = _create(ALICE, BOB, 0, 365 days);
        vm.warp(START + 300 days);
        vm.expectEmit(true, true, false, true, address(switches));
        emit PeriodChanged(id, ALICE, 1 days, START + 300 days);
        vm.prank(ALICE);
        switches.setPeriod(id, 1 days);
        assertEq(switches.timeLeft(id), 1 days);
        vm.warp(START + 300 days + 12 hours);
        vm.prank(ALICE);
        switches.setPeriod(id, 1 days);
        assertEq(switches.timeLeft(id), 1 days);
        vm.prank(ALICE);
        switches.setPeriod(id, 365 days);
        assertEq(switches.timeLeft(id), 365 days);
    }

    function test_invalidChangesLeaveClockAndConfigurationIntact() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 12 hours);
        _reverts(
            ALICE,
            abi.encodeCall(switches.setBeneficiary, (id, address(0))),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidBeneficiary.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.setBeneficiary, (id, ALICE)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidBeneficiary.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.setPeriod, (id, 1 days - 1)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidPeriod.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.setPeriod, (id, 365 days + 1)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidPeriod.selector)
        );
        _assertInfo(id, ALICE, BOB, 1 ether, 1 days, START, false);
    }

    function test_reclaimBoundaryMinusOneFailsAndExactBoundaryPaysAlternateRecipient() public {
        uint256 id = _create(ALICE, BOB, 2 ether, 1 days);
        vm.warp(START + 366 days - 1);
        _reverts(
            ALICE,
            abi.encodeCall(switches.reclaim, (id, CAROL)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.RecoveryNotAvailable.selector)
        );
        vm.warp(START + 366 days);
        vm.expectEmit(true, true, false, true, address(switches));
        emit Reclaimed(id, ALICE, CAROL, 2 ether);
        vm.prank(ALICE);
        switches.reclaim(id, CAROL);
        assertEq(CAROL.balance, 102 ether);
        _reverts(
            BOB,
            abi.encodeCall(switches.claim, (id, BOB)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.ClosedSwitch.selector, id)
        );
        _assertInfo(id, ALICE, BOB, 0, 1 days, START, true);
        _assertConserved();
    }

    function test_beneficiaryCanWinAtRecoveryBoundary() public {
        uint256 id = _create(ALICE, BOB, 2 ether, 1 days);
        vm.warp(START + 366 days);
        vm.prank(BOB);
        switches.claim(id, BOB);
        _reverts(
            ALICE,
            abi.encodeCall(switches.reclaim, (id, ALICE)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.ClosedSwitch.selector, id)
        );
        assertEq(BOB.balance, 102 ether);
        _assertConserved();
    }

    function test_recoveryDeadlineUsesLatestPingAndPeriod() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 12 hours);
        vm.prank(ALICE);
        switches.setPeriod(id, 2 days);
        vm.warp(START + 366 days);
        _reverts(
            ALICE,
            abi.encodeCall(switches.reclaim, (id, ALICE)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.RecoveryNotAvailable.selector)
        );
        vm.warp(START + 367 days + 12 hours);
        vm.prank(ALICE);
        switches.reclaim(id, ALICE);
        assertEq(ALICE.balance, 100 ether);
    }

    function test_zeroBalanceCanBeClaimedOrReclaimedAndStillCloses() public {
        uint256 claimId = _create(ALICE, BOB, 0, 1 days);
        uint256 reclaimId = _create(ALICE, BOB, 0, 1 days);
        vm.warp(START + 366 days);
        vm.prank(BOB);
        switches.claim(claimId, CAROL);
        vm.prank(ALICE);
        switches.reclaim(reclaimId, CAROL);
        _assertInfo(claimId, ALICE, BOB, 0, 1 days, START, true);
        _assertInfo(reclaimId, ALICE, BOB, 0, 1 days, START, true);
        _assertConserved();
    }

    function test_everyMutationRevertsAfterEitherClosureWhileHistoryRemainsReadable() public {
        uint256 claimId = _create(ALICE, BOB, 1 ether, 1 days);
        uint256 reclaimId = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 366 days);
        vm.prank(BOB);
        switches.claim(claimId, BOB);
        vm.prank(ALICE);
        switches.reclaim(reclaimId, ALICE);
        for (uint256 id = 1; id <= 2; ++id) {
            bytes memory reason = abi.encodeWithSelector(DeadMansSwitch.ClosedSwitch.selector, id);
            _depositorCallsRevert(id, ALICE, reason);
            _reverts(BOB, abi.encodeCall(switches.claim, (id, BOB)), 0, reason);
            _reverts(ALICE, abi.encodeCall(switches.reclaim, (id, ALICE)), 0, reason);
            assertEq(switches.timeLeft(id), 0);
            _assertInfo(id, ALICE, BOB, 0, 1 days, START, true);
        }
        _assertConserved();
    }

    function test_nonexistentIdsRevertForAllOperationsAndViews() public {
        _create(ALICE, BOB, 1 ether, 1 days);
        uint256[3] memory invalid = [uint256(0), 2, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            uint256 id = invalid[i];
            bytes memory reason = abi.encodeWithSelector(DeadMansSwitch.UnknownSwitch.selector, id);
            _depositorCallsRevert(id, ALICE, reason);
            _reverts(BOB, abi.encodeCall(switches.claim, (id, BOB)), 0, reason);
            _reverts(ALICE, abi.encodeCall(switches.reclaim, (id, ALICE)), 0, reason);
            vm.expectRevert(reason);
            switches.switchInfo(id);
            vm.expectRevert(reason);
            switches.timeLeft(id);
        }
        _assertConserved();
    }

    function test_zeroPayoutRecipientsRevertWithoutClosing() public {
        uint256 id = _create(ALICE, BOB, 1 ether, 1 days);
        vm.warp(START + 366 days);
        bytes memory reason = abi.encodeWithSelector(DeadMansSwitch.InvalidRecipient.selector);
        _reverts(BOB, abi.encodeCall(switches.claim, (id, address(0))), 0, reason);
        _reverts(ALICE, abi.encodeCall(switches.reclaim, (id, address(0))), 0, reason);
        _assertInfo(id, ALICE, BOB, 1 ether, 1 days, START, false);
        _assertConserved();
    }

    function test_rejectedWithdrawRollsBackBalanceClockAndGuard() public {
        RejectingReceiver receiver = new RejectingReceiver();
        vm.deal(address(receiver), 3 ether);
        uint256 id = _create(address(receiver), BOB, 2 ether, 1 days);
        vm.warp(START + 12 hours);
        _reverts(
            address(receiver),
            abi.encodeCall(switches.withdraw, (id, 1 ether)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.EtherTransferFailed.selector)
        );
        _assertInfo(id, address(receiver), BOB, 2 ether, 1 days, START, false);
        receiver.acceptEther();
        vm.prank(address(receiver));
        switches.withdraw(id, 1 ether);
        assertEq(address(receiver).balance, 2 ether);
        _assertInfo(id, address(receiver), BOB, 1 ether, 1 days, START + 12 hours, false);
        _assertConserved();
    }

    function test_rejectedClaimAndReclaimAreRetryableAndDoNotFreezeOtherSwitches() public {
        RejectingReceiver receiver = new RejectingReceiver();
        uint256 claimId = _create(ALICE, address(receiver), 2 ether, 1 days);
        uint256 reclaimId = _create(ALICE, BOB, 3 ether, 1 days);
        vm.warp(START + 366 days);
        bytes memory reason = abi.encodeWithSelector(DeadMansSwitch.EtherTransferFailed.selector);
        _reverts(address(receiver), abi.encodeCall(switches.claim, (claimId, address(receiver))), 0, reason);
        _reverts(ALICE, abi.encodeCall(switches.reclaim, (reclaimId, address(receiver))), 0, reason);
        _assertInfo(claimId, ALICE, address(receiver), 2 ether, 1 days, START, false);
        _assertInfo(reclaimId, ALICE, BOB, 3 ether, 1 days, START, false);
        vm.prank(ALICE);
        switches.reclaim(reclaimId, CAROL);
        vm.prank(address(receiver));
        switches.claim(claimId, CAROL);
        assertEq(CAROL.balance, 105 ether);
        _assertConserved();
    }

    function test_evenZeroValueSettlementCallsReceiverAndCanBeRetried() public {
        RejectingReceiver receiver = new RejectingReceiver();
        uint256 id = _create(ALICE, BOB, 0, 1 days);
        vm.warp(START + 366 days);
        bytes memory reason = abi.encodeWithSelector(DeadMansSwitch.EtherTransferFailed.selector);
        _reverts(BOB, abi.encodeCall(switches.claim, (id, address(receiver))), 0, reason);
        _reverts(ALICE, abi.encodeCall(switches.reclaim, (id, address(receiver))), 0, reason);
        vm.prank(BOB);
        switches.claim(id, CAROL);
        _assertInfo(id, ALICE, BOB, 0, 1 days, START, true);
    }

    function test_separateSwitchesCannotSpendEachOthersBalances() public {
        uint256 first = _create(ALICE, BOB, 1 ether, 1 days);
        uint256 second = _create(CAROL, BOB, 7 ether, 365 days);
        _reverts(
            ALICE,
            abi.encodeCall(switches.withdraw, (first, 2 ether)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.InvalidAmount.selector)
        );
        _reverts(
            ALICE,
            abi.encodeCall(switches.withdraw, (second, 1 ether)),
            0,
            abi.encodeWithSelector(DeadMansSwitch.UnauthorizedDepositor.selector)
        );
        vm.warp(START + 1 days);
        vm.prank(BOB);
        switches.claim(first, BOB);
        assertEq(address(switches).balance, 7 ether);
        _assertInfo(second, CAROL, BOB, 7 ether, 365 days, START, false);
        vm.prank(CAROL);
        switches.withdraw(second, 7 ether);
        _assertConserved();
    }

    function test_plainEtherAndUnknownSelectorsAreRejected() public {
        vm.prank(ALICE);
        (bool emptyOk,) = address(switches).call{value: 1 ether}("");
        assertFalse(emptyOk);
        vm.prank(ALICE);
        (bool dataOk,) = address(switches).call{value: 1 ether}(hex"12345678");
        assertFalse(dataOk);
        assertEq(ALICE.balance, 100 ether);
        _assertConserved();
    }

    function test_forcedEtherSurplusDoesNotIncreaseAnySwitchPayout() public {
        uint256 id = _create(ALICE, BOB, 2 ether, 1 days);
        // Model an EVM-forced balance increase, which cannot be rejected by receive/fallback.
        vm.deal(address(switches), 7 ether);
        vm.warp(START + 1 days);
        vm.prank(BOB);
        switches.claim(id, BOB);
        assertEq(BOB.balance, 102 ether);
        assertEq(address(switches).balance, 5 ether);
        _assertInfo(id, ALICE, BOB, 0, 1 days, START, true);
    }

    function _create(address depositor, address beneficiary, uint256 value, uint256 period) private returns (uint256) {
        vm.prank(depositor);
        return switches.create{value: value}(beneficiary, period);
    }

    function _depositorCallsRevert(uint256 id, address caller, bytes memory reason) private {
        _reverts(caller, abi.encodeCall(switches.ping, (id)), 0, reason);
        _reverts(caller, abi.encodeCall(switches.deposit, (id)), 1, reason);
        _reverts(caller, abi.encodeCall(switches.withdraw, (id, 1)), 0, reason);
        _reverts(caller, abi.encodeCall(switches.setBeneficiary, (id, CAROL)), 0, reason);
        _reverts(caller, abi.encodeCall(switches.setPeriod, (id, 2 days)), 0, reason);
    }

    function _reverts(address caller, bytes memory data, uint256 value, bytes memory reason) private {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(switches).call{value: value}(data);
        assertFalse(ok, "call unexpectedly succeeded");
        assertEq(result, reason, "unexpected revert reason");
    }

    function _assertInfo(
        uint256 id,
        address depositor,
        address beneficiary,
        uint256 balance,
        uint256 period,
        uint256 lastPing,
        bool closed
    ) private view {
        (
            address actualDepositor,
            address actualBeneficiary,
            uint256 actualBalance,
            uint256 actualPeriod,
            uint256 actualPing,
            bool actualClosed
        ) = switches.switchInfo(id);
        assertEq(actualDepositor, depositor);
        assertEq(actualBeneficiary, beneficiary);
        assertEq(actualBalance, balance);
        assertEq(actualPeriod, period);
        assertEq(actualPing, lastPing);
        assertEq(actualClosed, closed);
    }

    function _assertConserved() private view {
        uint256 total;
        for (uint256 id = 1; id <= switches.switchCount(); ++id) {
            (,, uint256 balance,,, bool closed) = switches.switchInfo(id);
            if (closed) assertEq(balance, 0);
            else total += balance;
        }
        assertEq(address(switches).balance, total);
    }
}
