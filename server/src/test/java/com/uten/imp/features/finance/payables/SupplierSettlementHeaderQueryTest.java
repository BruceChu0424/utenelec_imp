package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SupplierSettlementHeaderQueryTest {
    @Test
    void frozenBatchHeadersShareTypedPredicatesBetweenRowsAndCountBeforePagination() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class, RETURNS_SELF);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(51L);
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            statements.add(call.getArgument(0));
            return query;
        });
        var service = new SupplierSettlementService(em, null, null, null, null);
        var result = service.list(null, null, "FROZEN", null, 2, 30,
                Map.of("search.batchNo", "_%", "search.currencyCode", "人民币",
                        "search.closingBalanceOriginal", "-0.0000000001..9007199254740993.0001",
                        "sort", "closingBalanceOriginal", "order", "asc"));
        assertThat(result.total()).isEqualTo(51);
        assertThat(statements).hasSize(2);
        for (String sql : statements) {
            assertThat(sql).contains("batch.closing_balance_original BETWEEN :header_closingBalanceOriginal_lower"
                    + " AND :header_closingBalanceOriginal_upper");
            assertThat(sql).contains("header_batchNo", "header_currencyCode", "batch.status=:status");
            assertThat(sql).doesNotContain("9007199254740993", "_%");
        }
        assertThat(statements.getFirst()).contains("ORDER BY batch.closing_balance_original ASC NULLS LAST,batch.id");
        assertThat(statements.getLast()).doesNotContain("LIMIT", "OFFSET");
        verify(query, times(2)).setParameter("header_closingBalanceOriginal_lower", new BigDecimal("-0.0000000001"));
        verify(query, times(2)).setParameter("header_closingBalanceOriginal_upper", new BigDecimal("9007199254740993.0001"));
        verify(query).setParameter("offset", 30L);
    }

    @Test
    void invalidAmountCannotExecute() {
        EntityManager em = mock(EntityManager.class);
        var service = new SupplierSettlementService(em, null, null, null, null);
        assertThatThrownBy(() -> service.list(null, null, null, null, 1, 30,
                Map.of("search.closingBalanceOriginal", "0 OR 1=1"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }
}
