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
    @Test void mixedPublicInboundAndReverseNeverTouchSalesAndKeepExactBatchSources() {
        Fixture fixture = new Fixture("1000", "1000", "0");
        fixture.apply(1);
        assertThat(fixture.sql).anyMatch(sql -> sql.contains("UPDATE production_plan_items"));
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("FROM plan_order_item_links l")
                || sql.contains("UPDATE sales_order_items") || sql.contains("UPDATE plan_order_item_links"));
        verifyNoInteractions(fixture.reservations);
        fixture.assertForwardedSlice();

        Fixture reverse = new Fixture("1000", "1000", "1000");
        reverse.apply(-1);
        assertThat(reverse.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
        reverse.assertReverseReleasedOnly();
    }

    @Test void publicInboundCannotBorrowSalesApprovedReportQuantity() {
        Fixture fixture = new Fixture("1000", "0", "0");
        assertThrows(ApiException.class, () -> fixture.apply(1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void entirelyPublicLaterBatchReachesPublicClaimClassificationWithoutSalesWrites() {
        // Current segment has no sales allocation: its quota equals its whole
        // plan. The original plan item's sales ownership lives in sibling batches.
        Fixture fixture = new Fixture("1000", "1000", "0", "1000", true);
        fixture.apply(1);
        verifyNoInteractions(fixture.reservations);
        fixture.assertForwardedSlice();
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
    }

    @Test void internalMakeBatchRetainsItsExactAnalysisPeg() {
        Fixture fixture = new Fixture("1000", "1000", "0", "1000", false);
        fixture.apply(1);
        fixture.assertForwardedSlice();
        verifyNoInteractions(fixture.reservations);
    }

    @Test void actualSurplusOfInternalMakeTaskPreservesItsSourceForPublicClaimClassification() {
        Fixture fixture = new Fixture("1300", "1300", "300", "1000", false, true);
        fixture.apply(1);
        verifyNoInteractions(fixture.reservations);
        fixture.assertForwardedSlice();
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
    }

    @Test void actualSurplusStillCannotExceedItsApprovedAndUnreceivedSource() {
        Fixture fixture = new Fixture("1300", "1300", "301", "1000", false, true);
        assertThrows(ApiException.class, () -> fixture.apply(1));
        assertThat(fixture.sql).noneMatch(sql -> sql.startsWith("UPDATE"));
        verifyNoInteractions(fixture.reservations, fixture.peg);
    }

    @Test void privateAndPublicSiblingRowsReachOneBatchWithoutReusingThePrivateBudget() {
        Fixture fixture = new Fixture("600", "600", "0", "1000", false, true);
        fixture.item.setQty(new BigDecimal("400"));
        fixture.item.setExecutionSegmentId(null);
        StockDocumentItem publicLine = new StockDocumentItem();
        publicLine.setId(UUID.randomUUID()); publicLine.setGoodsId(fixture.goods);
        publicLine.setUnitId(fixture.unit); publicLine.setUnitRate(BigDecimal.ONE);
        publicLine.setQty(new BigDecimal("600")); publicLine.setUpstreamItemId(fixture.planItem);
        publicLine.setExecutionSegmentId(UUID.randomUUID());

        ReflectionTestUtils.invokeMethod(fixture.service, "applyFinishedInChain",
                fixture.document, List.of(fixture.item, publicLine), 1);

        List<PreplanAnalysisPegPort.FinishedInboundSlice> lines = fixture.batchLines();
        assertThat(lines).extracting(PreplanAnalysisPegPort.FinishedInboundSlice::stockDocumentItemId)
                .containsExactly(fixture.item.getId(), publicLine.getId());
        assertThat(lines.getFirst().baseQty()).isEqualByComparingTo("400");
        assertThat(lines.getLast().baseQty()).isEqualByComparingTo("600");
        assertThat(lines).allSatisfy(line -> {
            assertThat(line.planItemId()).isEqualTo(fixture.planItem);
            assertThat(line.goodsId()).isEqualTo(fixture.goods);
        });
        verifyNoMoreInteractions(fixture.peg);
        verifyNoInteractions(fixture.reservations);
        assertThat(fixture.sql).noneMatch(sql -> sql.contains("UPDATE sales_order_items")
                || sql.contains("UPDATE plan_order_item_links"));
    }

    @Test void actualSurplusReversalDoesNotCreateAnOriginalAnalysisClaim() {
        Fixture fixture = new Fixture("1300", "1300", "1000", "1000", false, true);
        fixture.apply(-1);
        fixture.assertReverseReleasedOnly();
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
            // Exercise the real whole-document collector and real quantity allocator.
            // The peg port classifies claimed-public versus private ownership once
            // for all slices; its actual split is covered in PreplanMakeInboundSplitTest.
            ReflectionTestUtils.invokeMethod(service,"applyFinishedInChain",document,List.of(item),sign);
        }
        @SuppressWarnings({"unchecked", "rawtypes"})
        List<PreplanAnalysisPegPort.FinishedInboundSlice> batchLines() {
            org.mockito.ArgumentCaptor<List<PreplanAnalysisPegPort.FinishedInboundSlice>> captured =
                    org.mockito.ArgumentCaptor.forClass((Class) List.class);
            verify(peg).pegFinishedInbound(eq(document.getId()),eq(planId),eq(document.getWarehouseId()),captured.capture());
            return captured.getValue();
        }
        void assertForwardedSlice() {
            assertThat(batchLines()).containsExactly(new PreplanAnalysisPegPort.FinishedInboundSlice(
                    item.getId(),planItem,goods,item.getColorId(),item.getQty()));
            verifyNoMoreInteractions(peg);
        }
        void assertReverseReleasedOnly() {
            verify(reservations).releaseBySourceDoc("PRODUCTION_INBOUND",document.getId());
            verifyNoMoreInteractions(reservations);
            verifyNoInteractions(peg);
        }
    }
}
