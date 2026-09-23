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

contract PaymentsTest is Test {
    Payments internal payments;

    address internal payer;
    address internal payee;

    bytes32 internal constant ORDER_ID = keccak256("order-1");
    uint256 internal constant AMOUNT = 1 ether;

    function setUp() public {
        payments = new Payments();
        payer = makeAddr("payer");
        payee = makeAddr("payee");
        vm.deal(payer, 10 ether);
    }

    // ---------------------------------------------------------------- caminho feliz

    function test_Pay_MovesExactAmountToPayee() public {
        uint256 payerBefore = payer.balance;
        uint256 payeeBefore = payee.balance;

        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        assertEq(payee.balance, payeeBefore + AMOUNT, "payee nao subiu pelo valor exato");
        assertEq(payer.balance, payerBefore - AMOUNT, "payer nao caiu pelo valor exato");
    }

    function test_Pay_ContractRetainsNothing() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        assertEq(address(payments).balance, 0, "contrato reteve valor");
    }

    function test_Pay_EmitsPaymentWithOrderId() public {
        vm.expectEmit(true, true, true, true, address(payments));
        emit Payments.Payment(ORDER_ID, payer, payee, AMOUNT);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);
    }

    // ------------------------------------------------------------------- as guardas

    function test_Pay_RevertsOnZeroOrderId() public {
        vm.prank(payer);
        vm.expectRevert(Payments.ZeroOrderId.selector);
        payments.pay{value: AMOUNT}(bytes32(0), payee);
    }

    function test_Pay_RevertsOnZeroPayee() public {
        vm.prank(payer);
        vm.expectRevert(Payments.ZeroPayee.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, address(0));
    }

    function test_Pay_RevertsOnZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(Payments.ZeroAmount.selector);
        payments.pay{value: 0}(ORDER_ID, payee);
    }

    // ------------------------------------------------- recebedor incapaz de receber

    function test_Pay_RevertsWhenPayeeRejectsValue() public {
        address rejecting = address(new RejectingPayee());

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, rejecting);
    }

    function test_Pay_RevertsWhenPayeeHasNoReceive() public {
        address silent = address(new SilentPayee());

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, silent);
    }

    function test_Pay_RevertsWhenPayeeIsTheContractItself() public {
        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, address(payments));
    }

    // --------------------------------------------- nada se move quando algo reverte

    function test_Pay_NoValueMovesWhenPayeeRejects() public {
        address rejecting = address(new RejectingPayee());
        uint256 payerBefore = payer.balance;

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, rejecting);

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
        assertFalse(payments.paid(ORDER_ID), "orderId nasceu marcado");

        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        assertTrue(payments.paid(ORDER_ID), "orderId nao ficou marcado");
    }

    function test_Pay_RevertsOnDuplicateOrderId() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.AlreadyPaid.selector, ORDER_ID));
        payments.pay{value: AMOUNT}(ORDER_ID, payee);
    }

    function test_Pay_DuplicateMovesNoValue() public {
        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        uint256 payerAfterFirst = payer.balance;
        uint256 payeeAfterFirst = payee.balance;

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.AlreadyPaid.selector, ORDER_ID));
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        assertEq(payer.balance, payerAfterFirst, "payer pagou duas vezes");
        assertEq(payee.balance, payeeAfterFirst, "payee recebeu duas vezes");
        assertEq(address(payments).balance, 0, "contrato reteve valor");
    }

    function test_Pay_FailedTransferDoesNotBurnOrderId() public {
        address rejecting = address(new RejectingPayee());

        vm.prank(payer);
        vm.expectRevert(Payments.TransferFailed.selector);
        payments.pay{value: AMOUNT}(ORDER_ID, rejecting);

        assertFalse(payments.paid(ORDER_ID), "orderId ficou marcado apesar do revert");

        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        assertEq(payee.balance, AMOUNT, "orderId recusado apos falha de repasse");
    }

    function test_Pay_DistinctOrderIdsDoNotCollide() public {
        bytes32 other = keccak256("order-2");

        vm.prank(payer);
        payments.pay{value: AMOUNT}(ORDER_ID, payee);

        vm.prank(payer);
        payments.pay{value: AMOUNT}(other, payee);

        assertEq(payee.balance, 2 * AMOUNT, "segundo orderId foi bloqueado");
    }

    // ------------------------------------------------------------------------ fuzz

    function testFuzz_Pay_MovesExactAmount(bytes32 orderId, uint96 amount) public {
        vm.assume(orderId != bytes32(0));
        vm.assume(amount > 0);
        vm.deal(payer, amount);

        uint256 payeeBefore = payee.balance;

        vm.prank(payer);
        payments.pay{value: amount}(orderId, payee);

        assertEq(payee.balance, payeeBefore + amount);
        assertEq(payer.balance, 0);
        assertEq(address(payments).balance, 0);
    }
}
