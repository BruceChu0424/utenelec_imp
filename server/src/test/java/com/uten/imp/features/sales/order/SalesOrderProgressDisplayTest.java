package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class SalesOrderProgressDisplayTest {
    @Mock EntityManager em;
    @Mock SalesDocumentAccessPolicy access;
    @InjectMocks SalesOrderService service;

    @Test
    void authorizedResponseNeverManufacturesAMixedProductPercentage() {
        UUID owner = UUID.randomUUID();
        when(access.nativeReadScope(anyString(), anyString())).thenReturn(
                new NativeReadScope("o.owner_employee_id IN (:salesOwners)", "salesOwners", Set.of(owner)));
        Query count = mock(Query.class, RETURNS_SELF);
        Query rows = mock(Query.class, RETURNS_SELF);
        when(count.getSingleResult()).thenReturn(1L);
        // Aggregated quantities may include one piece and 1000 metres. They are
        // legacy stage inputs, never a denominator for a product-completion display.
        when(rows.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                UUID.randomUUID().toString(), "SO-MIXED", "2026-10-12", "2026-10-13", "",
                new BigDecimal("1001"), BigDecimal.ONE, BigDecimal.ZERO, BigDecimal.ZERO,
                new BigDecimal("1001"), true, false, null, "", null, false, false,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, 1
        }));
        when(em.createNativeQuery(anyString())).thenReturn(count, rows);

        var result = service.progress(1, 50, "IN_PROGRESS", null, null, null, null, null, null);
        var row = result.getItems().getFirst();
        assertThat(row.productionPct()).isNull();
        assertThat(row.stage()).isEqualTo("PRODUCING");
        assertThat(row.orderQty()).isEqualTo(1001);
        assertThat(row.producedQty()).isEqualTo(1);
        assertThat(new ObjectMapper().valueToTree(row).get("productionPct").isNull()).isTrue();
        verify(count).setParameter("salesOwners", Set.of(owner));
        verify(rows).setParameter("salesOwners", Set.of(owner));
        var queries = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(queries.capture());
        assertThat(queries.getAllValues()).allMatch(sql -> sql.contains("o.owner_employee_id IN (:salesOwners)"));
    }
}
