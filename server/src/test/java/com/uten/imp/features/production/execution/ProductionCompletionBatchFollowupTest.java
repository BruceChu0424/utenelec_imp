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
        var service = new ProductionCompletionReverseService(mock(EntityManager.class),
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
}
