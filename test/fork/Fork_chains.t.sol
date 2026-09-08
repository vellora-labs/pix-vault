// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {UniV3ForkSuite} from "./UniV3ForkSuite.sol";

/**
 * Uma classe por rede: só endereços VERIFICADOS on-chain em 2026-09-07
 * (`cast code` != 0x, `factory.getPool` devolvendo pool com liquidez > 0 e
 * `QuoterV2` cotando 100 da reserva). Rodar:
 *
 *   FOUNDRY_PROFILE=fork forge test --match-contract Fork_eth --fork-url <rpc> -vv
 *
 * Os endereços do Uniswap v3 são os canônicos (mesmo endereço em ETH/POL/OP/ARB),
 * exceto Base, Avalanche, BSC e Robinhood, que têm deploys próprios.
 */
contract Fork_eth is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (500, 100, 3000);
        _initUniV3(
            "eth",
            "ETH_RPC_URL",
            "https://ethereum-rpc.publicnode.com",
            0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT (6)
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            0x1F98431c8aD98523631AE4a59f267346ea31F984,
            0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            0x61fFE014bA17989E743c5F6cB21bF9697530B21e,
            0xF977814e90dA44bFA03b6295A0616a897441aceC, // Binance 8
            fees
        );
    }
}

contract Fork_pol is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (500, 3000, 100);
        _initUniV3(
            "pol",
            "POL_RPC_URL",
            "https://polygon-bor-rpc.publicnode.com",
            0xc2132D05D31c914a87C6611C10748AEb04B58e8F, // USDT/USDT0 (6)
            0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, // WPOL
            0x1F98431c8aD98523631AE4a59f267346ea31F984,
            0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            0x61fFE014bA17989E743c5F6cB21bF9697530B21e,
            0xF977814e90dA44bFA03b6295A0616a897441aceC,
            fees
        );
    }
}

contract Fork_op is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (500, 3000, 100);
        _initUniV3(
            "op",
            "OP_RPC_URL",
            "https://optimism-rpc.publicnode.com",
            0x94b008aA00579c1307B0EF2c499aD98a8ce58e58, // USDT (6)
            0x4200000000000000000000000000000000000006, // WETH
            0x1F98431c8aD98523631AE4a59f267346ea31F984,
            0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            0x61fFE014bA17989E743c5F6cB21bF9697530B21e,
            0xacD03D601e5bB1B275Bb94076fF46ED9D753435A, // Optimism bridge/holder
            fees
        );
    }
}

contract Fork_arb is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (500, 3000, 100);
        _initUniV3(
            "arb",
            "ARB_RPC_URL",
            "https://arbitrum-one-rpc.publicnode.com",
            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9, // USD₮0 (6)
            0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, // WETH
            0x1F98431c8aD98523631AE4a59f267346ea31F984,
            0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            0x61fFE014bA17989E743c5F6cB21bF9697530B21e,
            0xF977814e90dA44bFA03b6295A0616a897441aceC,
            fees
        );
    }
}

contract Fork_base is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (3000, 500, 100);
        _initUniV3(
            "base",
            "BASE_RPC_URL",
            "https://base-rpc.publicnode.com",
            0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2, // USDT (6)
            0x4200000000000000000000000000000000000006, // WETH
            0x33128a8fC17869897dcE68Ed026d694621f6FDfD,
            0x2626664c2603336E57B271c5C0b26F421741e481,
            0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a,
            0xF977814e90dA44bFA03b6295A0616a897441aceC,
            fees
        );
    }
}

/// AVAX: sem 7702 (o operador aqui é uma EOA comum pagando gás em AVAX) — o
/// cofre é idêntico, o que muda é só quem assina.
contract Fork_avax is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (3000, 500, 100);
        _initUniV3(
            "avax",
            "AVAX_RPC_URL",
            "https://api.avax.network/ext/bc/C/rpc",
            0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7, // USDT (6)
            0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, // WAVAX
            0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD,
            0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE,
            0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F,
            0x4aeFa39caEAdD662aE31ab0CE7c8C2c9c0a013E8, // Binance C-Chain
            fees
        );
    }
}

/// Uniswap v3 na BSC (deploy próprio; o Pancake tem bateria separada em Fork_bsc).
contract Fork_bsc_uni is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (500, 100, 3000);
        _initUniV3(
            "bsc(uni)",
            "BSC_RPC_URL",
            "https://bsc-rpc.publicnode.com",
            0x55d398326f99059fF775485246999027B3197955, // USDT (18)
            0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // WBNB
            0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7, // factory() lido do SwapRouter02
            0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2,
            0x78D78E420Da98ad378D7799bE8f4AF69033EB077,
            0x8894E0a0c962CB723c1976a4421c95949bE2D4E3,
            fees
        );
    }
}

/// Robinhood Chain: reserva = USDG (não há USDT líquido), Uniswap v3 próprio.
contract Fork_robinhood is UniV3ForkSuite {
    function setUp() public {
        uint24[] memory fees = new uint24[](3);
        (fees[0], fees[1], fees[2]) = (100, 500, 3000);
        _initUniV3(
            "robinhood",
            "ROBINHOOD_RPC_URL",
            "https://rpc.mainnet.chain.robinhood.com",
            0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, // USDG (6)
            0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, // WETH
            0x1f7d7550B1b028f7571E69A784071F0205FD2EfA,
            0xCaf681a66D020601342297493863E78C959E5cb2,
            0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7,
            address(0), // sem whale conhecido: `deal` resolve
            fees
        );
    }
}
