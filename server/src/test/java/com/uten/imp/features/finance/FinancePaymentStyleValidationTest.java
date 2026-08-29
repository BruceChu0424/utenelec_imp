package com.uten.imp.features.finance;

import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.expense.FinanceExpense;
import com.uten.imp.features.finance.expense.FinanceExpenseItemRepository;
import com.uten.imp.features.finance.expense.FinanceExpenseRepository;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseItemInput;
import com.uten.imp.features.finance.expense.dto.FinanceExpenseSaveRequest;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeItemRepository;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeRepository;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeItemInput;
import com.uten.imp.features.finance.other_income.dto.FinanceOtherIncomeSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FinancePaymentStyleValidationTest {

    @Test
    void expenseApproveLocksHierarchyBeforeExpenseRow() {
        EntityManager em = mock(EntityManager.class);
        Query hierarchyLock = mock(Query.class);
        when(em.createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY")))
                .thenReturn(hierarchyLock);
        FinanceExpenseRepository expenseRepo = mock(FinanceExpenseRepository.class);
        FinanceExpense expense = new FinanceExpense();
        expense.setBillDate(LocalDate.of(2026, 8, 14));
        when(expenseRepo.findById(expense.getId())).thenReturn(Optional.of(expense));
        doThrow(new IllegalStateException("expense row lock reached"))
                .when(em).refresh(expense, LockModeType.PESSIMISTIC_WRITE);
        FinanceExpenseService service = new FinanceExpenseService(
                expenseRepo, mock(FinanceExpenseItemRepository.class), mock(TxSessionVars.class), actor(),
                mock(EmployeeNameResolver.class), em, numbers("FY26080001"), mock(GlPostingService.class),
                mock(FinanceDocumentAccessPolicy.class), mock(AccountFlowLedgerService.class));

        assertThatThrownBy(() -> service.approve(expense.getId()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("expense row lock reached");

        InOrder order = inOrder(em, hierarchyLock);
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(hierarchyLock).getSingleResult();
        order.verify(em).refresh(expense, LockModeType.PESSIMISTIC_WRITE);
    }

    @Test
    void expenseCreateLocksHierarchyBeforeValidatingStyle() {
        EntityManager em = mock(EntityManager.class);
        StyleQueries queries = rejectingStyleQueries(em);
        FinanceExpenseItemRepository itemRepo = mock(FinanceExpenseItemRepository.class);
        SecurityContextCurrentUser currentUser = actor();
        DocNumberService numbers = numbers("FY26080001");
        FinanceExpenseService service = new FinanceExpenseService(
                mock(FinanceExpenseRepository.class), itemRepo, mock(TxSessionVars.class), currentUser,
                mock(EmployeeNameResolver.class), em, numbers, mock(GlPostingService.class),
                mock(FinanceDocumentAccessPolicy.class), mock(AccountFlowLedgerService.class));
        UUID styleId = UUID.randomUUID();

        assertThatThrownBy(() -> service.create(expenseRequest(styleId)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不是末级类别");

        InOrder order = inOrder(em, queries.hierarchyLock(), queries.styleValidation());
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(queries.hierarchyLock()).getSingleResult();
        order.verify(em).createNativeQuery(argThat(sql -> sql.contains("ps.status = '使用'")
                && sql.contains("ps.category = 'EXPENSE'")
                && sql.contains("NOT EXISTS")
                && sql.contains("child.parent_id = ps.id")));
        order.verify(queries.styleValidation()).setParameter("id", styleId);
        order.verify(queries.styleValidation()).getSingleResult();
        verify(itemRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void otherIncomeCreateLocksHierarchyBeforeValidatingStyle() {
        EntityManager em = mock(EntityManager.class);
        StyleQueries queries = rejectingStyleQueries(em);
        FinanceOtherIncomeItemRepository itemRepo = mock(FinanceOtherIncomeItemRepository.class);
        SecurityContextCurrentUser currentUser = actor();
        DocNumberService numbers = numbers("QT26080001");
        FinanceOtherIncomeService service = new FinanceOtherIncomeService(
                mock(FinanceOtherIncomeRepository.class), itemRepo, mock(TxSessionVars.class), currentUser,
                mock(EmployeeNameResolver.class), em, numbers, mock(FinanceDocumentAccessPolicy.class),
                mock(GlPostingService.class), mock(AccountFlowLedgerService.class));
        UUID styleId = UUID.randomUUID();

        assertThatThrownBy(() -> service.create(incomeRequest(styleId)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("不是末级类别");

        InOrder order = inOrder(em, queries.hierarchyLock(), queries.styleValidation());
        order.verify(em).createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"));
        order.verify(queries.hierarchyLock()).getSingleResult();
        order.verify(em).createNativeQuery(argThat(sql -> sql.contains("ps.status = '使用'")
                && sql.contains("ps.category = 'INCOME'")
                && sql.contains("NOT EXISTS")
                && sql.contains("child.parent_id = ps.id")));
        order.verify(queries.styleValidation()).setParameter("id", styleId);
        order.verify(queries.styleValidation()).getSingleResult();
        verify(itemRepo, never()).save(org.mockito.ArgumentMatchers.any());
    }

    private static StyleQueries rejectingStyleQueries(EntityManager em) {
        Query hierarchyLock = mock(Query.class);
        Query styleValidation = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("PAYMENT_STYLE_HIERARCHY")) return hierarchyLock;
            if (sql.contains("FROM payment_styles")) return styleValidation;
            throw new AssertionError("unexpected SQL: " + sql);
        });
        when(styleValidation.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(styleValidation);
        when(styleValidation.getSingleResult()).thenReturn(0L);
        return new StyleQueries(hierarchyLock, styleValidation);
    }

    private record StyleQueries(Query hierarchyLock, Query styleValidation) {
    }

    private static SecurityContextCurrentUser actor() {
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(UUID.randomUUID());
        return currentUser;
    }

    private static DocNumberService numbers(String billNo) {
        DocNumberService service = mock(DocNumberService.class);
        when(service.nextNumber(org.mockito.ArgumentMatchers.any())).thenReturn(billNo);
        return service;
    }

    private static FinanceExpenseSaveRequest expenseRequest(UUID styleId) {
        FinanceExpenseItemInput item = new FinanceExpenseItemInput();
        item.setExpenseStyleId(styleId);
        item.setAmountLocal(BigDecimal.ONE);
        FinanceExpenseSaveRequest request = new FinanceExpenseSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 13));
        request.setItems(List.of(item));
        return request;
    }

    private static FinanceOtherIncomeSaveRequest incomeRequest(UUID styleId) {
        FinanceOtherIncomeItemInput item = new FinanceOtherIncomeItemInput();
        item.setIncomeStyleId(styleId);
        item.setAmountLocal(BigDecimal.ONE);
        FinanceOtherIncomeSaveRequest request = new FinanceOtherIncomeSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 13));
        request.setItems(List.of(item));
        return request;
    }
}
