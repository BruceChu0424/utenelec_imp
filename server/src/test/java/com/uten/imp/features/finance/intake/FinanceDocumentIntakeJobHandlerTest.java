package com.uten.imp.features.finance.intake;

import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceDocumentIntakeJobHandlerTest {
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final AiJobHandler.AiJobContext ctx = mock(AiJobHandler.AiJobContext.class);
    private final FinanceDocumentIntakeJobHandler handler = new FinanceDocumentIntakeJobHandler(current);
    @BeforeEach void before() {
        actor(Set.of("finance_receipt:view", "finance_receipt:create", "finance_payment:view", "finance_payment:create"));
        when(ctx.params()).thenReturn(Map.of("docType", "receipt"));
    }
    private void actor(Set<String> permissions) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "test", permissions, false, true, false)));
    }
    private void csv(String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        when(ctx.input()).thenReturn(new AiJobHandler.AiJobInput("bank.csv", "text/csv", "CSV", bytes.length, bytes, "a".repeat(64)));
    }
    @Test void exactReceiptIsLocalAndPreservesSourceAndDecimalText() {
        csv("银行回单\n银行流水号,交易日期,实收金额,币种,手续费\nBANK-00001,2026-10-03,1234.56,USD,12.30\n");
        Map<String, Object> result = handler.process(ctx);
        assertThat(result.get("fields")).isEqualTo(Map.of("bankReference", "BANK-00001", "transactionDate", "2026-10-03", "accountAmount", "1234.56", "currencyCode", "USD", "bankFee", "12.30"));
        assertThat(result.get("source")).isEqualTo(Map.of("fileName", "bank.csv", "sha256", "a".repeat(64)));
        assertThat(result).containsEntry("docType", "receipt").containsEntry("requiresReview", true);
        verify(ctx, never()).completeJson(any()); verify(ctx, never()).aiAllowed();
    }
    @Test void readAndFilterRecheckCurrentPermissions() {
        csv("银行流水号,ABC-123\n实收金额,100.00\n");
        var result = handler.process(ctx);
        actor(Set.of("finance_receipt:view"));
        assertThatThrownBy(() -> handler.authorizeRead(Map.of("docType", "receipt"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> handler.filterResultForReader(result)).isInstanceOf(ApiException.class);
    }
    @Test void forgedScopeAndUnsupportedDestinationAreRejectedBeforeReading() {
        assertThatThrownBy(() -> handler.authorizeSubmit(Map.of("docType", "receipt", "docId", UUID.randomUUID().toString()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> handler.authorizeSubmit(Map.of("docType", "expense"))).isInstanceOf(ApiException.class);
        actor(Set.of("finance_payment:view", "finance_payment:create"));
        assertThatThrownBy(() -> handler.authorizeSubmit(Map.of("docType", "receipt"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(ctx);
    }
    @Test void guestImpersonationAndUnboundStaffCannotSubmit() {
        var permissions = Set.of("finance_receipt:view", "finance_receipt:create");
        for (AuthUser actor : java.util.List.of(
                AuthUser.visitor(UUID.randomUUID(), "guest", "V1", permissions),
                new AuthUser(UUID.randomUUID(), null, "unbound", permissions, false, true, false),
                new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "impersonated", permissions, false, true, false, false, UUID.randomUUID()))) {
            when(current.get()).thenReturn(Optional.of(actor));
            assertThatThrownBy(() -> handler.authorizeSubmit(Map.of("docType", "receipt"))).isInstanceOf(ApiException.class);
        }
    }
    @Test void cancellationStopsBeforeDocumentParsing() {
        csv("damaged"); when(ctx.cancelled()).thenReturn(true);
        assertThat(handler.process(ctx)).isEmpty();
        verify(ctx, never()).completeJson(any());
    }
}
