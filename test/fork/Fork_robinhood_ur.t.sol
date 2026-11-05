// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PixVaultForkBase} from "./PixVaultForkBase.sol";
import {DexKit} from "./DexKit.sol";
import {VelloraPixVault} from "../../src/VelloraPixVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Universal Router da Robinhood Chain — o caso do **campo extra**.
 *
 * O UR de lá é 2.1.1: o comando `V3_SWAP_EXACT_IN` ganhou um argumento por
 * salto, `minHopPriceX36` (`uint256[]`), que não existe no layout 1.2/2.0.
 * Calldata montada com o encoder antigo **reverte**. Este arquivo prova:
 *
 *   1. o layout antigo (5 campos) reverte — logo o campo extra é obrigatório;
 *   2. o layout 2.1.1 com o array de zeros funciona: zero = "sem piso por
 *      salto", que é o comportamento do 2.0. **Não afeta a entrega**: quem
 *      garante o valor final continua sendo o `amountOutMinimum` do comando e,
 *      por cima dele, a medição do cofre no destinatário.
 *
 * Fluxo de pagamento do UR: `payerIsUser = true` puxa via **Permit2**, então a
 * ordem tem 2 calls — `Permit2.approve(reserva, UR, amountIn, exp)` e o
 * `execute` — e o `spender` da ordem é a Permit2 (o cofre aprova só ela).
 *
 * forge test --match-contract Fork_robinhood_ur --fork-url https://rpc.mainnet.chain.robinhood.com -vv
 */
contract Fork_robinhood_ur is PixVaultForkBase {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904; // 2.1.1
    address constant QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        address[] memory targets = new address[](1);
        targets[0] = UNIVERSAL_ROUTER;
        _setUpVault(USDG, targets, 1_000, address(0)); // Permit2 já entra na allowlist na base
    }

    function _permit2(uint256 amountIn) internal pure returns (VelloraPixVault.Call memory) {
        return DexKit.permit2Approve(USDG, UNIVERSAL_ROUTER, uint160(amountIn), type(uint48).max);
    }

    function test_ur211_reserve_to_wrapped_with_minHopPrice() public {
        uint256 amountIn = units(100);
        bytes memory path = DexKit.v3Path(USDG, 100, WETH);
        uint256 q = quoteV3Path(QUOTER_V2, path, amountIn);
        uint256 minOut = withSlippage(q);
        (uint256 delivered,) = buy(
            "robinhood UR 2.1.1 USDG->WETH (minHopPriceX36 zerado)",
            WETH,
            amountIn,
            minOut,
            DexKit.PERMIT2,
            two(_permit2(amountIn), DexKit.urV3ExactIn211(UNIVERSAL_ROUTER, path, amountIn, minOut, user, 1))
        );
        assertEq(IERC20(WETH).balanceOf(user), delivered);
    }

    function test_ur211_reserve_to_native_unwrap() public {
        uint256 amountIn = units(100);
        bytes memory path = DexKit.v3Path(USDG, 100, WETH);
        uint256 q = quoteV3Path(QUOTER_V2, path, amountIn);
        uint256 minOut = withSlippage(q);
        uint256 before = user.balance;
        (uint256 delivered,) = buy(
            "robinhood UR 2.1.1 USDG->ETH nativo (UNWRAP_WETH)",
            address(0),
            amountIn,
            minOut,
            DexKit.PERMIT2,
            two(_permit2(amountIn), DexKit.urV3ExactIn211NativeOut(UNIVERSAL_ROUTER, path, amountIn, minOut, user, 1))
        );
        assertEq(user.balance - before, delivered);
    }

    /// O layout 1.2/2.0 (sem o campo extra) não serve nesta rede.
    function test_ur_legacyLayout_reverts_on_211() public {
        uint256 amountIn = units(100);
        bytes memory path = DexKit.v3Path(USDG, 100, WETH);
        uint256 q = quoteV3Path(QUOTER_V2, path, amountIn);
        VelloraPixVault.Call[] memory calls =
            two(_permit2(amountIn), DexKit.urV3ExactIn(UNIVERSAL_ROUTER, path, amountIn, withSlippage(q), user));
        vm.prank(operator);
        vm.expectRevert(); // CallFailed: o UR 2.1.1 não decodifica o input antigo
        vault.executeBuy(keccak256("legacy-layout"), user, WETH, amountIn, withSlippage(q), DexKit.PERMIT2, calls);
        assertEq(IERC20(USDG).balanceOf(address(vault)), units(1_000), "reserva intacta");
    }
}
