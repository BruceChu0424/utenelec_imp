package com.uten.imp.common.finance;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class ProcurementReceiptAmountPreviewTest {

    private AutoCloseable precision;

    @BeforeEach
    void bindExplicitPrecisionChoice() {
        // 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）：100/3 等累计份额除不尽，
        // 按 ADR-112 既有四位 HALF_UP 分摊，末批收回全部余量。
        precision = BusinessPrecisionContext.use(Map.of(
                "money.cumulative-share", new BusinessPrecisionContext.Choice(4, "HALF_UP")));
    }

    @AfterEach
    void releaseExplicitPrecisionChoice() throws Exception {
        precision.close();
    }

    private static BigDecimal n(String value) { return new BigDecimal(value); }

    @Test void multipleRowsForOneSourceWithinADraftShareTheRemainder() {
        cumulativeDraft(false);
    }

    @Test void enteredTotalWithoutExtraColumnsUsesSourceRemainderInDraft() {
        cumulativeDraft(true);
    }

    /** ADR-144 §2.2：收满订货量时金额 = 订单金额分毫不差；容差内多收的部分按订单单价另计，超出 Q+T 不给金额。 */
    @Test void purchaseToleranceIsPricedOnlyBeyondTheOrderQuantity() {
        var draft = cumulativeDraft(false, n("5"));
        var item = lastItem;
        var tolerance = draft.line(item, n("0.15"), n("30"), n("7.1"));
        assertEquals(0, n("4.5").compareTo(tolerance.original()), "T = 3 × 5% = 0.15, 按单价 30 计价");
        assertEquals(0, n("31.95").compareTo(tolerance.local()));
        assertNull(draft.line(item, n("0.0001"), n("30"), n("7.1")).original(), "超过 Q+T 的部分要走财务");
    }

    private java.util.UUID lastItem;

    private void cumulativeDraft(boolean totalPricing) {
        var draft = cumulativeDraft(totalPricing, null);
        assertNull(draft.line(lastItem,n("1"),n("30"),n("7.1")).original());
    }

    private ProcurementReceiptAmountPreview.Draft cumulativeDraft(boolean totalPricing, BigDecimal tolerancePct) {
        var em = org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var replacement = org.mockito.Mockito.mock(ProcurementIqcReplacementAllocationService.class);
        var source = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var prior = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var allowance = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var historyRate = org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0);
            return sql.contains("i.extra_columns") ? source : sql.contains("approved_excess_qty") ? allowance
                    : sql.contains("r.exchange_rate IS NULL") ? historyRate : prior;
        });
        for (var query : java.util.List.of(source, prior, allowance,historyRate))
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(), org.mockito.ArgumentMatchers.any())).thenReturn(query);
        org.mockito.Mockito.when(source.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{n("3"), n("30"), n("100"), n("710"), n("7.1"), n("0"), totalPricing ? "[]" : "[{\"operation\":\"ADD\"}]", totalPricing ? n("100") : null, tolerancePct,java.util.UUID.randomUUID()}));
        org.mockito.Mockito.when(historyRate.getSingleResult()).thenReturn(0L);
        org.mockito.Mockito.when(prior.getSingleResult()).thenReturn(new Object[]{n("0"),n("0"),n("0")});
        org.mockito.Mockito.when(allowance.getSingleResult()).thenReturn(n("0"));
        var item = java.util.UUID.randomUUID();
        lastItem = item;
        org.mockito.Mockito.when(replacement.releasedCapacity("PURCHASE", item)).thenReturn(
                new ProcurementIqcReplacementAllocationService.ReleasedCapacity(n("0"), n("0"), n("0"), n("0")));
        var draft = new ProcurementReceiptAmountPreview(em, replacement).draft("PURCHASE", java.util.UUID.randomUUID());
        var first = draft.line(item,n("1"),n("30"),n("7.1"));
        var second = draft.line(item,n("1"),n("30"),n("7.1"));
        var third = draft.line(item,n("1"),n("30"),n("7.1"));
        assertEquals(0,n("33.3334").compareTo(second.original()));
        assertEquals(0,n("100").compareTo(first.original().add(second.original()).add(third.original())));
        assertEquals(0,n("710").compareTo(first.local().add(second.local()).add(third.local())));
        return draft;
    }

    @Test void fixedFeeIsAllocatedOnceWithFinalRemainder() {
        var first = ProcurementReceiptAmountPreview.allocated(n("1"),n("0"),n("3"),
                n("100"),n("710"),n("0"),n("0"));
        var second = ProcurementReceiptAmountPreview.allocated(n("1"),n("1"),n("3"),
                n("100"),n("710"),first.original(),first.local());
        var third = ProcurementReceiptAmountPreview.allocated(n("1"),n("2"),n("3"),
                n("100"),n("710"),first.original().add(second.original()),first.local().add(second.local()));
        assertEquals(0,n("100").compareTo(first.original().add(second.original()).add(third.original())));
        assertEquals(0,n("710").compareTo(first.local().add(second.local()).add(third.local())));
    }

    @Test void reversedAndReplacedAmountsUseRemainingSourceFact() {
        var remaining = ProcurementReceiptAmountPreview.allocated(n("2"),n("1"),n("3"),
                n("100"),n("710"),n("33.3333"),n("236.6667"));
        assertEquals(0,n("66.6667").compareTo(remaining.original()));
        assertEquals(0,n("473.3333").compareTo(remaining.local()));
    }

    @Test void unapprovedOverageHasNoInventedAmount() {
        var preview = ProcurementReceiptAmountPreview.allocated(n("4"),n("0"),n("3"),
                n("100"),n("710"),n("0"),n("0"));
        assertNull(preview.original());
        assertNull(preview.local());
    }

    @Test void subcontractActualAllowanceContinuesAfterTheOriginalTargetAndKeepsHistoricalVersionOne() {
        var em=org.mockito.Mockito.mock(jakarta.persistence.EntityManager.class);
        var replacement=org.mockito.Mockito.mock(ProcurementIqcReplacementAllocationService.class);
        var source=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var prior=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var allowance=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        var history=org.mockito.Mockito.mock(jakarta.persistence.Query.class);
        org.mockito.Mockito.when(em.createNativeQuery(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);
            return sql.contains("i.extra_columns")?source:sql.contains("approved_excess_qty")?allowance:
                    sql.contains("r.exchange_rate IS NULL")?history:prior;
        });
        for(var query:java.util.List.of(source,prior,allowance,history))
            org.mockito.Mockito.when(query.setParameter(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.any())).thenReturn(query);
        org.mockito.Mockito.when(source.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{
                n("1000"),n("50"),n("50000"),n("50000"),n("1"),n("0"),"[]",null,null,java.util.UUID.randomUUID(),n("1100")}));
        org.mockito.Mockito.when(history.getSingleResult()).thenReturn(0L);
        org.mockito.Mockito.when(prior.getSingleResult()).thenReturn(new Object[]{n("1000"),n("50000"),n("50000")});
        org.mockito.Mockito.when(allowance.getSingleResult()).thenReturn(n("0"));
        var item=java.util.UUID.randomUUID();
        org.mockito.Mockito.when(replacement.releasedCapacityWithOrdinaryReturns("SUBCONTRACT",item)).thenReturn(
                new ProcurementIqcReplacementAllocationService.ReleasedCapacity(n("0"),n("0"),n("0"),n("0")));
        var preview=new ProcurementReceiptAmountPreview(em,replacement);
        var draft=preview.draft("SUBCONTRACT",java.util.UUID.randomUUID());
        assertEquals(0,n("2500").compareTo(draft.line(item,n("50"),n("50"),n("1"),2).original()));
        assertEquals(0,n("2500").compareTo(draft.line(item,n("50"),n("50"),n("1"),2).original()));
        assertNull(draft.line(item,n("0.0001"),n("50"),n("1"),2).original());
        assertNull(preview.draft("SUBCONTRACT",java.util.UUID.randomUUID()).line(item,n("50"),n("50"),n("1"),1).original(),
                "a previously posted v1 receipt keeps its original consideration basis");
    }
}
