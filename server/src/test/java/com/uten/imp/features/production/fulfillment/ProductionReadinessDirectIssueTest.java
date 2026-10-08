package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.ObjectProvider;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionReadinessDirectIssueTest {
    @Test
    void anEarlyPromotionReturnStillIssuesExistingPendingDrawsAndDoesNotCacheAcrossCalls() {
        UUID segment=UUID.randomUUID(),demand=UUID.randomUUID(),warehouse=UUID.randomUUID(),workshop=UUID.randomUUID(),bin=UUID.randomUUID();
        var em=mock(EntityManager.class);var stock=mock(StockDocService.class);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(mock(AuthUser.class)));
        @SuppressWarnings("unchecked") var provider=(ObjectProvider<StockDocService>)mock(ObjectProvider.class);
        when(provider.getObject()).thenReturn(stock);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);var query=query();
            if(sql.contains("SELECT segment.workshop_department_id, package.warehouse_id"))
                when(query.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{workshop,warehouse}));
            else if(sql.contains("SELECT line_side.id"))when(query.getResultList()).thenReturn(List.of(bin));
            else when(query.getResultList()).thenReturn(List.of());
            when(query.getSingleResult()).thenReturn(!sql.contains("production_material_increment_requests"));
            return query;
        });
        var allowed=query();when(allowed.getResultList()).thenReturn(List.of(warehouse));
        when(em.createNativeQuery(anyString(),eq(UUID.class))).thenReturn(allowed);
        var service=new ProductionExecutionReadinessService(mock(PreplanAnalysisPegPort.class),em,
                mock(ProductionMaterialAllocationFacade.class),mock(ProductionFulfillmentLedgerService.class),
                mock(StockDocumentRepository.class),mock(StockDocumentItemRepository.class),provider,
                mock(DocNumberService.class),current,mock(ChainNoticeService.class));
        service.topUpDirectSupply(segment,demand,bin,BigDecimal.ONE,"first");
        service.topUpDirectSupply(segment,demand,bin,BigDecimal.ONE,"second");
        verify(stock,times(2)).issueWorkshopDirectTransferDraws(eq(segment),eq(bin),anyString());
    }

    private static Query query() {
        var query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);return query;
    }
}
