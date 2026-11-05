// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VelloraPixVault} from "../src/VelloraPixVault.sol";

/**
 * DETERMINISTIC deployment through the canonical CREATE2 deployer (0x4e59b448…,
 * present on all 8 target networks, including Robinhood Chain 4663): same `owner`
 * + same `salt` ⇒ same address on every network. The owner sets the reserve
 * (USDT/USDG) AFTERWARDS (`setReserve`), precisely so the init code is identical.
 *
 *   OWNER=0x… SALT=vellora-pix-vault-v1 forge script script/DeployVelloraPixVault.s.sol \
 *     --rpc-url <rpc> --broadcast --private-key <deployer>   (the deployer pays the gas; it does not have to be the owner)
 *
 * Without --broadcast it only simulates: nothing is sent, and the "deployed :"
 * line it prints comes from the simulation.
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
