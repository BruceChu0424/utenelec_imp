package com.uten.imp.features.finance.gl;

import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class GlPostingServiceIsolationTest {

    @Test
    void regeneratedSourceTypesNeverIncludeAssetSubledgerVouchers() {
        assertThat(GlPostingService.REGENERATED_SOURCE_TYPES)
                .containsExactlyInAnyOrder(
                        "AR_POST", "AP_POST", "RECEIPT", "PAYMENT", "EXPENSE", "INCOME", "COST_CARRY",
                        "BANK_TRANSFER", "SUPPLIER_CLAIM_LEDGER",
                        "SUPPLIER_CLAIM_OFFSET",
                        "SUPPLIER_CLAIM_RECEIVABLE",
                        "SUPPLIER_CLAIM_CASH",
                        "CUSTOMER_PREPAYMENT_OFFSET",
                        SubcontractWasteLossGlProjection.SOURCE_TYPE)
                .doesNotContain("FA_CAP", "DA_RECOGNITION", "FA_DEP", "DA_AMT", "FA_DISPOSAL");
    }

    @Test
    void generateDeletesOnlyItsOwnedSourceTypes() {
        EntityManager em = mock(EntityManager.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        when(query.executeUpdate()).thenReturn(0);
        when(query.getSingleResult()).thenReturn(0L);

        new GlPostingService(em, tx).generate("2026-08");

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.atLeastOnce()).createNativeQuery(sql.capture());
        String deleteSql = sql.getAllValues().stream()
                .filter(statement -> statement.stripLeading().startsWith("DELETE FROM gl_vouchers"))
                .findFirst()
                .orElseThrow();
        assertThat(deleteSql).contains("source_type IN (:sourceTypes)");
        verify(query, org.mockito.Mockito.atLeastOnce())
                .setParameter("sourceTypes", GlPostingService.REGENERATED_SOURCE_TYPES);
        verify(tx).bind();
    }
}
