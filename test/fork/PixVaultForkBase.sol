// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VelloraPixVault} from "../../src/VelloraPixVault.sol";
import {DexKit, IQuoterV2, IV2Router} from "./DexKit.sol";

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/**
 * Base dos testes em fork: deploya o cofre, configura reserva/operador/alvos,
 * financia (deal → whale) e expõe `buy(...)` que executa e mede. Cada rede
 * tem um contrato `Fork_<key>` com os endereços verificados do levantamento.
 */
abstract contract PixVaultForkBase is Test {
    VelloraPixVault internal vault;
    address internal owner = makeAddr("vault-owner");
    address internal operator = makeAddr("vault-operator-7702");
    address internal user = makeAddr("pix-user");

    address internal reserve;
    uint8 internal reserveDecimals;

    /// `fundWhole` em unidades HUMANAS da reserva (ex.: 1_000 = 1.000 USDT).
    function _setUpVault(address reserve_, address[] memory targets, uint256 fundWhole, address whale) internal {
        reserve = reserve_;
        reserveDecimals = IERC20Meta(reserve_).decimals();
        uint256 fund = fundWhole * (10 ** reserveDecimals);
        vault = new VelloraPixVault(owner);
        vm.startPrank(owner);
        vault.setReserve(reserve_);
        vault.setOperator(operator, true);
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(0)) vault.setAllowedTarget(targets[i], true);
        }
        vault.setAllowedTarget(DexKit.PERMIT2, true);
        vault.setLimits(fund, 0);
        vm.stopPrank();
        _fund(fund, whale);
    }

    function _fund(uint256 amount, address whale) internal {
        // `deal` acha o slot do balance por sondagem; em tokens não-padrão (proxy,
        // storage exótico) pode falhar — cai no whale.
        try this._dealTo(reserve, address(vault), amount) {} catch {}
        if (IERC20(reserve).balanceOf(address(vault)) < amount && whale != address(0)) {
            vm.prank(whale);
            IERC20(reserve).transfer(address(vault), amount);
        }
        require(IERC20(reserve).balanceOf(address(vault)) >= amount, "fork: nao consegui financiar o cofre");
    }

    function _dealTo(address token, address to, uint256 amount) external {
        require(msg.sender == address(this), "self");
        deal(token, to, amount);
    }

    function units(uint256 whole) internal view returns (uint256) {
        return whole * (10 ** reserveDecimals);
    }

    /// Executa uma compra e imprime gas/entrega. Retorna (delivered, spent).
    function buy(
        string memory label,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address spender,
        VelloraPixVault.Call[] memory calls
    ) internal returns (uint256 delivered, uint256 spent) {
        bytes32 orderId = keccak256(abi.encodePacked(label, block.number));
        uint256 g0 = gasleft();
        vm.prank(operator);
        (delivered, spent) = vault.executeBuy(orderId, user, tokenOut, amountIn, minOut, spender, calls);
        uint256 gasUsed = g0 - gasleft();
        console2.log(string.concat("[", label, "] spent=", vm.toString(spent), " delivered=", vm.toString(delivered), " minOut=", vm.toString(minOut), " gas=", vm.toString(gasUsed)));
        assertGe(delivered, minOut, "entrega abaixo do minOut");
        assertLe(spent, amountIn, "gastou mais que amountIn");
        assertEq(IERC20(reserve).allowance(address(vault), spender), 0, "approve nao zerado");
    }

    function one(VelloraPixVault.Call memory c) internal pure returns (VelloraPixVault.Call[] memory calls) {
        calls = new VelloraPixVault.Call[](1);
        calls[0] = c;
    }

    function two(VelloraPixVault.Call memory a, VelloraPixVault.Call memory b)
        internal
        pure
        returns (VelloraPixVault.Call[] memory calls)
    {
        calls = new VelloraPixVault.Call[](2);
        calls[0] = a;
        calls[1] = b;
    }

    // ---------------------------------------------------------------- quotes

    function quoteV3(address quoterV2, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (amountOut,,,) =
            IQuoterV2(quoterV2).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, fee, 0));
    }

    function quoteV3Path(address quoterV2, bytes memory path, uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = IQuoterV2(quoterV2).quoteExactInput(path, amountIn);
    }

    function quoteV2(address router, address[] memory path, uint256 amountIn) internal view returns (uint256) {
        uint256[] memory amounts = IV2Router(router).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    /// 3% de folga sobre o quote (tolerância de fork/slippage; FOT fica de fora).
    function withSlippage(uint256 quoted) internal pure returns (uint256) {
        return (quoted * 97) / 100;
    }
}
