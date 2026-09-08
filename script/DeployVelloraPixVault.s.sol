// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VelloraPixVault} from "../src/VelloraPixVault.sol";

/**
 * Deploy DETERMINÍSTICO via o deployer CREATE2 canônico (0x4e59b448…, presente
 * em todas as 8 redes, inclusive Robinhood 4663): mesmo `owner` + mesmo `salt`
 * ⇒ mesmo endereço em toda rede. A reserva (USDT/USDG) é configurada DEPOIS
 * pelo owner (`setReserve`), justamente para o init code ser idêntico.
 *
 *   OWNER=0x… SALT=vellora-pix-vault-v1 forge script script/DeployVelloraPixVault.s.sol \
 *     --rpc-url <rpc> --broadcast --private-key <deployer>   (o deployer paga o gás; não precisa ser o owner)
 *
 * Sem --broadcast só imprime o endereço previsto.
 */
contract DeployVelloraPixVault is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address owner = vm.envAddress("OWNER");
        bytes32 salt = keccak256(bytes(vm.envOr("SALT", string("vellora-pix-vault-v1"))));
        bytes memory initCode = abi.encodePacked(type(VelloraPixVault).creationCode, abi.encode(owner));
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        console2.log("owner    :", owner);
        console2.log("predicted:", predicted);
        if (predicted.code.length > 0) {
            console2.log("ja deployado nesta rede");
            return;
        }
        vm.startBroadcast();
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "create2 deployer call failed");
        vm.stopBroadcast();
        require(predicted.code.length > 0, "deploy nao aconteceu no endereco previsto");
        console2.log("deployed :", predicted);
    }
}
