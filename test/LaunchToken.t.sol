// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SUPPLY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndEntireSupplyMintedOnceToDeployer() public {
        assertEq(token.name(), "Heartbeat");
        assertEq(token.symbol(), "BEAT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        LaunchToken another = new LaunchToken();
        assertEq(another.balanceOf(ALICE), SUPPLY);
        assertEq(another.balanceOf(address(this)), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB) + token.balanceOf(address(this)), SUPPLY);
    }

    function test_selfAndZeroTransfers() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_approveReplaceRevokeAndFiniteTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 100);
        assertTrue(token.approve(ALICE, 100));
        assertEq(token.allowance(address(this), ALICE), 100);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 60));
        assertEq(token.allowance(address(this), ALICE), 40);
        assertEq(token.balanceOf(BOB), 60);
        assertTrue(token.approve(ALICE, 7));
        assertEq(token.allowance(address(this), ALICE), 7);
        assertTrue(token.approve(ALICE, 0));
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_infiniteApprovalIsNotConsumed() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, SUPPLY);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), SUPPLY);
    }

    function test_transferFromSelfConsumesAllowanceWithoutChangingBalance() public {
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        token.transferFrom(address(this), address(this), 80);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), ALICE), 20);
    }

    function test_insufficientBalanceAndAllowanceRevertWithoutChanges() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        token.approve(ALICE, SUPPLY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, SUPPLY + 1);
        assertEq(token.allowance(address(this), ALICE), SUPPLY + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroAddressesRejectedAndFailedTransferFromRestoresAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(ALICE, 10);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), ALICE), 10);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
    }

    function test_noAdministrativeOrMintEntryPointsForAnyone() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], BOB, SUPPLY);
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded);
            vm.prank(ALICE);
            (bool strangerSucceeded,) = address(token).call(data);
            assertFalse(strangerSucceeded);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_plainEtherRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }
}
