// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VelloraPixVault} from "../../src/VelloraPixVault.sol";

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// Fake DEX: pulls `amountIn` of the reserve from msg.sender and delivers `amountOut` of tokenOut (or native coin) to `to`.
contract MockDex {
    MockERC20 public immutable reserve;
    MockERC20 public immutable tokenOut;

    constructor(MockERC20 r, MockERC20 t) {
        reserve = r;
        tokenOut = t;
    }

    receive() external payable {}

    function swap(uint256 amountIn, uint256 amountOut, address to) external {
        reserve.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.mint(to, amountOut);
    }

    function swapToNative(uint256 amountIn, uint256 amountOut, address to) external {
        reserve.transferFrom(msg.sender, address(this), amountIn);
        (bool ok,) = payable(to).call{value: amountOut}("");
        require(ok, "native");
    }

    /// Delivers to itself (the user receives nothing).
    function swapKeepOutput(uint256 amountIn, uint256 amountOut) external {
        reserve.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.mint(address(this), amountOut);
    }

    /// Tries to re-enter the vault.
    function reenter(VelloraPixVault vault, bytes32 orderId, address to) external {
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](0);
        vault.executeBuy(orderId, to, address(tokenOut), 1, 0, address(this), calls);
    }
}

contract VelloraPixVaultTest is Test {
    VelloraPixVault vault;
    MockERC20 usdt;
    MockERC20 tkn;
    MockDex dex;
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdt = new MockERC20("Tether", "USDT", 18);
        tkn = new MockERC20("Token", "TKN", 18);
        dex = new MockDex(usdt, tkn);
        vm.deal(address(dex), 100 ether);
        vault = new VelloraPixVault(owner);
        vm.startPrank(owner);
        vault.setReserve(address(usdt));
        vault.setOperator(operator, true);
        vault.setAllowedTarget(address(dex), true);
        vault.setLimits(1_000e18, 5_000e18);
        vm.stopPrank();
        usdt.mint(address(vault), 10_000e18);
    }

    function _swapCall(uint256 amountIn, uint256 amountOut) internal view returns (VelloraPixVault.Call[] memory calls) {
        calls = new VelloraPixVault.Call[](1);
        calls[0] = VelloraPixVault.Call(address(dex), abi.encodeCall(MockDex.swap, (amountIn, amountOut, user)));
    }

    function test_executeBuy_happyPath_measuresDeliveryAndSpend() public {
        vm.prank(operator);
        (uint256 delivered, uint256 spent) =
            vault.executeBuy(keccak256("o1"), user, address(tkn), 100e18, 90e18, address(dex), _swapCall(100e18, 95e18));
        assertEq(delivered, 95e18);
        assertEq(spent, 100e18);
        assertEq(tkn.balanceOf(user), 95e18);
        assertEq(usdt.balanceOf(address(vault)), 9_900e18);
        assertEq(usdt.allowance(address(vault), address(dex)), 0, "approval reset");
        assertTrue(vault.usedOrders(keccak256("o1")));
    }

    function test_executeBuy_nativeOut() public {
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](1);
        calls[0] = VelloraPixVault.Call(address(dex), abi.encodeCall(MockDex.swapToNative, (100e18, 1 ether, user)));
        vm.prank(operator);
        (uint256 delivered,) = vault.executeBuy(keccak256("n1"), user, address(0), 100e18, 0.9 ether, address(dex), calls);
        assertEq(delivered, 1 ether);
        assertEq(user.balance, 1 ether);
    }

    function test_executeBuy_rejectsDuplicateOrder() public {
        vm.startPrank(operator);
        vault.executeBuy(keccak256("dup"), user, address(tkn), 10e18, 0, address(dex), _swapCall(10e18, 10e18));
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.OrderAlreadyUsed.selector, keccak256("dup")));
        vault.executeBuy(keccak256("dup"), user, address(tkn), 10e18, 0, address(dex), _swapCall(10e18, 10e18));
        vm.stopPrank();
    }

    function test_executeBuy_onlyOperator_andPause() public {
        vm.prank(stranger);
        vm.expectRevert(VelloraPixVault.NotOperator.selector);
        vault.executeBuy(keccak256("x"), user, address(tkn), 10e18, 0, address(dex), _swapCall(10e18, 10e18));

        vm.prank(owner);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));
        vault.executeBuy(keccak256("x"), user, address(tkn), 10e18, 0, address(dex), _swapCall(10e18, 10e18));
    }

    function test_executeBuy_rejectsTargetOrSpenderNotAllowed() public {
        MockDex other = new MockDex(usdt, tkn);
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](1);
        calls[0] = VelloraPixVault.Call(address(other), abi.encodeCall(MockDex.swap, (10e18, 10e18, user)));
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.TargetNotAllowed.selector, address(other)));
        vault.executeBuy(keccak256("t"), user, address(tkn), 10e18, 0, address(dex), calls);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.SpenderNotAllowed.selector, address(other)));
        vault.executeBuy(keccak256("s"), user, address(tkn), 10e18, 0, address(other), _swapCall(10e18, 10e18));
        vm.stopPrank();
    }

    function test_executeBuy_neverCallsReserveOrSelf() public {
        vm.prank(owner);
        vault.setAllowedTarget(address(usdt), true); // owner mistake: allowlisted the reserve
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](1);
        calls[0] = VelloraPixVault.Call(address(usdt), abi.encodeCall(IERC20.transfer, (stranger, 1e18)));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.TargetNotAllowed.selector, address(usdt)));
        vault.executeBuy(keccak256("r"), user, address(tkn), 10e18, 0, address(dex), calls);
    }

    function test_executeBuy_rejectsWhenUserNotDelivered_orBelowMinOut() public {
        VelloraPixVault.Call[] memory keep = new VelloraPixVault.Call[](1);
        keep[0] = VelloraPixVault.Call(address(dex), abi.encodeCall(MockDex.swapKeepOutput, (10e18, 10e18)));
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.InsufficientDelivery.selector, 0, 0));
        vault.executeBuy(keccak256("k"), user, address(tkn), 10e18, 0, address(dex), keep);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.InsufficientDelivery.selector, 5e18, 6e18));
        vault.executeBuy(keccak256("m"), user, address(tkn), 10e18, 6e18, address(dex), _swapCall(10e18, 5e18));
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(vault)), 10_000e18, "revert restores everything");
    }

    function test_executeBuy_rejectsOverspend_andNothingSpent() public {
        vm.startPrank(operator);
        // the DEX pulls 20 but the order only approved 10 → the mock's transferFrom fails → CallFailed
        vm.expectRevert();
        vault.executeBuy(keccak256("over"), user, address(tkn), 10e18, 0, address(dex), _swapCall(20e18, 20e18));
        // no calls: nothing spent
        VelloraPixVault.Call[] memory none = new VelloraPixVault.Call[](0);
        vm.expectRevert(VelloraPixVault.NothingSpent.selector);
        vault.executeBuy(keccak256("none"), user, address(tkn), 10e18, 0, address(dex), none);
        vm.stopPrank();
    }

    function test_limits_perOrderAndDaily() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.AboveMaxPerOrder.selector, 1_001e18, 1_000e18));
        vault.executeBuy(keccak256("big"), user, address(tkn), 1_001e18, 0, address(dex), _swapCall(1_001e18, 1e18));
        for (uint256 i = 0; i < 5; i++) {
            vault.executeBuy(keccak256(abi.encode("d", i)), user, address(tkn), 1_000e18, 0, address(dex), _swapCall(1_000e18, 1e18));
        }
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.AboveDailyCap.selector, 5_001e18, 5_000e18));
        vault.executeBuy(keccak256("d6"), user, address(tkn), 1e18, 0, address(dex), _swapCall(1e18, 1e18));
        vm.stopPrank();
        // next UTC day → the daily total resets
        vm.warp(block.timestamp + 1 days);
        usdt.mint(address(vault), 1_000e18);
        vm.prank(operator);
        vault.executeBuy(keccak256("d7"), user, address(tkn), 1e18, 0, address(dex), _swapCall(1e18, 1e18));
        assertEq(vault.spentToday(), 1e18);
    }

    function test_transferReserve_andWithdraw() public {
        vm.prank(operator);
        vault.transferReserve(keccak256("tr"), user, 50e18);
        assertEq(usdt.balanceOf(user), 50e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(VelloraPixVault.OrderAlreadyUsed.selector, keccak256("tr")));
        vault.transferReserve(keccak256("tr"), user, 50e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableUnauthorizedAccount(address)")), stranger));
        vault.withdraw(address(usdt), stranger, 1e18);
        vm.prank(owner);
        vault.withdraw(address(usdt), owner, 1e18);
        assertEq(usdt.balanceOf(owner), 1e18);
    }

    function test_setReserve_onlyWhenEmpty() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(owner);
        vm.expectRevert(VelloraPixVault.ReserveHasBalance.selector);
        vault.setReserve(address(usdc));
        vm.prank(owner);
        vault.withdraw(address(usdt), owner, 10_000e18);
        vm.prank(owner);
        vault.setReserve(address(usdc));
        assertEq(address(vault.reserve()), address(usdc));
    }

    function test_reentrancyBlocked() public {
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](1);
        calls[0] = VelloraPixVault.Call(address(dex), abi.encodeCall(MockDex.reenter, (vault, keccak256("re2"), user)));
        vm.prank(owner);
        vault.setOperator(address(dex), true);
        vm.prank(operator);
        vm.expectRevert(); // CallFailed(ReentrancyGuardReentrantCall)
        vault.executeBuy(keccak256("re1"), user, address(tkn), 10e18, 0, address(dex), calls);
    }
}
