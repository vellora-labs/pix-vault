// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {VelloraPixVault} from "../../src/VelloraPixVault.sol";

/**
 * Builds the `Call[]` the vault executes against each DEX family. The ABIs are
 * the canonical ones:
 *  - Uniswap v3 SwapRouter02 / PancakeSwap v3 SmartRouter: exactInputSingle
 *    WITHOUT deadline, ADDRESS_THIS = address(2), unwrapWETH9(amountMin, recipient),
 *    multicall(bytes[]).
 *  - V2-style routers (Pancake V2, QuickSwap, Trader Joe v1, Pangolin):
 *    swapExactTokensForTokens / swapExactTokensForETH (5 args).
 *  - Universal Router 1.2 / 2.0: execute(bytes,bytes[],uint256) with
 *    V3_SWAP_EXACT_IN (0x00) and UNWRAP_WETH (0x0c); payment through Permit2
 *    (payerIsUser=true) → the vault approves Permit2 and calls
 *    Permit2.approve(token, ur, amount, expiration) within the same order
 *    (the same executeBuy call).
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

    /// Swap to the wrapped native with recipient = router (ADDRESS_THIS), then unwrapWETH9 to the user, in one multicall.
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

    /// Fee-on-transfer: the router measures the recipient's balance, so `minOut` is the NET amount received.
    function v2SwapSupportingFeeOnTransfer(
        address router,
        uint256 amountIn,
        uint256 minOut,
        address[] memory path,
        address to
    ) internal view returns (VelloraPixVault.Call memory) {
        bytes memory data = abi.encodeWithSelector(
            bytes4(
                keccak256(
                    "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)"
                )
            ),
            amountIn,
            minOut,
            path,
            to,
            block.timestamp + 600
        );
        return VelloraPixVault.Call(router, data);
    }

    function v2SwapSupportingFeeOnTransferForETH(
        address router,
        uint256 amountIn,
        uint256 minOut,
        address[] memory path,
        address to
    ) internal view returns (VelloraPixVault.Call memory) {
        bytes memory data = abi.encodeWithSelector(
            bytes4(
                keccak256(
                    "swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)"
                )
            ),
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

    /// V3_SWAP_EXACT_IN to ADDRESS_THIS + UNWRAP_WETH to the user.
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

    /**
     * Universal Router **2.1.1** (Robinhood Chain): V3_SWAP_EXACT_IN gained one
     * argument per hop, `minHopPriceX36`, a price floor for each hop in X36.
     * Passing zeros disables the bound (same behaviour as 2.0) and does NOT
     * affect delivery: `amountOutMinimum` still guards the final amount, and the
     * vault measures the delivery at the recipient anyway.
     * `hops` = number of pools in the path (2 addresses = 1 hop).
     */
    function urV3ExactIn211(
        address ur,
        bytes memory path,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 hops
    ) internal view returns (VelloraPixVault.Call memory) {
        bytes memory commands = abi.encodePacked(UR_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(recipient, amountIn, minOut, path, true, new uint256[](hops));
        return VelloraPixVault.Call(ur, _urExecute(commands, inputs));
    }

    function urV3ExactIn211NativeOut(
        address ur,
        bytes memory path,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 hops
    ) internal view returns (VelloraPixVault.Call memory) {
        bytes memory commands = abi.encodePacked(UR_V3_SWAP_EXACT_IN, UR_UNWRAP_WETH);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ADDRESS_THIS, amountIn, minOut, path, true, new uint256[](hops));
        inputs[1] = abi.encode(recipient, minOut);
        return VelloraPixVault.Call(ur, _urExecute(commands, inputs));
    }

    /// Variant with pre-encoded inputs (e.g. the 2.1.1 layout with minHopPriceX36).
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

    /// Canonical path: reserve → wrapped native → token.
    function pathOf3(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        p[0] = a;
        p[1] = b;
        p[2] = c;
    }
}

/// Quoters (called through eth_call in the tests; QuoterV2 is non-view but works in a call).
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
