package com.uten.imp.features.expenseclaim.ocr;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.ExpenseOcrProperties;
import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class InvoicePrefillAdapterSecurityTest {
    private final InvoiceRecognitionService recognition = mock(InvoiceRecognitionService.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules();
    private final InvoicePrefillAdapter adapter = new InvoicePrefillAdapter(recognition, current, json);

    @Test void adapterIndependentlyRejectsRevokedLockedPasswordChangeVisitorAndImpersonatedActors() {
        List<AuthUser> blocked = List.of(
                actor(Set.of(), false, true, null),
                actor(Set.of("expense:apply"), true, true, null),
                actor(Set.of("expense:apply"), false, false, null),
                actor(Set.of("expense:apply"), false, true, UUID.randomUUID()),
                AuthUser.visitor(UUID.randomUUID(), "visitor", "V", Set.of("expense:apply")));
        for (AuthUser actor : blocked) {
            when(current.get()).thenReturn(Optional.of(actor));
            assertThatThrownBy(() -> adapter.fromText(List.of("价税合计:100.00"))).isInstanceOf(ApiException.class);
            assertThatThrownBy(() -> adapter.fromImage(new byte[]{1, 2, 3}, "image/png")).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(recognition);
    }

    @Test void adapterOmitsBlankOcrFieldsAndUsesPlainDecimalAndIsoDate() {
        when(current.get()).thenReturn(Optional.of(actor(Set.of("expense:apply"), false, true, null)));
        when(recognition.recognize(any())).thenReturn(new RecognizedInvoiceDto("", " ", "", LocalDate.of(2026, 10, 3),
                "", null, "", null, null, null, new BigDecimal("1E+10"), ""));
        Map<String, Object> fields = adapter.fromImage(new byte[]{1, 2, 3}, "image/png");
        assertThat(fields).containsEntry("issueDate", "2026-10-03").containsEntry("totalAmount", "10000000000")
                .doesNotContainKeys("invoiceNo", "invoiceCode", "invoiceType", "sellerName", "buyerName", "itemSummary");
    }

    @Test void multipleTextInvoicesCannotBePrefilledEvenWhenTheRouteHandlerIsBypassed() {
        when(current.get()).thenReturn(Optional.of(actor(Set.of("expense:apply"), false, true, null)));
        assertThat(adapter.fromText(List.of("电子发票", "价税合计:100.00", "电子发票", "价税合计:200.00"))).isEmpty();
        verifyNoInteractions(recognition);
    }

    @Test void imageOcrTextUsesTheSameMultiInvoiceGuardWithoutAnyNetworkCall() throws Exception {
        PaddleOcrClient client = new PaddleOcrClient(new ExpenseOcrProperties());
        String response = json.writeValueAsString(Map.of("lines", List.of(
                Map.of("text", "电子发票"), Map.of("text", "发票号码:12345678"), Map.of("text", "价税合计:100.00"),
                Map.of("text", "发票号码:87654321"), Map.of("text", "价税合计:200.00"))));
        assertThat(client.parse(response)).isNull();
    }

    private static AuthUser actor(Set<String> permissions, boolean changePassword, boolean unlocked, UUID impersonatedBy) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "invoice-test", permissions, changePassword, unlocked,
                false, false, impersonatedBy, UUID.randomUUID());
    }
}
