package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.features.finance.other_income.FinanceOtherIncomeService;
import com.uten.imp.features.finance.payment.FinancePaymentService;
import com.uten.imp.features.finance.receipt.FinanceReceiptService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Validation;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceBatchRecoveryValidationTest {
    private final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    private final UUID actor=UUID.randomUUID();
    private final NamedParameterJdbcTemplate db=mock(NamedParameterJdbcTemplate.class);
    private final FinanceExpenseService expenses=mock(FinanceExpenseService.class);
    private FinanceBatchEntryService service;
    @BeforeEach void setup() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,"test",List.of(new SimpleGrantedAuthority("finance_expense:view"))));
        var current=mock(SecurityContextCurrentUser.class);when(current.requireId()).thenReturn(actor);
        var identity=mock(AuthUser.class);when(identity.isAccountNonLocked()).thenReturn(true);when(current.get()).thenReturn(Optional.of(identity));
        service=new FinanceBatchEntryService(db,json,Validation.buildDefaultValidatorFactory().getValidator(),current,mock(AuditService.class),
                mock(FinanceReceiptService.class),mock(FinancePaymentService.class),expenses,mock(FinanceOtherIncomeService.class),mock(FinanceBankTransferService.class));
        when(db.update(anyString(),org.mockito.ArgumentMatchers.<Map<String,?>>any())).thenReturn(1);
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void anOriginalCreationRejectedForRowLimitCanStillSealAllOfItsOriginalRows()throws Exception {
        var rows=json.createArrayNode();for(int index=0;index<501;index++)rows.addObject().put("originalRow",index).put("amount","0.000000000000000000000001");
        var body=json.createObjectNode().put("idempotencyKey","over-limit-original").set("documents",rows);
        var result=service.cancelUnwritten("expenses","over-limit-original",new FinanceBatchEntryController.Cancellation(actor,body));
        assertThat(result).containsEntry("outcome","CANCELLED_UNWRITTEN").containsEntry("requestBody",body);
        assertThat(((com.fasterxml.jackson.databind.JsonNode)result.get("requestBody")).path("documents")).hasSize(501);
        verifyNoInteractions(expenses);
    }
    @Test void anIgnoredOriginalFieldCannotBeUsedToPretendThatDifferentContentWasCancelled()throws Exception {
        var body=json.readTree("{\"idempotencyKey\":\"original-field-key\",\"documents\":[],\"ignoredGuess\":true}");
        assertThatThrownBy(()->service.cancelUnwritten("expenses","original-field-key",new FinanceBatchEntryController.Cancellation(actor,body)))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("完整正文");
        verifyNoInteractions(db);
    }
    @Test void noTerminalCancellationIsReturnedWhenTheInsertDidNotPersistOneRow()throws Exception {
        when(db.update(anyString(),org.mockito.ArgumentMatchers.<Map<String,?>>any())).thenReturn(0);
        var body=json.readTree("{\"idempotencyKey\":\"missing-receipt-key\",\"documents\":[]}");
        assertThatThrownBy(()->service.cancelUnwritten("expenses","missing-receipt-key",new FinanceBatchEntryController.Cancellation(actor,body)))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("取消证据尚未保存");
    }
}
