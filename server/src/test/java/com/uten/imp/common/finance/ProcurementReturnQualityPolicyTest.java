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
                new BigDecimal("4"), "RESOLVED", new BigDecimal("4"), UUID.randomUUID()}),
                List.of(event("PASS", "6"), event("FAIL", "4")), null);

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

    /**
     * ADR-112 评审用例: 3 件共 100, 不论先判不合格还是先判合格, 不合格金额 + 合格件全部可退额度
     * 恰好等于收货金额(原币与本币), 合格件全退后应付不留 0.0001 尾差。
     */
    @Test
    void failedAmountAndReturnableLimitAreComplementsInEitherDispositionOrder() {
        for (var events : List.of(
                List.of(event("FAIL", "1"), event("PASS", "2")),
                List.of(event("PASS", "2"), event("FAIL", "1")))) {
            UUID inspection = UUID.randomUUID();
            var source = policyResult(java.util.Collections.singletonList(new Object[]{
                    new BigDecimal("3"), new BigDecimal("2"), BigDecimal.ONE, "RESOLVED",
                    new BigDecimal("2"), inspection}), events, null);
            BigDecimal failedOriginal = ProcurementIqcAmountSplit.failedSlices(
                    new BigDecimal("100"), new BigDecimal("3"), toEvents(events), BigDecimal.ONE);
            BigDecimal failedLocal = ProcurementIqcAmountSplit.failedSlices(
                    new BigDecimal("710"), new BigDecimal("3"), toEvents(events), BigDecimal.ONE);

            var result = ProcurementReturnQualityPolicy.lockAndLimit(
                    source.em(), "PURCHASE", UUID.randomUUID(),
                    new BigDecimal("3"), BigDecimal.ONE,
                    new BigDecimal("100"), new BigDecimal("710"));

            assertThat(failedOriginal.add(result.amountOriginal())).isEqualByComparingTo("100");
            assertThat(failedLocal.add(result.amountLocal())).isEqualByComparingTo("710");
        }
    }

    @Test
    void frozenQualityFailureIsTheComplementBasisWhenItIsFinite() {
        var source = policyResult(java.util.Collections.singletonList(new Object[]{
                new BigDecimal("32"), new BigDecimal("31"), BigDecimal.ONE, "RESOLVED",
                new BigDecimal("31"), UUID.randomUUID()}),
                List.of(event("FAIL", "1"), event("PASS", "31")),
                new Object[]{2L, new BigDecimal("0.03125"), new BigDecimal("0.221875")});

        var result = ProcurementReturnQualityPolicy.lockAndLimit(
                source.em(), "PURCHASE", UUID.randomUUID(),
                new BigDecimal("32"), BigDecimal.ONE,
                BigDecimal.ONE, new BigDecimal("7.1"));

        // 冻结的不合格资金分项 0.03125 是不合格任务与贷项的同一份事实, 可退额度取它的补数。
        assertThat(result.amountOriginal()).isEqualByComparingTo("0.96875");
        assertThat(result.amountLocal()).isEqualByComparingTo("6.878125");
    }

    @Test
    void pendingInspectionCannotBeHiddenByOtherSameGoodsInventory() {
        var source = policyResult(java.util.Collections.singletonList(new Object[]{
                new BigDecimal("10"), new BigDecimal("6"),
                BigDecimal.ZERO, "PARTIAL", BigDecimal.ZERO, UUID.randomUUID()}), List.of(), null);

        assertThatThrownBy(() -> ProcurementReturnQualityPolicy.lockAndLimit(
                source.em(), "PURCHASE", UUID.randomUUID(),
                new BigDecimal("10"), BigDecimal.ONE,
                new BigDecimal("100"), new BigDecimal("100")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("尚未完成 IQC");
    }

    @Test
    void legacyReceiptWithoutInspectionKeepsAuditedReceiptAuthority() {
        var source = policyResult(List.of(), List.of(), null);

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

    private static Fixture policyResult(List<Object[]> rows, List<Object[]> events, Object[] frozen) {
        EntityManager em = mock(EntityManager.class);
        AtomicReference<String> sql = new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String text = invocation.getArgument(0);
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenReturn(query);
            if (text.contains("procurement_iqc_quality_consideration_parts")) {
                when(query.getResultList()).thenReturn(java.util.Collections.singletonList(
                        frozen == null ? new Object[]{0L, null, null} : frozen));
            } else if (text.contains("procurement_inspection_events")) {
                when(query.getResultList()).thenReturn(events);
            } else {
                sql.set(text);
                when(query.getResultList()).thenReturn(rows);
            }
            return query;
        });
        return new Fixture(em, sql);
    }

    private static Object[] event(String action, String qty) {
        return new Object[]{action, new BigDecimal(qty)};
    }

    private static List<ProcurementIqcAmountSplit.Event> toEvents(List<Object[]> events) {
        return events.stream().map(row -> new ProcurementIqcAmountSplit.Event(
                "PASS".equals(row[0]), (BigDecimal) row[1])).toList();
    }

    private record Fixture(EntityManager em, AtomicReference<String> sql) {
    }
}
