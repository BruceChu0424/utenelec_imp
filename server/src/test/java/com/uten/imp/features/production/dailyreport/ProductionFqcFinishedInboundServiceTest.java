package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.ProductionFinishedInboundReleasePort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionFqcFinishedInboundServiceTest {

    @Test
    void exactPassCreatesOneWarehouseDraftWithUuidSources() {
        EntityManager em = mock(EntityManager.class);
        StockDocumentRepository documents =
                mock(StockDocumentRepository.class);
        StockDocumentItemRepository items =
                mock(StockDocumentItemRepository.class);
        DocNumberService numbers = mock(DocNumberService.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        ChainNoticeService notices = mock(ChainNoticeService.class);
        ProductionFqcFinishedInboundService service =
                new ProductionFqcFinishedInboundService(
                        em, documents, items, numbers,
                        currentUser, notices);

        UUID reportId = UUID.randomUUID();
        UUID reportItemId = UUID.randomUUID();
        UUID inspectionId = UUID.randomUUID();
        UUID decisionId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID workerId = UUID.randomUUID();
        UUID makerId = UUID.randomUUID();
        UUID planItemId = UUID.randomUUID();
        UUID segmentId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        UUID actorId = UUID.randomUUID();
        UUID documentId = UUID.randomUUID();
        UUID documentItemId = UUID.randomUUID();
        BigDecimal quantity = new BigDecimal("1000.0000");

        Query source = query();
        when(source.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        reportId, (short) 1, warehouseId,
                        "RB202608280001", workerId, makerId,
                        reportItemId, planItemId, segmentId,
                        allocationId, goodsId, null, unitId,
                        BigDecimal.ONE, planId, "SJ202608280001",
                        quantity, "IN_PROGRESS", inspectionId,
                        decisionId
                }));
        Query goods = query();
        when(goods.getResultList()).thenReturn(
                Collections.singletonList(new Object[]{
                        goodsId, "V51043",
                        "V5多功能三极插座E极插套(酸洗)"
                }));
        Query link = query();
        when(link.executeUpdate()).thenReturn(1);
        when(em.createNativeQuery(anyString()))
                .thenReturn(source, goods, link);
        when(numbers.nextNumber(any()))
                .thenReturn("CPRK202608280001");
        when(currentUser.requireId()).thenReturn(actorId);
        when(documents.saveAndFlush(any())).thenAnswer(invocation -> {
            StockDocument value = invocation.getArgument(0);
            value.setId(documentId);
            return value;
        });
        when(items.saveAndFlush(any())).thenAnswer(invocation -> {
            StockDocumentItem value = invocation.getArgument(0);
            value.setId(documentItemId);
            return value;
        });

        var result = service.createReleasedDraft(
                new ProductionFinishedInboundReleasePort.ReleaseRequest(
                        inspectionId, decisionId,
                        reportId, reportItemId, quantity));

        assertThat(result.stockDocumentId()).isEqualTo(documentId);
        assertThat(result.stockDocumentItemId())
                .isEqualTo(documentItemId);
        ArgumentCaptor<StockDocument> document =
                ArgumentCaptor.forClass(StockDocument.class);
        verify(documents).saveAndFlush(document.capture());
        assertThat(document.getValue().getSourceDailyReportId())
                .isEqualTo(reportId);
        assertThat(document.getValue().getMakerId())
                .isEqualTo(makerId);
        assertThat(document.getValue().getStatus()).isZero();

        ArgumentCaptor<StockDocumentItem> item =
                ArgumentCaptor.forClass(StockDocumentItem.class);
        verify(items).saveAndFlush(item.capture());
        assertThat(item.getValue().getSourceDailyReportItemId())
                .isEqualTo(reportItemId);
        assertThat(item.getValue().getExecutionSegmentId())
                .isEqualTo(segmentId);
        assertThat(item.getValue().getQty())
                .isEqualByComparingTo(quantity);
        assertThat(item.getValue().getReportedQty())
                .isEqualByComparingTo(quantity);
        verify(notices).notifyFinishedInboundPending(documentId);
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any()))
                .thenReturn(query);
        return query;
    }
}
