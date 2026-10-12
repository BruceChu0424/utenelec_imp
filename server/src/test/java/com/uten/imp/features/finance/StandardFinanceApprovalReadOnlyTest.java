package com.uten.imp.features.finance;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseController;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeController;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.payment.FinancePaymentController;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.receipt.FinanceReceiptController;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authorization.method.AuthorizationManagerBeforeMethodInterceptor;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class StandardFinanceApprovalReadOnlyTest {
    @AfterEach void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @ParameterizedTest
    @MethodSource("documents")
    void removedReviewCommandCannotOverwriteAmountsOrPostMoney(Document document) throws Exception {
        var mvc = MockMvcBuilders.standaloneSetup(document.controller()).build();
        UUID id = UUID.randomUUID();

        mvc.perform(post(document.path() + "/{id}/review", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"expectedSnapshot":"old-review-snapshot","approveNow":true,
                                 "document":{"amountOriginal":"999","accountAmount":"999","items":[]}}
                                """))
                .andExpect(status().isNotFound());
        mvc.perform(get(document.path() + "/{id}/review", id)).andExpect(status().isNotFound());
        verifyNoInteractions(document.service());
    }

    @ParameterizedTest
    @MethodSource("documents")
    void approvalPermissionDoesNotGrantOrdinaryEditingAtControllerOrService(Document document) throws Exception {
        loginAsReviewer(document.permission());
        UUID id = UUID.randomUUID();
        Object request = document.requestType().getConstructor().newInstance();
        Object controller = secured(document.controller());
        Object service = secured(document.service());

        assertThatThrownBy(() -> controller.getClass().getMethod("update", UUID.class, document.requestType())
                        .invoke(controller, id, request)).hasCauseInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> service.getClass().getMethod("update", UUID.class, document.requestType())
                        .invoke(service, id, request)).hasCauseInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(document.service());
    }

    @ParameterizedTest
    @MethodSource("documents")
    void existingApprovalActionRemainsAvailableWithItsOwnPermission(Document document) throws Exception {
        loginAsReviewer(document.permission());
        UUID id = UUID.randomUUID();
        Object controller = secured(document.controller());

        controller.getClass().getMethod("approve", UUID.class).invoke(controller, id);
        document.service().getClass().getMethod("approve", UUID.class).invoke(verify(document.service()), id);
    }

    private static Object secured(Object target) {
        ProxyFactory factory = new ProxyFactory(target);
        factory.setProxyTargetClass(true);
        factory.addAdvisor(AuthorizationManagerBeforeMethodInterceptor.preAuthorize());
        return factory.getProxy();
    }

    private static void loginAsReviewer(String permission) {
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(
                "reviewer", "unused", List.of(new SimpleGrantedAuthority(permission + ":view"),
                        new SimpleGrantedAuthority(permission + ":approve"))));
    }

    private static Stream<Document> documents() {
        var receipt = mock(FinanceReceiptService.class);
        var payment = mock(FinancePaymentService.class);
        var expense = mock(FinanceExpenseService.class);
        var income = mock(FinanceOtherIncomeService.class);
        var transfer = mock(FinanceBankTransferService.class);
        var audit = mock(AuditService.class);
        var detailAudit = mock(AuditDetailViewRecorder.class);
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.empty());
        return Stream.of(
                new Document(new FinanceReceiptController(receipt, audit, current, detailAudit), receipt,
                        com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest.class, "finance_receipt", "/api/finance/receipts"),
                new Document(new FinancePaymentController(payment, audit, current, detailAudit), payment,
                        com.uten.imp.features.finance.payment.dto.FinancePaymentSaveRequest.class, "finance_payment", "/api/finance/payments"),
                new Document(new FinanceExpenseController(expense, audit, current, detailAudit), expense,
                        com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest.class, "finance_expense", "/api/finance/expenses"),
                new Document(new FinanceOtherIncomeController(income, audit, current, detailAudit), income,
                        com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest.class, "finance_other_income", "/api/finance/incomes"),
                new Document(new FinanceBankTransferController(transfer, audit, current, detailAudit), transfer,
                        com.uten.imp.features.finance.bank_transfer.dto.FinanceBankTransferSaveRequest.class, "finance_bank_transfer", "/api/finance/bank-transfers"));
    }

    private record Document(Object controller, Object service, Class<?> requestType, String permission, String path) {
        @Override public String toString() {
            return permission;
        }
    }
}
