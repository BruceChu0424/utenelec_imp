package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.valuation.ProductionInventoryValueService;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionMaterialUsageSourceScopeTest {
    @Test void sharedIssueProofDoesNotGrantAccessToAnotherWorkshop() {
        UUID plan=UUID.randomUUID(),target=UUID.randomUUID(),source=UUID.randomUUID(),foreign=UUID.randomUUID();
        EntityManager em=mock(EntityManager.class);
        Query query=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(new Object[]{target,"THIS-BATCH"},
                new Object[]{source,"ACTUAL-ISSUE"},new Object[]{foreign,"OTHER-WORKSHOP"}));
        var access=mock(ProductionMaterialTaskAccessPolicy.class);
        when(access.readable(plan,target)).thenReturn(new ProductionMaterialTaskAccessPolicy.ReadScope(false,List.of(target)));
        when(access.readable(plan,null)).thenReturn(new ProductionMaterialTaskAccessPolicy.ReadScope(false,List.of(target,source)));
        when(access.capabilities(plan,target)).thenReturn(new ProductionMaterialTaskAccessPolicy.Capabilities(true,false,false,false));
        when(access.capabilities(plan,source)).thenReturn(new ProductionMaterialTaskAccessPolicy.Capabilities(false,false,false,false));
        var service=new ProductionMaterialSettlementService(em,mock(TxSessionVars.class),access,mock(ProductionInventoryValueService.class));
        var result=service.materialUsageSources(plan,target);
        assertThat(result).hasSize(2);
        assertThat(result.getFirst().executionSegmentId()).isEqualTo(target);
        assertThat(result.getFirst().shared()).isFalse();
        assertThat(result.get(1).executionSegmentId()).isEqualTo(source);
        assertThat(result.get(1).shared()).isTrue();
        assertThat(result.get(1).canOpen()).isTrue();
        assertThat(result.get(1).canSettle()).isFalse();
        verify(access,never()).capabilities(plan,foreign);
        verify(query,never()).executeUpdate();
    }

    @Test void invisibleCurrentBatchCannotProbeItsPriorMaterialSource() {
        UUID plan=UUID.randomUUID(),target=UUID.randomUUID();
        EntityManager em=mock(EntityManager.class);
        var access=mock(ProductionMaterialTaskAccessPolicy.class);
        doThrow(new ApiException(ErrorCode.NOT_FOUND,"任务不存在")).when(access).readable(plan,target);
        var service=new ProductionMaterialSettlementService(em,mock(TxSessionVars.class),access,mock(ProductionInventoryValueService.class));
        assertThatThrownBy(()->service.materialUsageSources(plan,target)).isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }
}
