// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PixVaultForkBase} from "./PixVaultForkBase.sol";
import {DexKit} from "./DexKit.sol";
import {VelloraPixVault} from "../../src/VelloraPixVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniV3Pool {
    function liquidity() external view returns (uint128);
}

/**
 * Bateria comum "reserva → nativo (wrapped e desembrulhado) via Uniswap v3
 * SwapRouter02" — a família que existe em 7 das 8 redes-alvo (na BSC o
 * SwapRouter02 da Uniswap também existe, com factory próprio). Cada rede
 * herda, preenche os endereços verificados on-chain e ganha os mesmos testes.
 *
 * O que cada teste prova, do ponto de vista do cofre:
 *   - a calldata de um router real passa pela allowlist e executa;
 *   - a entrega é medida no DESTINATÁRIO e cobre o minOut do quoter;
 *   - o gasto nunca excede o amountIn e o approve volta a zero;
 *   - saída em nativo (multicall + unwrapWETH9) chega como saldo do usuário;
 *   - minOut impossível reverte a ordem inteira sem mover a reserva.
 */
abstract contract UniV3ForkSuite is PixVaultForkBase {
    address internal factory;
    address internal swapRouter02;
    address internal quoterV2;
    address internal wnative;
    address internal whale;
    string internal chainLabel;
    /// Fee tiers a testar, em ordem de preferência.
    uint24[] internal feeTiers;

    function _initUniV3(
        string memory label,
        string memory rpcEnv,
        string memory rpcFallback,
        address reserve_,
        address wnative_,
        address factory_,
        address swapRouter02_,
        address quoterV2_,
        address whale_,
        uint24[] memory fees
    ) internal {
        vm.createSelectFork(vm.envOr(rpcEnv, rpcFallback));
        chainLabel = label;
        factory = factory_;
        swapRouter02 = swapRouter02_;
        quoterV2 = quoterV2_;
        wnative = wnative_;
        whale = whale_;
        feeTiers = fees;
        address[] memory targets = new address[](1);
        targets[0] = swapRouter02_;
        _setUpVault(reserve_, targets, 1_000, whale_);
    }

    /// Primeiro fee tier com pool, liquidez > 0 e quote > 0 para 100 da reserva.
    function _bestFee(uint256 amountIn) internal returns (uint24 fee, uint256 quoted) {
        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = IUniV3Factory(factory).getPool(reserve, wnative, feeTiers[i]);
            if (pool == address(0) || IUniV3Pool(pool).liquidity() == 0) continue;
            try this._quote(quoterV2, reserve, wnative, feeTiers[i], amountIn) returns (uint256 out) {
                if (out > 0) return (feeTiers[i], out);
            } catch {}
        }
        revert("nenhum pool reserva/wnative com liquidez e quote");
    }

    function _quote(address q, address tIn, address tOut, uint24 fee, uint256 amountIn)
        external
        returns (uint256 out)
    {
        require(msg.sender == address(this), "self");
        return quoteV3(q, tIn, tOut, fee, amountIn);
    }

    function test_uniV3_reserve_to_wrappedNative() public {
        uint256 amountIn = units(100);
        (uint24 fee, uint256 q) = _bestFee(amountIn);
        uint256 minOut = withSlippage(q);
        (uint256 delivered,) = buy(
            string.concat(chainLabel, " uni-v3 reserva->wNative fee", vm.toString(uint256(fee))),
            wnative,
            amountIn,
            minOut,
            swapRouter02,
            one(DexKit.srExactInputSingle(swapRouter02, reserve, wnative, fee, user, amountIn, minOut))
        );
        assertEq(IERC20(wnative).balanceOf(user), delivered, "wrapped foi para o usuario");
    }

    function test_uniV3_reserve_to_native_unwrap() public {
        uint256 amountIn = units(100);
        (uint24 fee, uint256 q) = _bestFee(amountIn);
        uint256 minOut = withSlippage(q);
        uint256 before = user.balance;
        (uint256 delivered,) = buy(
            string.concat(chainLabel, " uni-v3 reserva->NATIVO (multicall+unwrap)"),
            address(0),
            amountIn,
            minOut,
            swapRouter02,
            one(DexKit.srExactInputSingleNativeOut(swapRouter02, reserve, wnative, fee, user, amountIn, minOut))
        );
        assertEq(user.balance - before, delivered, "nativo chegou ao usuario");
    }

    function test_uniV3_minOut_impossible_reverts_without_spending() public {
        uint256 amountIn = units(100);
        (uint24 fee, uint256 q) = _bestFee(amountIn);
        uint256 balanceBefore = IERC20(reserve).balanceOf(address(vault));
        VelloraPixVault.Call[] memory calls =
            one(DexKit.srExactInputSingle(swapRouter02, reserve, wnative, fee, user, amountIn, q * 2));
        vm.prank(operator);
        vm.expectRevert();
        vault.executeBuy(keccak256("impossible"), user, wnative, amountIn, q * 2, swapRouter02, calls);
        assertEq(IERC20(reserve).balanceOf(address(vault)), balanceBefore, "reserva intacta");
        assertEq(IERC20(reserve).allowance(address(vault), swapRouter02), 0, "sem approve residual");
    }

    function test_reserveOut_transfer() public {
        vm.prank(operator);
        vault.transferReserve(keccak256("reserve-out"), user, units(50));
        assertEq(IERC20(reserve).balanceOf(user), units(50));
    }

    /// O cofre recusa entregar a própria reserva por `executeBuy` (só por transferReserve).
    function test_rejects_tokenOut_equal_reserve() public {
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](0);
        vm.prank(operator);
        vm.expectRevert(VelloraPixVault.InvalidTokenOut.selector);
        vault.executeBuy(keccak256("bad"), user, reserve, units(10), 0, swapRouter02, calls);
    }
}
