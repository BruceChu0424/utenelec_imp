package com.uten.imp.features.production.fulfillment;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService;
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
import java.util.Set;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionReadinessDirectIssueTest {
    @Test
    void otherInboundWithoutAReceiptWarehouseOrCandidateNeverAcquiresAnEmptyPrefix() {
        var em=mock(EntityManager.class);var allocation=mock(ProductionMaterialAllocationFacade.class);
        var footprints=mock(ProductionPlanMutationFootprintService.class);
        var service=callbackService(em,allocation,footprints);
        service.onOtherInboundApproved(null,UUID.randomUUID());
        service.onOtherInboundApproved(UUID.randomUUID(),null);
        verifyNoInteractions(em,allocation,footprints);
        var empty=query();when(empty.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        service.onOtherInboundApproved(UUID.randomUUID(),UUID.randomUUID());
        verifyNoInteractions(allocation,footprints);
    }

    @Test
    void otherInboundPrelocksAllDistinctCandidatePlansOnceBeforeTheFirstMaterialLock() {
        UUID plan=UUID.randomUUID(),siblingPlan=UUID.randomUUID(),warehouse=UUID.randomUUID();
        List<Object[]> candidates=List.of(new Object[]{UUID.randomUUID(),warehouse,plan},
                new Object[]{UUID.randomUUID(),warehouse,plan},
                new Object[]{UUID.randomUUID(),warehouse,siblingPlan});
        var em=mock(EntityManager.class);var allocation=mock(ProductionMaterialAllocationFacade.class);
        var footprints=mock(ProductionPlanMutationFootprintService.class);
        var guard=mock(FulfillmentMutationLocks.Guard.class);
        when(footprints.beginPlans(anyCollection())).thenReturn(guard);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            var query=query();
            when(query.getResultList()).thenReturn(call.<String>getArgument(0)
                    .contains("SELECT DISTINCT segment.id, package.warehouse_id, segment.plan_id")?candidates:List.of());
            when(query.getSingleResult()).thenReturn(false);
            return query;
        });
        callbackService(em,allocation,footprints).onOtherInboundApproved(UUID.randomUUID(),warehouse);
        var ordered=inOrder(footprints,guard,allocation);
        ordered.verify(footprints).beginPlans(argThat(ids->ids.size()==2 && Set.copyOf(ids).equals(Set.of(plan,siblingPlan))));
        ordered.verify(guard).verifyUnchanged();
        ordered.verify(allocation,times(3)).lockMaterialDimensions(anyCollection());
        verifyNoMoreInteractions(footprints,guard,allocation);
    }

    private static ProductionExecutionReadinessService callbackService(EntityManager em,
            ProductionMaterialAllocationFacade allocation,ProductionPlanMutationFootprintService footprints) {
        @SuppressWarnings("unchecked") var provider=(ObjectProvider<StockDocService>)mock(ObjectProvider.class);
        return new ProductionExecutionReadinessService(mock(PreplanAnalysisPegPort.class),em,
                allocation,mock(ProductionFulfillmentLedgerService.class),mock(StockDocumentRepository.class),
                mock(StockDocumentItemRepository.class),provider,mock(DocNumberService.class),
                mock(SecurityContextCurrentUser.class),mock(ChainNoticeService.class),footprints);
    }

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
                mock(DocNumberService.class),current,mock(ChainNoticeService.class),
                mock(ProductionPlanMutationFootprintService.class));
        service.topUpDirectSupply(segment, demand, bin, BigDecimal.ONE);
        service.topUpDirectSupply(segment, demand, bin, BigDecimal.ONE);
        verify(stock,times(2)).issueWorkshopDirectTransferDraws(eq(segment),eq(bin),anyString());
    }

    private static Query query() {
        var query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);return query;
    }
}
