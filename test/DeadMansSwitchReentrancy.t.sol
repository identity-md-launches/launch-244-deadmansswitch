// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeadMansSwitch} from "../src/DeadMansSwitch.sol";

contract CallbackReceiver {
    DeadMansSwitch private immutable switches;
    uint256 private observedId;
    bytes private attack;
    uint256 private attackValue;
    bool private armed;
    bool private rejectAfterAttack;
    bool public attempted;
    bool public succeeded;
    bytes public result;
    uint256 public observedBalance;
    uint256 public observedPing;
    bool public observedClosed;

    constructor(DeadMansSwitch target) {
        switches = target;
    }

    function arm(uint256 id, bytes memory payload, uint256 value, bool reject) external {
        observedId = id;
        attack = payload;
        attackValue = value;
        rejectAfterAttack = reject;
        attempted = false;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        (,, observedBalance,, observedPing, observedClosed) = switches.switchInfo(observedId);
        attempted = true;
        (succeeded, result) = address(switches).call{value: attackValue}(attack);
        require(!rejectAfterAttack, "reject after callback");
    }
}

contract DeadMansSwitchReentrancyTest is Test {
    DeadMansSwitch private switches;
    CallbackReceiver private receiver;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        vm.warp(100 days);
        switches = new DeadMansSwitch();
        receiver = new CallbackReceiver(switches);
        vm.deal(address(receiver), 100 ether);
        vm.deal(ALICE, 100 ether);
    }

    function test_withdrawReentryFailsAndCallbackSeesEffectsAlreadyApplied() public {
        uint256 id = _create(address(receiver), BOB, 3 ether);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        receiver.arm(id, abi.encodeCall(switches.withdraw, (id, 1 ether)), 0, false);
        vm.prank(address(receiver));
        switches.withdraw(id, 1 ether);
        _assertAttackBlocked(2 ether, false);
        assertEq(receiver.observedPing(), vm.getBlockTimestamp());
        assertEq(address(switches).balance, 2 ether);
        assertEq(address(receiver).balance, 98 ether);
    }

    function test_claimReentryFailsAndCallbackSeesClosedZeroBalance() public {
        uint256 id = _create(ALICE, address(receiver), 3 ether);
        vm.warp(block.timestamp + 1 days);
        receiver.arm(id, abi.encodeCall(switches.claim, (id, address(receiver))), 0, false);
        vm.prank(address(receiver));
        switches.claim(id, address(receiver));
        _assertAttackBlocked(0, true);
        assertEq(address(switches).balance, 0);
        assertEq(address(receiver).balance, 103 ether);
    }

    function test_reclaimReentryFailsAndCallbackSeesClosedZeroBalance() public {
        uint256 id = _create(address(receiver), BOB, 3 ether);
        vm.warp(block.timestamp + 366 days);
        receiver.arm(id, abi.encodeCall(switches.reclaim, (id, address(receiver))), 0, false);
        vm.prank(address(receiver));
        switches.reclaim(id, address(receiver));
        _assertAttackBlocked(0, true);
        assertEq(address(switches).balance, 0);
        assertEq(address(receiver).balance, 100 ether);
    }

    function test_withdrawCallbackCannotMutateAnyOtherSwitchOrCreateOne() public {
        uint256 recoveryId = _create(address(receiver), BOB, 2 ether);
        uint256 claimId = _create(ALICE, address(receiver), 2 ether);
        vm.warp(block.timestamp + 366 days);
        uint256 sourceId = _create(address(receiver), BOB, 10 ether);
        uint256 activeId = _create(address(receiver), BOB, 2 ether);
        bytes[8] memory payloads = [
            abi.encodeCall(switches.create, (BOB, 1 days)),
            abi.encodeCall(switches.ping, (activeId)),
            abi.encodeCall(switches.deposit, (activeId)),
            abi.encodeCall(switches.withdraw, (activeId, 1 ether)),
            abi.encodeCall(switches.setBeneficiary, (activeId, ALICE)),
            abi.encodeCall(switches.setPeriod, (activeId, 2 days)),
            abi.encodeCall(switches.claim, (claimId, address(receiver))),
            abi.encodeCall(switches.reclaim, (recoveryId, address(receiver)))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            receiver.arm(sourceId, payloads[i], i == 2 ? 1 ether : 0, false);
            vm.prank(address(receiver));
            switches.withdraw(sourceId, 1 ether);
            _assertAttackBlocked((9 - i) * 1 ether, false);
        }
        assertEq(switches.switchCount(), 4);
        assertEq(address(switches).balance, 8 ether);
        for (uint256 id = 1; id <= 4; ++id) {
            (,, uint256 balance, uint256 period,, bool closed) = switches.switchInfo(id);
            assertEq(balance, 2 ether);
            assertEq(period, 1 days);
            assertFalse(closed);
        }
    }

    function test_claimCallbackCannotWinDepositorRecoveryOnAnotherSwitch() public {
        uint256 claimed = _create(ALICE, address(receiver), 1 ether);
        uint256 recovered = _create(address(receiver), BOB, 3 ether);
        vm.warp(block.timestamp + 366 days);
        receiver.arm(claimed, abi.encodeCall(switches.reclaim, (recovered, address(receiver))), 0, false);
        vm.prank(address(receiver));
        switches.claim(claimed, address(receiver));
        _assertAttackBlocked(0, true);
        assertEq(address(switches).balance, 3 ether);
        vm.prank(address(receiver));
        switches.reclaim(recovered, address(receiver));
        assertEq(address(switches).balance, 0);
    }

    function test_reclaimCallbackCannotClaimAnotherSwitch() public {
        uint256 reclaimed = _create(address(receiver), BOB, 1 ether);
        uint256 claimed = _create(ALICE, address(receiver), 3 ether);
        vm.warp(block.timestamp + 366 days);
        receiver.arm(reclaimed, abi.encodeCall(switches.claim, (claimed, address(receiver))), 0, false);
        vm.prank(address(receiver));
        switches.reclaim(reclaimed, address(receiver));
        _assertAttackBlocked(0, true);
        assertEq(address(switches).balance, 3 ether);
        vm.prank(address(receiver));
        switches.claim(claimed, address(receiver));
        assertEq(address(switches).balance, 0);
    }

    function test_callbackRejectionRollsBackOuterWithdrawalAndGuard() public {
        uint256 id = _create(address(receiver), BOB, 3 ether);
        uint256 originalPing = vm.getBlockTimestamp();
        vm.warp(originalPing + 12 hours);
        receiver.arm(id, abi.encodeCall(switches.withdraw, (id, 1 ether)), 0, true);
        vm.expectRevert(DeadMansSwitch.EtherTransferFailed.selector);
        vm.prank(address(receiver));
        switches.withdraw(id, 1 ether);
        (,, uint256 balance,, uint256 lastPing, bool closed) = switches.switchInfo(id);
        assertEq(balance, 3 ether);
        assertEq(lastPing, originalPing);
        assertFalse(closed);
        assertEq(address(switches).balance, 3 ether);
        receiver.arm(id, abi.encodeCall(switches.withdraw, (id, 1 ether)), 0, false);
        vm.prank(address(receiver));
        switches.withdraw(id, 1 ether);
        _assertAttackBlocked(2 ether, false);
    }

    function _create(address depositor, address beneficiary, uint256 amount) private returns (uint256) {
        vm.prank(depositor);
        return switches.create{value: amount}(beneficiary, 1 days);
    }

    function _assertAttackBlocked(uint256 balance, bool closed) private view {
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(receiver.result(), abi.encodeWithSelector(DeadMansSwitch.ReentrantCall.selector));
        assertEq(receiver.observedBalance(), balance);
        assertEq(receiver.observedClosed(), closed);
    }
}
