package com.uten.imp.features.sales.shipment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import jakarta.persistence.*;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesShipmentOrderMoneySnapshotTest {
    @Test void releasedFinancialReviewReadsItsFrozenOrderFactsWithoutRecomputingCurrentMoney() {
        EntityManager em=mock(EntityManager.class);Query q=query();when(em.createNativeQuery(anyString())).thenReturn(q);
        UUID order=UUID.randomUUID(),shipmentId=UUID.randomUUID(),event=UUID.randomUUID();
        String snapshot="{\""+order+"\":{\"cashReceivedOriginal\":\"1000\",\"plannedRemainingOriginal\":\"500\",\"positionComplete\":true,\"warnings\":[]}}";
        when(q.getResultList()).thenReturn(List.of(snapshot));
        SalesShipment shipment=new SalesShipment();shipment.setId(shipmentId);shipment.setFinanceAudit((short)1);shipment.setFinanceReleaseEventId(event);
        var service=mock(SalesShipmentService.class,CALLS_REAL_METHODS);var current=mock(SalesOrderMoneyReadPort.class);
        ReflectionTestUtils.setField(service,"em",em);ReflectionTestUtils.setField(service,"orderMoney",current);
        Map<UUID,SalesOrderMoneyReadPort.Position> result=ReflectionTestUtils.invokeMethod(service,"orderMoneyPositions",shipment);
        assertThat(result.get(order).cashReceivedOriginal()).isEqualTo("1000");
        verifyNoInteractions(current);verify(q).setParameter("event",event);verify(q).setParameter("shipment",shipmentId);
        when(q.getResultList()).thenReturn(Collections.singletonList(null));
        Map<UUID,SalesOrderMoneyReadPort.Position> historical=ReflectionTestUtils.invokeMethod(service,"orderMoneyPositions",shipment);
        assertThat(historical).isEmpty();verifyNoInteractions(current);
    }
    @Test void ordinaryWarehousePaperAllowlistNeverReturnsTheEmbeddedFinancialPositionOrHashesItIntoPaper() throws Exception {
        UUID id=UUID.randomUUID();var shipments=mock(SalesShipmentService.class);var detail=mock(ShipmentDetail.class);
        when(shipments.detail(id)).thenReturn(detail);when(detail.getFinanceAudit()).thenReturn((short)1);when(detail.getStatus()).thenReturn((short)0);
        when(detail.getId()).thenReturn(id);when(detail.getBillNo()).thenReturn("XC-SAFE");when(detail.getBillDate()).thenReturn(LocalDate.of(2026,11,4));
        when(detail.getItems()).thenReturn(List.of());when(detail.isPriceMasked()).thenReturn(true);
        EntityManager em=mock(EntityManager.class);Query q=query();when(em.createNativeQuery(anyString())).thenReturn(q);
        String base="{\"lines\":{},\"settlementName\":\"现结\",\"makerName\":\"制单\",\"orderMoneyPositions\":{\"secret\":{\"cashReceivedOriginal\":\"%1$s\"}},\"frozenReceivablePosition\":{\"confirmedPaidOriginal\":\"%1$s\",\"balanceOriginal\":\"%1$s\"}}";
        when(q.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"Client","人民币",base.formatted("981239812398123"),"仓库"}));
        var branding=mock(CompanyBrandingReadPort.class);when(branding.currentIdentity()).thenReturn(new CompanyBrandingReadPort.Identity(1,"Company",List.of()));
        ObjectMapper json=new ObjectMapper();var service=new SalesShipmentPrintService(shipments,em,json,branding);
        var first=service.read(id);String paper=json.writeValueAsString(first);
        assertThat(paper).doesNotContain("orderMoneyPositions","cashReceivedOriginal","frozenReceivablePosition","confirmedPaidOriginal","balanceOriginal","981239812398123");
        assertThat(first.priceMasked()).isTrue();
        when(q.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"Client","人民币",base.formatted("1"),"仓库"}));
        assertThat(service.read(id).contentDigest()).isEqualTo(first.contentDigest());
    }
    private static Query query(){Query q=mock(Query.class);when(q.setParameter(anyString(),any())).thenReturn(q);return q;}
}
