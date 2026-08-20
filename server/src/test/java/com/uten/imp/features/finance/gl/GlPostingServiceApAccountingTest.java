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
    void subcontractReturnsAndWasteDeductionsParticipateInEveryApProjectionGate() {
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

        assertContainsBothSubcontractReductions(find(statements, "WITH required_role(role_key)"));
        assertContainsBothSubcontractReductions(find(statements, "ledger.source_doc_id IS NULL"));
        assertContainsBothSubcontractReductions(find(statements, "'AUTO', 'AP_POST'"));
        assertContainsBothSubcontractReductions(find(statements,
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

    private static void assertContainsBothSubcontractReductions(String sql) {
        assertThat(sql)
                .contains("'SUBCONTRACT_RETURN'")
                .contains("'SUBCONTRACT_WASTE'");
    }
}
