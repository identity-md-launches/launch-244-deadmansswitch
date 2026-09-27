// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DeadMansSwitch} from "../src/DeadMansSwitch.sol";

/// @dev A constructor-context probe, not an implementation of the protocol's ProjectFactory.
contract ConstructorProbe {
    function deploy() external returns (LaunchToken token, DeadMansSwitch switches) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        switches = new DeadMansSwitch{salt: bytes32(uint256(2))}();
    }

    function tryPayableDeploy(bytes memory code) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(callvalue(), add(code, 32), mload(code))
        }
    }
}

contract DeploymentTest is Test {
    function test_factoryContextNeedsNoInitializationOrTokenBalanceInApplication() public {
        vm.chainId(11155111);
        ConstructorProbe factory = new ConstructorProbe();
        (LaunchToken token, DeadMansSwitch switches) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(switches)), 0);
        assertEq(switches.switchCount(), 0);
        address depositor = address(0xA11CE);
        vm.prank(depositor);
        uint256 id = switches.create(address(0xB0B), 1 days);
        (address recorded,,,,,) = switches.switchInfo(id);
        assertEq(recorded, depositor);
        vm.expectRevert(DeadMansSwitch.UnauthorizedDepositor.selector);
        vm.prank(address(factory));
        switches.ping(id);
        assertEq(token.balanceOf(address(factory)), 1e27);
    }

    function test_bothConstructorsAreNonpayable() public {
        ConstructorProbe probe = new ConstructorProbe();
        vm.deal(address(this), 2);
        assertEq(probe.tryPayableDeploy{value: 1}(type(LaunchToken).creationCode), address(0));
        assertEq(probe.tryPayableDeploy{value: 1}(type(DeadMansSwitch).creationCode), address(0));
    }

    function test_runtimesAreWithinSizeLimitAndHaveNoForbiddenOpcodes() public {
        LaunchToken token = new LaunchToken();
        DeadMansSwitch switches = new DeadMansSwitch();
        _checkRuntime(address(token).code);
        _checkRuntime(address(switches).code);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
