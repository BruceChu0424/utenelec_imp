package com.uten.imp.features.finance.gl;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GlPostingLegacyCashGuardTest {
    @ParameterizedTest
    @ValueSource(strings={"receipt", "receiptReverse", "payment", "paymentReverse", "expense", "expenseConfirm",
            "removePayment", "removeExpense", "removeIncome", "removeTransfer"})
    void everyDirectWriterRefusesLegacyCashBeforeAnyGlStatement(String action) {
        EntityManager em=mock(EntityManager.class);
        List<String> statements=new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0); statements.add(sql);
            Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of(906002));
            return query;
        });
        var service=new GlPostingService(em,mock(TxSessionVars.class));
        UUID id=UUID.randomUUID();
        assertThatThrownBy(()->{
            switch(action) {
                case "receipt" -> service.postReceiptDoc(id);
                case "receiptReverse" -> service.reverseReceiptDoc(id,OffsetDateTime.now());
                case "payment" -> service.postActualBankPayment(id);
                case "paymentReverse" -> service.reverseActualBankPayment(id,OffsetDateTime.now());
                case "expense" -> service.postExpenseDoc(id);
                case "expenseConfirm" -> service.requireConfirmableExpenseVoucher(id,UUID.randomUUID(),"cash",BusinessTime.today());
                case "removePayment" -> service.removePaymentDoc(id,"cash",BusinessTime.today());
                case "removeExpense" -> service.removeExpenseDoc(id,"cash",BusinessTime.today());
                case "removeIncome" -> service.removeAutoProjection("INCOME","INCOME",id,"cash",BusinessTime.today());
                case "removeTransfer" -> service.removeAutoProjection("BANK_TRANSFER","BANK_TRANSFER",id,"cash",BusinessTime.today());
                default -> throw new AssertionError(action);
            }
        }).isInstanceOf(ApiException.class).hasMessageContaining("历史资金记录仅供核对");
        assertThat(statements).hasSize(1).allSatisfy(sql->assertThat(sql).startsWith("SELECT legacy_id FROM finance_"));
    }
}
