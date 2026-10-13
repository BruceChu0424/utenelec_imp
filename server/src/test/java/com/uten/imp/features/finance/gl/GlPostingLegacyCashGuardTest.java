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
import java.util.HashMap;
import java.util.List;
import java.util.Map;
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
    void everyDirectWriterRefusesLegacyCashBeforeAnyGlReadOrMutation(String action) {
        EntityManager em=mock(EntityManager.class);
        List<String> statements=new ArrayList<>();
        List<Map<String,Object>> parameters=new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation->{
            String sql=invocation.getArgument(0); statements.add(sql);
            Map<String,Object> bound=new HashMap<>();parameters.add(bound);
            Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenAnswer(parameter->{
                bound.put(parameter.getArgument(0),parameter.getArgument(1));
                return query;
            });
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
        if(action.startsWith("remove")) {
            // Removal holds the same period lock as regeneration before reading
            // the source guard. The lock reads no accounting rows and writes none.
            assertThat(statements).hasSize(2);
            assertThat(statements.getFirst())
                    .isEqualTo("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))");
            assertThat(parameters.getFirst()).containsExactlyEntriesOf(Map.of(
                    "key","uten:gl:auto-period:"+java.time.YearMonth.from(BusinessTime.today())));
        } else {
            assertThat(statements).hasSize(1);
        }
        String family=switch(action) {
            case "receipt","receiptReverse"->"receipts";
            case "payment","paymentReverse","removePayment"->"payments";
            case "expense","expenseConfirm","removeExpense"->"expenses";
            case "removeIncome"->"other_incomes";
            case "removeTransfer"->"bank_transfers";
            default->throw new AssertionError(action);
        };
        assertThat(statements.getLast()).isEqualTo("SELECT legacy_id FROM finance_"+family+" WHERE id=:id");
        assertThat(parameters.getLast()).containsExactlyEntriesOf(Map.of("id",id));
        assertThat(statements).noneMatch(sql->sql.contains("gl_vouchers") || sql.contains("gl_entries"));
    }
}
