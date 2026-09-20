package com.uten.imp.features.expenseclaim;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.EmployeeClaimPostingPort.EmployeeClaimPosting;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.accountflow.AccountFlowLedgerService;
import com.uten.imp.features.finance.expense.*;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
/** A payment and a normal expense reversal must never take the account/GL locks in opposite order. */
class ExpenseFinancePostingLockOrderTest {
    @Test void controlledEmployeePaymentLocksAccountingPeriodBeforeAccount() {
        var em=mock(EntityManager.class);var global=mock(Query.class);var account=mock(Query.class);
        when(em.createNativeQuery(contains("PAYMENT_STYLE_HIERARCHY"))).thenReturn(global);
        when(em.createNativeQuery(contains("FROM accounts"))).thenReturn(account);
        when(account.setParameter(anyString(),any())).thenReturn(account);when(account.getResultList()).thenReturn(List.of());
        var gl=mock(GlPostingService.class);
        var service=new FinanceExpenseService(mock(FinanceExpenseRepository.class),mock(FinanceExpenseItemRepository.class),
            mock(TxSessionVars.class),mock(SecurityContextCurrentUser.class),mock(EmployeeNameResolver.class),em,
            mock(DocNumberService.class),gl,mock(FinanceDocumentAccessPolicy.class),mock(AccountFlowLedgerService.class));
        LocalDate date=LocalDate.of(2026,9,19);
        assertThrows(ApiException.class,()->service.postEmployeeClaim(new EmployeeClaimPosting(
            UUID.randomUUID(),date,UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),new BigDecimal("100"))));
        var order=inOrder(gl,account);order.verify(gl).lockAutoProjectionPeriod(date);order.verify(account).getResultList();
    }
}
