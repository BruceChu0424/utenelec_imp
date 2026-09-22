package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import com.uten.imp.application.port.SubcontractPreparationInventoryPort;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import com.uten.imp.features.production.analysis.SubcontractMakeTaskService;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.mockito.Mockito.*;

class ProductionCompletionBatchFollowupTest {
    @Test
    void everySourceKeepsItsExactHandoffsBeforeOneFinalAnalysisRefresh() {
        var readiness = mock(ProductionExecutionReadinessService.class);
        var analyses = mock(MaterialAnalysisSupplyWakeupService.class);
        var preparation = mock(SubcontractPreparationInventoryPort.class);
        var make = mock(SubcontractMakeTaskService.class);
        var orderPreparation = mock(SubcontractOrderPreparationPort.class);
        // V595：完工入库先问一句「是不是线边仓」(线边仓入库跳过分析唤醒与委外钩子)；本用例是普通仓。
        var em = mock(EntityManager.class);
        var lineSideProbe = mock(jakarta.persistence.Query.class);
        when(lineSideProbe.setParameter(anyString(), any())).thenReturn(lineSideProbe);
        when(lineSideProbe.getSingleResult()).thenReturn(false);
        when(em.createNativeQuery(anyString())).thenReturn(lineSideProbe);
        var service = new ProductionCompletionReverseService(em,
                mock(SecurityContextCurrentUser.class), readiness, analyses, preparation, make, orderPreparation);
        UUID first = UUID.randomUUID(), second = UUID.randomUUID(), warehouse = UUID.randomUUID();

        service.afterFinishedInboundPosted(first, warehouse);
        service.afterFinishedInboundPosted(second, warehouse);
        verifyNoInteractions(analyses);
        service.afterFinishedInboundBatchApproved(List.of(first, second));

        var order = inOrder(readiness, preparation, make, orderPreparation, analyses);
        for (UUID document : List.of(first, second)) {
            order.verify(readiness).onFinishedInboundApproved(document, warehouse);
            order.verify(preparation).afterFinishedInboundApproved(document, warehouse);
            order.verify(make).afterFinishedInboundApproved(document, warehouse);
            order.verify(orderPreparation).afterFinishedInboundApproved(document);
        }
        order.verify(analyses).afterFinishedInboundApproved(List.of(first, second));
        verifyNoMoreInteractions(readiness, preparation, make, orderPreparation, analyses);
    }

    /**
     * 线边仓入库(车间直送)：公共侧联动一个都不做，**包括就绪提升**。
     *
     * <p>直送服务在同一事务里已经按需求把料投给确定的接收工单，这里再按 peg 图找一遍并
     * tryPromote，每条直送行都要白跑一次可用量扫描——2026-09-22 审核提速把这条去掉。
     */
    @Test
    void lineSideInboundSkipsReadinessPromotionAsWellAsTheWakeups() {
        var readiness = mock(ProductionExecutionReadinessService.class);
        var analyses = mock(MaterialAnalysisSupplyWakeupService.class);
        var preparation = mock(SubcontractPreparationInventoryPort.class);
        var make = mock(SubcontractMakeTaskService.class);
        var orderPreparation = mock(SubcontractOrderPreparationPort.class);
        var em = mock(EntityManager.class);
        var lineSideProbe = mock(jakarta.persistence.Query.class);
        when(lineSideProbe.setParameter(anyString(), any())).thenReturn(lineSideProbe);
        when(lineSideProbe.getSingleResult()).thenReturn(true);
        when(em.createNativeQuery(anyString())).thenReturn(lineSideProbe);
        var service = new ProductionCompletionReverseService(em,
                mock(SecurityContextCurrentUser.class), readiness, analyses, preparation,
                make, orderPreparation);

        service.afterFinishedInboundApproved(UUID.randomUUID(), UUID.randomUUID());

        verifyNoInteractions(readiness, analyses, preparation, make, orderPreparation);
    }
}
