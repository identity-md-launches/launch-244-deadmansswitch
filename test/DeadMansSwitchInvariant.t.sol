// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeadMansSwitch} from "../src/DeadMansSwitch.sol";

/// @dev Generates real funded operations from several independent accounts. No direct funding
/// of the switch contract, no environment variables, and no swallowed unexpected reverts.
contract SwitchHandler is Test {
    DeadMansSwitch public immutable switches;
    address[4] private actors = [address(0xA1), address(0xB2), address(0xC3), address(0xD4)];
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public created;
    mapping(uint256 => uint256) public expectedBalance;
    mapping(uint256 => bool) public expectedClosed;

    constructor(DeadMansSwitch target) {
        switches = target;
    }

    function create(uint256 actorSeed, uint256 amount, uint256 period) external {
        if (created >= 24) return;
        address depositor = actors[actorSeed % 4];
        address beneficiary = actors[(actorSeed % 4 + 1) % 4];
        amount = bound(amount, 0, 5 ether);
        period = bound(period, 1 days, 365 days);
        vm.deal(depositor, depositor.balance + amount);
        vm.prank(depositor);
        uint256 id = switches.create{value: amount}(beneficiary, period);
        ++created;
        assertEq(id, created);
        expectedBalance[id] = amount;
        totalIn += amount;
    }

    function deposit(uint256 seed, uint256 amount) external {
        uint256 id = _id(seed);
        (address depositor,, bool active) = _active(id);
        if (!active) return;
        amount = bound(amount, 1, 5 ether);
        vm.deal(depositor, depositor.balance + amount);
        vm.prank(depositor);
        switches.deposit{value: amount}(id);
        totalIn += amount;
        expectedBalance[id] += amount;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        uint256 id = _id(seed);
        (address depositor, uint256 balance, bool active) = _active(id);
        if (!active || balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 before = depositor.balance;
        vm.prank(depositor);
        switches.withdraw(id, amount);
        assertEq(depositor.balance, before + amount);
        totalOut += amount;
        expectedBalance[id] -= amount;
    }

    function ping(uint256 seed) external {
        uint256 id = _id(seed);
        (address depositor,, bool active) = _active(id);
        if (!active) return;
        vm.prank(depositor);
        switches.ping(id);
    }

    function changePeriod(uint256 seed, uint256 period) external {
        uint256 id = _id(seed);
        (address depositor,, bool active) = _active(id);
        if (!active) return;
        period = bound(period, 1 days, 365 days);
        vm.prank(depositor);
        switches.setPeriod(id, period);
    }

    function changeBeneficiary(uint256 seed, uint256 actorSeed) external {
        uint256 id = _id(seed);
        (address depositor,, bool active) = _active(id);
        if (!active) return;
        address beneficiary = actors[actorSeed % 4];
        if (beneficiary == depositor) beneficiary = actors[(actorSeed % 4 + 1) % 4];
        vm.prank(depositor);
        switches.setBeneficiary(id, beneficiary);
    }

    function settle(uint256 seed, bool recovery, uint256 recipientSeed) external {
        uint256 id = _id(seed);
        (address depositor, address beneficiary, uint256 balance, uint256 period, uint256 lastPing, bool closed) =
            switches.switchInfo(id);
        if (closed || block.timestamp < lastPing + period + (recovery ? 365 days : 0)) return;
        address recipient = actors[recipientSeed % 4];
        uint256 before = recipient.balance;
        vm.prank(recovery ? depositor : beneficiary);
        if (recovery) switches.reclaim(id, recipient);
        else switches.claim(id, recipient);
        assertEq(recipient.balance, before + balance);
        totalOut += balance;
        expectedBalance[id] = 0;
        expectedClosed[id] = true;
    }

    function advanceTime(uint256 seed, uint256 mode) external {
        (,,, uint256 period, uint256 lastPing,) = switches.switchInfo(_id(seed));
        uint256 target;
        if (mode % 4 == 0) target = block.timestamp + 1 hours;
        else if (mode % 4 == 1) target = lastPing + period - 1;
        else if (mode % 4 == 2) target = lastPing + period;
        else target = lastPing + period + 365 days;
        if (target > block.timestamp) vm.warp(target);
    }

    function unauthorized(uint256 seed, uint8 action) external {
        uint256 id = _id(seed);
        bytes memory payload;
        uint256 value;
        if (action % 7 == 0) {
            payload = abi.encodeCall(switches.ping, (id));
        } else if (action % 7 == 1) {
            payload = abi.encodeCall(switches.deposit, (id));
            value = 1;
        } else if (action % 7 == 2) {
            payload = abi.encodeCall(switches.withdraw, (id, 1));
        } else if (action % 7 == 3) {
            payload = abi.encodeCall(switches.setPeriod, (id, 1 days));
        } else if (action % 7 == 4) {
            payload = abi.encodeCall(switches.setBeneficiary, (id, address(0xBAD)));
        } else if (action % 7 == 5) {
            payload = abi.encodeCall(switches.claim, (id, address(0xBAD)));
        } else {
            payload = abi.encodeCall(switches.reclaim, (id, address(0xBAD)));
        }
        vm.deal(address(0xBAD), 1);
        bytes memory before = _snapshot(id);
        vm.prank(address(0xBAD));
        (bool ok,) = address(switches).call{value: value}(payload);
        assertFalse(ok, "unauthorized mutation");
        assertEq(_snapshot(id), before);
    }

    function _id(uint256 seed) private view returns (uint256) {
        return 1 + seed % created;
    }

    function _active(uint256 id) private view returns (address depositor, uint256 balance, bool active) {
        uint256 period;
        uint256 lastPing;
        bool closed;
        (depositor,, balance, period, lastPing, closed) = switches.switchInfo(id);
        active = !closed && block.timestamp < lastPing + period;
    }

    function _snapshot(uint256 id) private view returns (bytes memory) {
        (address depositor, address beneficiary, uint256 balance, uint256 period, uint256 lastPing, bool closed) =
            switches.switchInfo(id);
        return abi.encode(depositor, beneficiary, balance, period, lastPing, closed);
    }
}

contract DeadMansSwitchInvariantTest is StdInvariant, Test {
    DeadMansSwitch private switches;
    SwitchHandler private handler;

    function setUp() public {
        vm.warp(100 days);
        switches = new DeadMansSwitch();
        handler = new SwitchHandler(switches);
        handler.create(0, 1 ether, 1 days);
        handler.create(1, 3 ether, 365 days);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.deposit.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.ping.selector;
        selectors[4] = handler.changePeriod.selector;
        selectors[5] = handler.changeBeneficiary.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.unauthorized.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ethEqualsOpenBalancesAndNetDeposits() public view {
        uint256 sum;
        assertEq(switches.switchCount(), handler.created());
        for (uint256 id = 1; id <= switches.switchCount(); ++id) {
            (,, uint256 balance,,, bool closed) = switches.switchInfo(id);
            assertEq(balance, handler.expectedBalance(id), "cross-switch accounting mismatch");
            assertEq(closed, handler.expectedClosed(id), "unexpected closure state");
            if (closed) assertEq(balance, 0);
            else sum += balance;
        }
        assertEq(address(switches).balance, sum);
        assertEq(address(switches).balance, handler.totalIn() - handler.totalOut());
    }

    /// @dev Every generated balance can eventually be collected independently; none remains stuck.
    function afterInvariant() public {
        vm.warp(block.timestamp + 731 days);
        for (uint256 id = 1; id <= switches.switchCount(); ++id) {
            (address depositor,, uint256 balance,,, bool closed) = switches.switchInfo(id);
            if (closed) continue;
            uint256 before = depositor.balance;
            vm.prank(depositor);
            switches.reclaim(id, depositor);
            assertEq(depositor.balance, before + balance);
        }
        assertEq(address(switches).balance, 0);
    }
}
