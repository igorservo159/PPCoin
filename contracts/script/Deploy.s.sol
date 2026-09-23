// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {Payments} from "../src/Payments.sol";

/// @title  Deploy
/// @notice Publica o Payments. O contrato nao tem construtor: o deploy nao carrega argumento
///         algum, e o endereco resultante depende so do deployer e do nonce dele.
/// @dev    A chave nunca entra no repositorio. O script cita apenas o NOME da variavel de
///         ambiente; `vm.envUint` reverte na execucao local se ela nao estiver carregada,
///         entao o erro aparece antes de qualquer transmissao.
contract Deploy is Script {
    function run() external returns (Payments payments) {
        uint256 deployerKey = vm.envUint("ACC1_KEY");

        vm.startBroadcast(deployerKey);
        payments = new Payments();
        vm.stopBroadcast();
    }
}
