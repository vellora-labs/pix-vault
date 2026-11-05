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
 * Shared suite "reserve → native coin (wrapped and unwrapped) through Uniswap v3
 * SwapRouter02", the router family present on all 8 target networks (on BSC
 * through Uniswap's own deployment, next to PancakeSwap). Each network
 * inherits it, fills in the addresses verified on-chain and gets the same tests.
 *
 * What each test proves, from the vault's point of view:
 *   - calldata for a real router passes the allowlist and executes;
 *   - delivery is measured at the RECIPIENT and covers the quoter's minOut;
 *   - the spend never exceeds amountIn and the approval goes back to zero;
 *   - native output (multicall + unwrapWETH9) arrives as the user's balance;
 *   - an impossible minOut reverts the whole order without moving the reserve.
 */
abstract contract UniV3ForkSuite is PixVaultForkBase {
    address internal factory;
    address internal swapRouter02;
    address internal quoterV2;
    address internal wnative;
    address internal whale;
    string internal chainLabel;
    /// Fee tiers to try, in order of preference.
    uint24[] internal feeTiers;
    /// Third-party token candidates for the canonical path reserve → wrapped → token.
    address[] internal thirdTokens;

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

    /// First fee tier with a pool, liquidity > 0 and a quote > 0 for 100 units of the reserve.
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

    /**
     * `amountIn` is always in the reserve stablecoin and, when needed, the path is
     * **reserve → wrapped native → token**, never a direct stablecoin/token pair
     * that may not exist or may have worse liquidity.
     * Picks the first candidate token with a wrapped/token pool and a quote > 0.
     */
    function test_uniV3_reserve_via_wrapped_to_token() public {
        if (thirdTokens.length == 0) {
            emit log_string("sem token de terceiro configurado nesta rede - pulado");
            return;
        }
        uint256 amountIn = units(100);
        (uint24 feeIn,) = _bestFee(amountIn);
        for (uint256 t = 0; t < thirdTokens.length; t++) {
            address tokenOut = thirdTokens[t];
            for (uint256 i = 0; i < feeTiers.length; i++) {
                address pool = IUniV3Factory(factory).getPool(wnative, tokenOut, feeTiers[i]);
                if (pool == address(0) || IUniV3Pool(pool).liquidity() == 0) continue;
                bytes memory path = DexKit.v3Path2(reserve, feeIn, wnative, feeTiers[i], tokenOut);
                uint256 q;
                try this._quotePath(quoterV2, path, amountIn) returns (uint256 out) {
                    q = out;
                } catch {
                    continue;
                }
                if (q == 0) continue;
                uint256 minOut = withSlippage(q);
                (uint256 delivered,) = buy(
                    string.concat(
                        chainLabel,
                        " uni-v3 reserva->wNative->token fee",
                        vm.toString(uint256(feeIn)),
                        "/",
                        vm.toString(uint256(feeTiers[i]))
                    ),
                    tokenOut,
                    amountIn,
                    minOut,
                    swapRouter02,
                    one(DexKit.srExactInput(swapRouter02, path, user, amountIn, minOut))
                );
                assertEq(IERC20(tokenOut).balanceOf(user), delivered, "token de terceiro foi para o usuario");
                return;
            }
        }
        revert("nenhum candidato reserva->wrapped->token com pool e quote");
    }

    function _quotePath(address q, bytes memory path, uint256 amountIn) external returns (uint256 out) {
        require(msg.sender == address(this), "self");
        return quoteV3Path(q, path, amountIn);
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

    /// The vault refuses to deliver the reserve itself through `executeBuy` (only through transferReserve).
    function test_rejects_tokenOut_equal_reserve() public {
        VelloraPixVault.Call[] memory calls = new VelloraPixVault.Call[](0);
        vm.prank(operator);
        vm.expectRevert(VelloraPixVault.InvalidTokenOut.selector);
        vault.executeBuy(keccak256("bad"), user, reserve, units(10), 0, swapRouter02, calls);
    }
}
