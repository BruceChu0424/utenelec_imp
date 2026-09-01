package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProcurementReturnQualityPolicyTest {

    @Test
    void mixedPassFailLimitsReturnAndCreditToWarehouseStockedSlice() {
        var source = policyResult(java.util.Collections.singletonList(new Object[]{
                new BigDecimal("10"), new BigDecimal("6"),
                new BigDecimal("4"), "RESOLVED", new BigDecimal("4")}));

        var result = ProcurementReturnQualityPolicy.lockAndLimit(
                source.em(), "SUBCONTRACT", UUID.randomUUID(),
                new BigDecimal("10"), BigDecimal.ONE,
                new BigDecimal("100"), new BigDecimal("700"));

        assertThat(result.qty()).isEqualByComparingTo("4.0000");
        assertThat(result.amountOriginal()).isEqualByComparingTo("40.0000");
        assertThat(result.amountLocal()).isEqualByComparingTo("280.0000");
        assertThat(result.legacyFallback()).isFalse();
        assertThat(source.sql().get())
                .contains("warehouse_stocked_base_qty", "FOR UPDATE");
    }

    @Test
    void pendingInspectionCannotBeHiddenByOtherSameGoodsInventory() {
        var source = policyResult(java.util.Collections.singletonList(new Object[]{
                new BigDecimal("10"), new BigDecimal("6"),
                BigDecimal.ZERO, "PARTIAL", BigDecimal.ZERO}));

        assertThatThrownBy(() -> ProcurementReturnQualityPolicy.lockAndLimit(
                source.em(), "PURCHASE", UUID.randomUUID(),
                new BigDecimal("10"), BigDecimal.ONE,
                new BigDecimal("100"), new BigDecimal("100")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("尚未完成 IQC");
    }

    @Test
    void legacyReceiptWithoutInspectionKeepsAuditedReceiptAuthority() {
        var source = policyResult(List.of());

        var result = ProcurementReturnQualityPolicy.lockAndLimit(
                source.em(), "PURCHASE", UUID.randomUUID(),
                new BigDecimal("3"), new BigDecimal("2"),
                new BigDecimal("9"), new BigDecimal("63"));

        assertThat(result.qty()).isEqualByComparingTo("3");
        assertThat(result.amountOriginal()).isEqualByComparingTo("9");
        assertThat(result.legacyFallback()).isTrue();
    }

    @Test
    void prelockUsesStableInspectionOrderBeforeReceiptAuthorityLocks() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        AtomicReference<String> sql = new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql.set(invocation.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());

        ProcurementReturnQualityPolicy.lockInspectionRows(
                em, "SUBCONTRACT", List.of(UUID.randomUUID(), UUID.randomUUID()));

        assertThat(sql.get()).contains("ORDER BY id", "FOR UPDATE");
    }

    private static Fixture policyResult(List<Object[]> rows) {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        AtomicReference<String> sql = new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            sql.set(invocation.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return new Fixture(em, sql);
    }

    private record Fixture(EntityManager em, AtomicReference<String> sql) {
    }
}
