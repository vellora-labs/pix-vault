// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.36;

import {PixVaultForkBase} from "./PixVaultForkBase.sol";
import {DexKit} from "./DexKit.sol";
import {VelloraPixVault} from "../../src/VelloraPixVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// forge test --match-contract Fork_bsc --fork-url https://bsc-rpc.publicnode.com -vv
contract Fork_bsc is PixVaultForkBase {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // 18 dec
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address constant PCS_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4; // v3 SmartRouter
    address constant PCS_QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant PCS_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant USDT_WHALE = 0x8894E0a0c962CB723c1976a4421c95949bE2D4E3; // large USDT holder (funding fallback)

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-rpc.publicnode.com")));
        address[] memory targets = new address[](2);
        targets[0] = PCS_SMART_ROUTER;
        targets[1] = PCS_V2_ROUTER;
        _setUpVault(USDT, targets, 1_000, USDT_WHALE);
    }

    function test_pancakeV3_usdt_to_wbnb() public {
        uint256 amountIn = units(100);
        uint256 q = quoteV3(PCS_QUOTER_V2, USDT, WBNB, 100, amountIn);
        (uint256 delivered,) = buy(
            "pcs-v3 USDT->WBNB fee100",
            WBNB,
            amountIn,
            withSlippage(q),
            PCS_SMART_ROUTER,
            one(DexKit.srExactInputSingle(PCS_SMART_ROUTER, USDT, WBNB, 100, user, amountIn, withSlippage(q)))
        );
        assertEq(IERC20(WBNB).balanceOf(user), delivered);
    }

    function test_pancakeV3_usdt_to_bnb_native() public {
        uint256 amountIn = units(100);
        uint256 q = quoteV3(PCS_QUOTER_V2, USDT, WBNB, 100, amountIn);
        (uint256 delivered,) = buy(
            "pcs-v3 USDT->BNB native (multicall+unwrap)",
            address(0),
            amountIn,
            withSlippage(q),
            PCS_SMART_ROUTER,
            one(DexKit.srExactInputSingleNativeOut(PCS_SMART_ROUTER, USDT, WBNB, 100, user, amountIn, withSlippage(q)))
        );
        assertEq(user.balance, delivered);
    }

    function test_pancakeV3_multihop_usdt_wbnb_cake() public {
        uint256 amountIn = units(100);
        bytes memory path = DexKit.v3Path2(USDT, 100, WBNB, 2500, CAKE);
        uint256 q = quoteV3Path(PCS_QUOTER_V2, path, amountIn);
        buy(
            "pcs-v3 USDT->WBNB->CAKE exactInput",
            CAKE,
            amountIn,
            withSlippage(q),
            PCS_SMART_ROUTER,
            one(DexKit.srExactInput(PCS_SMART_ROUTER, path, user, amountIn, withSlippage(q)))
        );
    }

    function test_pancakeV2_usdt_to_cake() public {
        uint256 amountIn = units(100);
        address[] memory path = DexKit.pathOf(USDT, CAKE);
        uint256 q = quoteV2(PCS_V2_ROUTER, path, amountIn);
        buy(
            "pcs-v2 USDT->CAKE",
            CAKE,
            amountIn,
            withSlippage(q),
            PCS_V2_ROUTER,
            one(DexKit.v2SwapExactTokensForTokens(PCS_V2_ROUTER, amountIn, withSlippage(q), path, user))
        );
    }

    function test_pancakeV2_usdt_to_bnb_native() public {
        uint256 amountIn = units(100);
        address[] memory path = DexKit.pathOf(USDT, WBNB);
        uint256 q = quoteV2(PCS_V2_ROUTER, path, amountIn);
        buy(
            "pcs-v2 USDT->BNB native",
            address(0),
            amountIn,
            withSlippage(q),
            PCS_V2_ROUTER,
            one(DexKit.v2SwapExactTokensForETH(PCS_V2_ROUTER, amountIn, withSlippage(q), path, user))
        );
    }

    function test_transferReserve_usdtOut() public {
        vm.prank(operator);
        vault.transferReserve(keccak256("usdt-out"), user, units(50));
        assertEq(IERC20(USDT).balanceOf(user), units(50));
    }

    function test_reverts_when_minOut_too_high() public {
        uint256 amountIn = units(100);
        uint256 q = quoteV3(PCS_QUOTER_V2, USDT, WBNB, 100, amountIn);
        VelloraPixVault.Call[] memory calls =
            one(DexKit.srExactInputSingle(PCS_SMART_ROUTER, USDT, WBNB, 100, user, amountIn, q * 2));
        vm.prank(operator);
        vm.expectRevert(); // CallFailed("Too little received")
        vault.executeBuy(keccak256("x"), user, WBNB, amountIn, q * 2, PCS_SMART_ROUTER, calls);
        assertEq(IERC20(USDT).balanceOf(address(vault)), units(1_000), "nothing left the vault");
    }
}
