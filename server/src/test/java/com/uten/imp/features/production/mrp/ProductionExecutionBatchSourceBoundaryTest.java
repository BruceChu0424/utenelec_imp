package com.uten.imp.features.production.mrp;

import com.uten.imp.application.port.PreplanAnalysisPegPort.PreviewPlanTransfer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class ProductionExecutionBatchSourceBoundaryTest {
    @Test void onlyActuallySelectedLegacyPoolSlicesBlockTheBatch() {
        assertThatCode(()->ProductionExecutionBatchService.requireTraceableBatchSources(List.of())).doesNotThrowAnyException();
        PreviewPlanTransfer qualified=new PreviewPlanTransfer(UUID.randomUUID(),UUID.randomUUID(),BigDecimal.TEN,true,true);
        assertThatCode(()->ProductionExecutionBatchService.requireTraceableBatchSources(List.of(qualified))).doesNotThrowAnyException();
        PreviewPlanTransfer legacy=new PreviewPlanTransfer(qualified.demandId(),UUID.randomUUID(),BigDecimal.ONE,false,false);
        assertThatThrownBy(()->ProductionExecutionBatchService.requireTraceableBatchSources(List.of(qualified,legacy)))
                .isInstanceOf(ApiException.class).hasMessageContaining("历史预留").hasMessageNotContaining("刷新");
    }

    @Test void sharedWarehouseKernelProtectsLaterSelectedSourceBeforeUsingPublicStock() {
        UUID first=new UUID(0,1),second=new UUID(0,2);
        var owned=new LinkedHashMap<UUID,ProductionMaterialAllocationFacade.OwnedSlice>();
        owned.put(first,new ProductionMaterialAllocationFacade.OwnedSlice(new BigDecimal("3"),BigDecimal.ZERO));
        owned.put(second,new ProductionMaterialAllocationFacade.OwnedSlice(new BigDecimal("4"),BigDecimal.ZERO));
        var result=ProductionMaterialAllocationFacade.allocateByQualifiedSourceOrder(BigDecimal.TEN,List.of(first,second),owned,
                (warehouse,limit,qualified,requiresProof,isOwned)->limit);
        assertThat(result.get(first)).isEqualByComparingTo("6");
        assertThat(result.get(second)).isEqualByComparingTo("4");
    }
}
