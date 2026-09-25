// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title  Payments
/// @notice Repasse direto de valor de um pagador para um recebedor, identificado por um
///         orderId que compromete o recebedor, o valor e um salt da cobranca.
/// @dev    O contrato nao retem valor. Todo msg.value recebido em `pay` e repassado ao
///         payee na mesma transacao, e a falha do repasse reverte a transacao inteira.
///         Nenhuma funcao le address(this).balance, e nao existe `receive` nem `fallback`:
///         o contrato so aceita valor atraves de `pay`.
///         Cada orderId liquida no maximo uma vez. A guarda e autoritativa porque a EVM
///         executa as transacoes em ordem total: a segunda chamada le o que a primeira
///         escreveu, mesmo no mesmo bloco.
///         O orderId e recalculado a partir dos argumentos e do valor enviado: uma chamada
///         com valor ou recebedor diferentes do que a ordem comprometeu nao fecha o hash e
///         reverte antes de mover dinheiro.
contract Payments {
    /// @notice orderId ja liquidado por este contrato.
    /// @dev    Publica de proposito: o app responde "esse orderId ja foi pago?" com uma
    ///         chamada so, sem varrer faixa de blocos de log.
    mapping(bytes32 => bool) public paid;

    /// @notice Repasse concluido.
    /// @param orderId keccak256(abi.encode(payee, amount, salt)) da ordem.
    /// @param payer   Conta que assinou e custeou a transacao.
    /// @param payee   Conta que recebeu o valor.
    /// @param amount  Valor repassado, em wei.
    event Payment(
        bytes32 indexed orderId,
        address indexed payer,
        address indexed payee,
        uint256 amount
    );

    /// @notice Repassar para o endereco zero queimaria o valor.
    error ZeroPayee();
    /// @notice Pagamento sem valor produziria evento de pagamento sem pagamento.
    error ZeroAmount();
    /// @notice O orderId apresentado nao corresponde a keccak256(payee, msg.value, salt).
    /// @param expected orderId que a chamada apresentou.
    /// @param derived  orderId recalculado a partir dos argumentos e do valor enviado.
    error OrderIdMismatch(bytes32 expected, bytes32 derived);
    /// @notice Esse orderId ja foi liquidado. Leva o orderId recusado na revert data.
    error AlreadyPaid(bytes32 orderId);
    /// @notice O payee recusou o valor ou nao e capaz de recebe-lo.
    error TransferFailed();

    /// @notice Repassa msg.value ao payee e publica o evento com o orderId.
    /// @param orderId keccak256(abi.encode(payee, amount, salt)), calculado pelo recebedor
    ///        ao criar a cobranca.
    /// @param salt    32 bytes aleatorios da cobranca; a unica parcela do hash que o
    ///                contrato nao tem por conta propria.
    /// @param payee   Conta que recebe o valor.
    function pay(bytes32 orderId, bytes32 salt, address payee) external payable {
        // checks
        if (payee == address(0)) revert ZeroPayee();
        if (msg.value == 0) revert ZeroAmount();

        bytes32 derived = keccak256(abi.encode(payee, msg.value, salt));
        if (derived != orderId) revert OrderIdMismatch(orderId, derived);

        if (paid[orderId]) revert AlreadyPaid(orderId);

        // effects
        paid[orderId] = true;
        emit Payment(orderId, msg.sender, payee, msg.value);

        // interactions
        (bool ok, ) = payee.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }
}
