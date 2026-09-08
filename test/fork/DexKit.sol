// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {VelloraPixVault} from "../../src/VelloraPixVault.sol";

/**
 * Monta as `Call[]` que o cofre executa contra cada família de DEX. As ABIs
 * são as canônicas:
 *  - Uniswap v3 SwapRouter02 / PancakeSwap SmartRouter v3: exactInputSingle
 *    SEM deadline, ADDRESS_THIS = address(2), unwrapWETH9(amountMin, recipient),
 *    multicall(bytes[]).
 *  - Routers V2-like (Pancake V2, QuickSwap, Trader Joe v1, Pangolin):
 *    swapExactTokensForTokens / swapExactTokensForETH (5 args).
 *  - Universal Router 1.2 / 2.0: execute(bytes,bytes[],uint256) com
 *    V3_SWAP_EXACT_IN (0x00) e UNWRAP_WETH (0x0c); pagamento via Permit2
 *    (payerIsUser=true) → o cofre aprova a Permit2 e chama
 *    Permit2.approve(token, ur, amount, expiration) na mesma ordem.
 */
library DexKit {
    address internal constant ADDRESS_THIS = address(2);
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes1 internal constant UR_V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant UR_UNWRAP_WETH = 0x0c;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    // ------------------------------------------------ SwapRouter02 / SmartRouter

    function srExactInputSingle(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 minOut
    ) internal pure returns (VelloraPixVault.Call memory) {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")),
            ExactInputSingleParams(tokenIn, tokenOut, fee, recipient, amountIn, minOut, 0)
        );
        return VelloraPixVault.Call(router, data);
    }

    function srExactInput(address router, bytes memory path, address recipient, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (VelloraPixVault.Call memory)
    {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("exactInput((bytes,address,uint256,uint256))")),
            ExactInputParams(path, recipient, amountIn, minOut)
        );
        return VelloraPixVault.Call(router, data);
    }

    /// swap para o wrapped com recipient = router (ADDRESS_THIS) + unwrapWETH9 para o usuário, numa multicall.
    function srExactInputSingleNativeOut(
        address router,
        address tokenIn,
        address wnative,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 minOut
    ) internal pure returns (VelloraPixVault.Call memory) {
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeWithSelector(
            bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")),
            ExactInputSingleParams(tokenIn, wnative, fee, ADDRESS_THIS, amountIn, minOut, 0)
        );
        inner[1] = abi.encodeWithSelector(bytes4(keccak256("unwrapWETH9(uint256,address)")), minOut, recipient);
        return VelloraPixVault.Call(router, abi.encodeWithSelector(bytes4(keccak256("multicall(bytes[])")), inner));
    }

    // -------------------------------------------------------------- V2-like

    function v2SwapExactTokensForTokens(address router, uint256 amountIn, uint256 minOut, address[] memory path, address to)
        internal
        view
        returns (VelloraPixVault.Call memory)
    {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)")),
            amountIn,
            minOut,
            path,
            to,
            block.timestamp + 600
        );
        return VelloraPixVault.Call(router, data);
    }

    function v2SwapExactTokensForETH(address router, uint256 amountIn, uint256 minOut, address[] memory path, address to)
        internal
        view
        returns (VelloraPixVault.Call memory)
    {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForETH(uint256,uint256,address[],address,uint256)")),
            amountIn,
            minOut,
            path,
            to,
            block.timestamp + 600
        );
        return VelloraPixVault.Call(router, data);
    }

    // ----------------------------------------------------- Universal Router

    function permit2Approve(address token, address spender, uint160 amount, uint48 expiration)
        internal
        pure
        returns (VelloraPixVault.Call memory)
    {
        return VelloraPixVault.Call(
            PERMIT2, abi.encodeWithSelector(bytes4(keccak256("approve(address,address,uint160,uint48)")), token, spender, amount, expiration)
        );
    }

    /// V3_SWAP_EXACT_IN (layout 1.2 / 2.0): (recipient, amountIn, amountOutMin, path, payerIsUser).
    function urV3ExactIn(address ur, bytes memory path, uint256 amountIn, uint256 minOut, address recipient)
        internal
        view
        returns (VelloraPixVault.Call memory)
    {
        bytes memory commands = abi.encodePacked(UR_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(recipient, amountIn, minOut, path, true);
        return VelloraPixVault.Call(ur, _urExecute(commands, inputs));
    }

    /// V3_SWAP_EXACT_IN para ADDRESS_THIS + UNWRAP_WETH para o usuário.
    function urV3ExactInNativeOut(address ur, bytes memory path, uint256 amountIn, uint256 minOut, address recipient)
        internal
        view
        returns (VelloraPixVault.Call memory)
    {
        bytes memory commands = abi.encodePacked(UR_V3_SWAP_EXACT_IN, UR_UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, amountIn, minOut, path, true);
        inputs[1] = abi.encode(recipient, minOut);
        return VelloraPixVault.Call(ur, _urExecute(commands, inputs));
    }

    /// Variante com inputs já codificados (ex.: layout 2.1.1 com minHopPriceX36).
    function urExecuteRaw(address ur, bytes memory commands, bytes[] memory inputs)
        internal
        view
        returns (VelloraPixVault.Call memory)
    {
        return VelloraPixVault.Call(ur, _urExecute(commands, inputs));
    }

    function _urExecute(bytes memory commands, bytes[] memory inputs) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(keccak256("execute(bytes,bytes[],uint256)")), commands, inputs, block.timestamp + 600
        );
    }

    // ---------------------------------------------------------------- paths

    function v3Path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function v3Path2(address a, uint24 fee1, address b, uint24 fee2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee1, b, fee2, c);
    }

    function pathOf(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }
}

/// Quoters (chamados via eth_call nos testes; QuoterV2 é non-view mas funciona em call).
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface IV2Router {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory);
}
