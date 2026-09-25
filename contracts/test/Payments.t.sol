// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";

/// @dev Recebedor que recusa valor explicitamente, para provocar TransferFailed.
contract RejectingPayee {
    receive() external payable {
        revert("recusado");
    }
}

/// @dev Recebedor sem `receive` e sem `fallback`: recusa por ausencia de entrada.
contract SilentPayee {}

/// @dev Recebedor que recusa enquanto `accepting` for false, para provar que um repasse
///      que falhou nao queima o orderId: a mesma ordem liquida depois.
contract ToggleablePayee {
    bool public accepting;

    function setAccepting(bool value) external {
        accepting = value;
    }

    receive() external payable {
        if (!accepting) revert("recusado");
    }
}

contract PaymentsTest is Test {
    Payments internal payments;

    address internal payer;
    address internal payee;

    bytes32 internal constant SALT = keccak256("salt-1");
    uint256 internal constant AMOUNT = 1 ether;

    /// @dev Tripla fixa e o orderId que ela produz, calculado FORA do Solidity com
    ///      `cast abi-encode` + `cast keccak`. Prende o formato do orderId: e o vetor de
    ///      teste que o app da Fase 4 tem de reproduzir em Rust, byte por byte.
    address internal constant PINNED_PAYEE = 0x1111111111111111111111111111111111111111;
    uint256 internal constant PINNED_AMOUNT = 1 ether;
    bytes32 internal constant PINNED_SALT =
        0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 internal constant PINNED_ORDER_ID =
        0x869211b2d967910689ad25d3ba8335e13e467de5f15abeff18cb3aa3663fdfcb;

    /// @dev orderId da cobranca padrao: payee, AMOUNT e SALT. Nao pode ser `constant`
    ///      porque depende do `payee`, que so existe depois do setUp.
    bytes32 internal orderId;

    /// @dev Espelha a formula do contrato. Toda ordem do teste passa por aqui.
    function orderIdFor(address payee_, uint256 amount_, bytes32 salt_)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payee_, amount_, salt_));
    }

    function setUp() public {
        payments = new Payments();
        payer = makeAddr("payer");
        payee = makeAddr("payee");
        vm.deal(payer, 10 ether);

        orderId = orderIdFor(payee, AMOUNT, SALT);
    }

    // ---------------------------------------------------------------- caminho feliz

    function test_Pay_MovesExactAmountToPayee() public {
        uint256 payerBefore = payer.balance;
        uint256 payeeBefore = payee.balance;

        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        assertEq(payee.balance, payeeBefore + AMOUNT, "payee nao subiu pelo valor exato");
        assertEq(payer.balance, payerBefore - AMOUNT, "payer nao caiu pelo valor exato");
    }

    function test_Pay_ContractRetainsNothing() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        assertEq(address(payments).balance, 0, "contrato reteve valor");
    }

    function test_Pay_EmitsPaymentWithOrderId() public {
        vm.expectEmit(true, true, true, true, address(payments));
        emit Payments.Payment(orderId, payer, payee, AMOUNT);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);
    }

    // ------------------------------------------- o orderId compromete valor e payee

    function test_Pay_RevertsWhenValueIsBelowCommitted() public {
        bytes32 derived = orderIdFor(payee, AMOUNT - 1, SALT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, orderId, derived)
        );
        payments.pay{value: AMOUNT - 1}(orderId, SALT, payee);
    }

    function test_Pay_RevertsWhenValueIsAboveCommitted() public {
        bytes32 derived = orderIdFor(payee, AMOUNT + 1, SALT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, orderId, derived)
        );
        payments.pay{value: AMOUNT + 1}(orderId, SALT, payee);
    }

    function test_Pay_RevertsWhenPayeeIsNotTheCommittedOne() public {
        address other = makeAddr("other");
        bytes32 derived = orderIdFor(other, AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, orderId, derived)
        );
        payments.pay{value: AMOUNT}(orderId, SALT, other);
    }

    function test_Pay_RevertsOnWrongSalt() public {
        bytes32 wrongSalt = keccak256("salt-2");
        bytes32 derived = orderIdFor(payee, AMOUNT, wrongSalt);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, orderId, derived)
        );
        payments.pay{value: AMOUNT}(orderId, wrongSalt, payee);
    }

    /// @dev bytes32(0) perdeu a guarda dedicada: nao tem caminho especial, so nao fecha o hash.
    function test_Pay_RevertsOnZeroOrderId() public {
        bytes32 derived = orderIdFor(payee, AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, bytes32(0), derived)
        );
        payments.pay{value: AMOUNT}(bytes32(0), SALT, payee);
    }

    function test_Pay_MismatchMovesNoValue() public {
        uint256 payerBefore = payer.balance;
        uint256 payeeBefore = payee.balance;

        vm.prank(payer);
        vm.expectRevert();
        payments.pay{value: AMOUNT - 1}(orderId, SALT, payee);

        assertEq(payer.balance, payerBefore, "payer pagou apesar do mismatch");
        assertEq(payee.balance, payeeBefore, "payee recebeu apesar do mismatch");
        assertFalse(payments.paid(orderId), "orderId ficou marcado apesar do mismatch");
    }

    // ------------------------------------------------------------------- as guardas

    function test_Pay_RevertsOnZeroPayee() public {
        bytes32 oid = orderIdFor(address(0), AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.ZeroPayee.selector);
        payments.pay{value: AMOUNT}(oid, SALT, address(0));
    }

    function test_Pay_RevertsOnZeroAmount() public {
        bytes32 oid = orderIdFor(payee, 0, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.ZeroAmount.selector);
        payments.pay{value: 0}(oid, SALT, payee);
    }

    // ------------------------------------------------- recebedor incapaz de receber

    function test_Pay_RevertsWhenPayeeRejectsValue() public {
        address rejecting = address(new RejectingPayee());
        bytes32 oid = orderIdFor(rejecting, AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(oid, SALT, rejecting);
    }

    function test_Pay_RevertsWhenPayeeHasNoReceive() public {
        address silent = address(new SilentPayee());
        bytes32 oid = orderIdFor(silent, AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(oid, SALT, silent);
    }

    function test_Pay_RevertsWhenPayeeIsTheContractItself() public {
        bytes32 oid = orderIdFor(address(payments), AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(oid, SALT, address(payments));
    }

    // --------------------------------------------- nada se move quando algo reverte

    function test_Pay_NoValueMovesWhenPayeeRejects() public {
        address rejecting = address(new RejectingPayee());
        bytes32 oid = orderIdFor(rejecting, AMOUNT, SALT);
        uint256 payerBefore = payer.balance;

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(oid, SALT, rejecting);

        assertEq(payer.balance, payerBefore, "saldo do payer mudou apesar do revert");
        assertEq(rejecting.balance, 0, "payee recebeu apesar do revert");
        assertEq(address(payments).balance, 0, "contrato reteve apesar do revert");
    }

    // ------------------------------------- o contrato so aceita valor atraves de pay

    function test_PlainTransferToContractReverts() public {
        vm.deal(address(this), 1 ether);

        (bool ok, ) = address(payments).call{value: 1 ether}("");

        assertFalse(ok, "contrato aceitou ETH fora de pay");
        assertEq(address(payments).balance, 0, "contrato reteve ETH enviado direto");
    }

    // ----------------------------------------------- idempotencia autoritativa

    function test_Pay_MarksOrderIdAsPaid() public {
        assertFalse(payments.paid(orderId), "orderId nasceu marcado");

        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        assertTrue(payments.paid(orderId), "orderId nao ficou marcado");
    }

    function test_Pay_RevertsOnDuplicateOrderId() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.AlreadyPaid.selector, orderId));
        payments.pay{value: AMOUNT}(orderId, SALT, payee);
    }

    function test_Pay_DuplicateMovesNoValue() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        uint256 payerAfterFirst = payer.balance;
        uint256 payeeAfterFirst = payee.balance;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.AlreadyPaid.selector, orderId));
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        assertEq(payer.balance, payerAfterFirst, "payer pagou duas vezes");
        assertEq(payee.balance, payeeAfterFirst, "payee recebeu duas vezes");
        assertEq(address(payments).balance, 0, "contrato reteve valor");
    }

    function test_Pay_FailedTransferDoesNotBurnOrderId() public {
        ToggleablePayee toggle = new ToggleablePayee();
        bytes32 oid = orderIdFor(address(toggle), AMOUNT, SALT);

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(oid, SALT, address(toggle));

        assertFalse(payments.paid(oid), "orderId ficou marcado apesar do revert");

        toggle.setAccepting(true);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(oid, SALT, address(toggle));

        assertEq(address(toggle).balance, AMOUNT, "a mesma ordem nao liquidou depois");
    }

    function test_Pay_DistinctOrderIdsDoNotCollide() public {
        bytes32 otherSalt = keccak256("salt-2");
        bytes32 other = orderIdFor(payee, AMOUNT, otherSalt);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(orderId, SALT, payee);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(other, otherSalt, payee);

        assertEq(payee.balance, 2 * AMOUNT, "segundo orderId foi bloqueado");
    }

    // ------------------------------------------------------------------------ fuzz

    function testFuzz_Pay_MovesExactAmount(bytes32 salt, uint96 amount) public {
        vm.assume(amount > 0);
        bytes32 oid = orderIdFor(payee, amount, salt);
        vm.deal(payer, amount);

        uint256 payeeBefore = payee.balance;

        vm.prank(payer);
        payments.pay{value: amount}(oid, salt, payee);

        assertEq(payee.balance, payeeBefore + amount);
        assertEq(payer.balance, 0);
        assertEq(address(payments).balance, 0);
    }

    function testFuzz_Pay_RevertsWhenValueDiverges(uint96 committed, uint96 sent) public {
        vm.assume(committed > 0 && sent > 0 && sent != committed);

        bytes32 oid = orderIdFor(payee, committed, SALT);
        bytes32 derived = orderIdFor(payee, sent, SALT);
        vm.deal(payer, sent);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(Payments.OrderIdMismatch.selector, oid, derived)
        );
        payments.pay{value: sent}(oid, SALT, payee);
    }

    // ------------------------------------------------- o formato do orderId, fixado

    function test_OrderIdFormulaIsPinned() public {
        assertEq(
            orderIdFor(PINNED_PAYEE, PINNED_AMOUNT, PINNED_SALT),
            PINNED_ORDER_ID,
            "a formula do orderId mudou"
        );
    }

    function test_Pay_AcceptsPinnedOrderId() public {
        vm.prank(payer);
        payments.pay{value: PINNED_AMOUNT}(PINNED_ORDER_ID, PINNED_SALT, PINNED_PAYEE);

        assertTrue(payments.paid(PINNED_ORDER_ID), "o contrato nao derivou o orderId fixado");
    }
}
