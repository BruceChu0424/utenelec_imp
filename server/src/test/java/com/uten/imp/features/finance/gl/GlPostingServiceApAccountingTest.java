package com.uten.imp.features.finance.gl;

import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GlPostingServiceApAccountingTest {

    @Test
    void subcontractReturnsAndWasteParticipateInGenericApProjectionGates() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> statements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0));
            return query;
        });

        new GlPostingService(em, mock(TxSessionVars.class)).generate("2026-08");

        assertContainsGenericSubcontractReductions(find(statements, "WITH required_role(role_key)"));
        assertContainsGenericSubcontractReductions(find(
                statements, "ledger.source_doc_id IS NULL", "'PURCHASE_RECEIPT'"));
        assertContainsGenericSubcontractReductions(find(statements, "'AUTO', 'AP_POST'"));
        assertContainsGenericSubcontractReductions(find(statements,
                "v.source_type = 'AP_POST'", "INSERT INTO gl_entries"));
    }

    private static String find(List<String> statements, String... requiredTokens) {
        return statements.stream()
                .filter(statement -> {
                    for (String token : requiredTokens) {
                        if (!statement.contains(token)) {
                            return false;
                        }
                    }
                    return true;
                })
                .findFirst()
                .orElseThrow();
    }

    private static void assertContainsGenericSubcontractReductions(String sql) {
        assertThat(sql)
                .contains("'SUBCONTRACT_RETURN'")
                .contains("'SUBCONTRACT_WASTE'")
                .doesNotContain("'SUBCONTRACT_LOSS_OFFSET'");
    }
    @Test
    void supplierClaimRecognitionOffsetsAndCashUseDedicatedBalancedProjections() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        List<String> statements = new ArrayList<>();
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(0L);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0));
            return query;
        });

        new GlPostingService(em, mock(TxSessionVars.class)).generate("2026-08");

        String all = String.join("\n", statements);
        assertThat(all)
                .contains("'SUPPLIER_CLAIM_LEDGER'")
                .contains("'SUPPLIER_CLAIM_OFFSET'")
                .contains("'SUPPLIER_CLAIM_RECEIVABLE'")
                .contains("'SUPPLIER_CLAIM_CASH'")
                .contains("system_posting_style_id('SUPPLIER_CLAIM_RECEIVABLE')")
                .contains("system_posting_style_id('SUBCONTRACT_LOSS_RECOVERY')")
                .contains("system_posting_style_id('AP_CONTROL')")
                .contains("account_style_id(receipt.account_id)")
                .contains("system_posting_style_id('FX_GAIN_LOSS')")
                .contains("allocation.resolution_id IS NOT NULL")
                .contains("allocation.offset_batch_id")
                .contains("allocation.source_amount_local<>allocation.target_amount_local")
                .contains("receipt.exchange_difference<>0");
        assertThat(find(statements, "'AUTO', 'AP_POST'"))
                .doesNotContain("SUBCONTRACT_LOSS_OFFSET");
        assertThat(find(statements, "DELETE FROM gl_vouchers"))
                .contains("source_type IN (:sourceTypes)");
    }
}
