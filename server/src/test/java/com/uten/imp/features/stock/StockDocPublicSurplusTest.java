package com.uten.imp.features.stock;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class StockDocPublicSurplusTest {
    @Test void mixedPublicInboundAndReverseNeverTouchSalesOrReserveBackToAnalysis() {
        Fixture fixture = new Fixture("1000", "1000", "0");
        fixture.apply(1);
        assertThat(fixture.sql).anyMatch(sql -> sql.contains("UPDATE production_plan_items"));
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("FROM plan_order_item_links l")
                || sql.contains("UPDATE sales_order_items") || sql.contains("UPDATE plan_order_item_links"));
        verifyNoInteractions(fixture.reservations, fixture.peg);

        Fixture reverse = new Fixture("1000", "1000", "1000");
        reverse.apply(-1);
        assertThat(reverse.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
        verifyNoInteractions(reverse.reservations, reverse.peg);
    }

    @Test void publicInboundCannotBorrowSalesApprovedReportQuantity() {
        Fixture fixture = new Fixture("1000", "0", "0");
        assertThrows(ApiException.class, () -> fixture.apply(1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void entirelyPublicLaterBatchDoesNotPegBackToTheSalesAnalysis() {
        // Current segment has no sales allocation: its quota equals its whole
        // plan. The original plan item's sales ownership lives in sibling batches.
        Fixture fixture = new Fixture("1000", "1000", "0", "1000", true);
        fixture.apply(1);
        verifyNoInteractions(fixture.reservations, fixture.peg);
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
    }

    @Test void internalMakeBatchRetainsItsExactAnalysisPeg() {
        Fixture fixture = new Fixture("1000", "1000", "0", "1000", false);
        fixture.apply(1);
        verify(fixture.peg).pegFinishedInbound(eq(fixture.document.getId()), eq(fixture.planId),
                eq(fixture.document.getWarehouseId()), anyList());
        verifyNoInteractions(fixture.reservations);
    }

    @Test void actualSurplusOfInternalMakeTaskBecomesPublicWithoutInheritedAnalysisOwnership() {
        Fixture fixture = new Fixture("1300", "1300", "300", "1000", false, true);
        fixture.apply(1);
        verifyNoInteractions(fixture.reservations, fixture.peg);
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
    }

    @Test void actualSurplusStillCannotExceedItsApprovedAndUnreceivedSource() {
        Fixture fixture = new Fixture("1300", "1300", "301", "1000", false, true);
        assertThrows(ApiException.class, () -> fixture.apply(1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void actualSurplusReversalDoesNotCreateAnOriginalAnalysisClaim() {
        Fixture fixture = new Fixture("1300", "1300", "1000", "1000", false, true);
        fixture.apply(-1);
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void publicInboundCannotExceedPublicQuotaEvenAfterRecoveryReports() {
        Fixture fixture = new Fixture("1000", "2000", "600");
        assertThrows(ApiException.class, () -> fixture.apply(1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
    }

    @Test void sameDocumentPublicLinesAreValidatedTogetherBeforeAnyPlanWrite() {
        Fixture fixture = new Fixture("1000", "2000", "0");
        fixture.item.setQty(new BigDecimal("600"));
        StockDocumentItem second = new StockDocumentItem();
        second.setId(UUID.randomUUID()); second.setGoodsId(fixture.goods); second.setUnitId(fixture.unit);
        second.setQty(new BigDecimal("600")); second.setUpstreamItemId(fixture.planItem);
        second.setExecutionSegmentId(fixture.item.getExecutionSegmentId());
        assertThrows(ApiException.class, () -> ReflectionTestUtils.invokeMethod(fixture.service,
                "applyFinishedInChain", fixture.document, List.of(fixture.item, second), 1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void publicReverseValidatesZeroSalesReservationsWithoutGuessingTheOnlyPlanLink() {
        Fixture fixture = new Fixture("1000", "1000", "1000");
        ReflectionTestUtils.invokeMethod(fixture.service, "validateExactFinishedInReverseMapping",
                fixture.document, List.of(fixture.item), fixture.planId);
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("FROM plan_order_item_links"));
        assertThat(fixture.sql).anyMatch(sql -> sql.contains("FROM stock_reservations"));
    }

    private static class Fixture {
        final UUID planId=UUID.randomUUID(), planItem=UUID.randomUUID(), unit=UUID.randomUUID();
        final UUID goods=UUID.randomUUID();
        final List<String> sql = new ArrayList<>();
        final EntityManager em=mock(EntityManager.class);
        final StockReservationService reservations=mock(StockReservationService.class);
        final PreplanAnalysisPegPort peg=mock(PreplanAnalysisPegPort.class);
        final StockDocService service=mock(StockDocService.class, CALLS_REAL_METHODS);
        final StockDocument document=new StockDocument();
        final StockDocumentItem item=new StockDocumentItem();
        Fixture(String quota, String reported, String inbound) {
            this(quota, reported, inbound, "2000", false);
        }
        Fixture(String quota, String reported, String inbound, String planned, boolean approvedSalesSurplus) {
            this(quota, reported, inbound, planned, approvedSalesSurplus, false);
        }
        Fixture(String quota, String reported, String inbound, String planned, boolean approvedSalesSurplus,
                boolean explicitPublicOutput) {
            ReflectionTestUtils.setField(service,"em",em);
            ReflectionTestUtils.setField(service,"reservationService",reservations);
            ReflectionTestUtils.setField(service,"preplanAnalysisPeg",peg);
            document.setId(UUID.randomUUID()); document.setWarehouseId(UUID.randomUUID());
            item.setId(UUID.randomUUID()); item.setGoodsId(goods); item.setUnitId(unit);
            item.setUnitRate(BigDecimal.ONE); item.setQty(new BigDecimal("1000"));
            item.setUpstreamItemId(planItem); item.setExecutionSegmentId(UUID.randomUUID());
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                String querySql=invocation.getArgument(0); sql.add(querySql.stripLeading());
                Query query=mock(Query.class);
                when(query.setParameter(anyString(),any())).thenReturn(query);
                when(query.executeUpdate()).thenReturn(1);
                List<Object[]> rows;
                if(querySql.contains("SELECT DISTINCT l.plan_id FROM plan_draw_links")) {
                    when(query.getResultList()).thenReturn(List.of(planId));
                    return query;
                } else if(querySql.contains("SELECT segment.planned_qty")) {
                    rows=java.util.Collections.singletonList(new Object[]{new BigDecimal(quota),
                            new BigDecimal(reported),new BigDecimal(inbound),new BigDecimal(planned),approvedSalesSurplus,
                            explicitPublicOutput});
                } else if(querySql.contains("SELECT i.goods_id")) {
                    rows=java.util.Collections.singletonList(new Object[]{goods,null,unit,BigDecimal.ONE});
                } else if(querySql.contains("AS item_remain")) {
                    rows=java.util.Collections.singletonList(new Object[]{planItem,new BigDecimal("2000"),unit,BigDecimal.ONE});
                } else rows=List.of();
                when(query.getResultList()).thenReturn(rows);
                return query;
            });
        }
        void apply(int sign) {
            ReflectionTestUtils.invokeMethod(service,"allocateFinishedIn",document,item,planId,
                    new BigDecimal("1000"),sign,new BigDecimal("1000"));
        }
    }
}
