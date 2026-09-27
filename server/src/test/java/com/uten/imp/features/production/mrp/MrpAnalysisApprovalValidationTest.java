package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class MrpAnalysisApprovalValidationTest {
    @Test void inputValidationRetainsExactOpenPurchaseConditionsWithoutReadingStockBudgets() {
        EntityManager em=mock(EntityManager.class);Query graph=query(),inputs=query();
        when(graph.getSingleResult()).thenReturn(new Object[]{false,false});
        when(inputs.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);
            if(sql.contains("AS has_cycle"))return graph;
            assertThat(sql).contains("o.status=1", "o.is_deleted=false", "COALESCE(o.is_stopped,false)=false",
                    "o.is_closed=false", "oi.is_deleted=false", "oi.goods_id=e.goods_id",
                    "oi.color_id IS NOT DISTINCT FROM e.color_id", "COALESCE(oi.qty,0)-COALESCE(oi.received_qty,0)",
                    "COALESCE(oi.unit_rate,1)<=0 OR oi.unit_id IS NULL");
            assertThat(sql).doesNotContain("stock_balances","stock_reservations","demand_timeline");
            return inputs;
        });
        service(em).validatePlanBomGraph(UUID.randomUUID());
        verify(graph).getSingleResult();verify(inputs).getResultList();
    }

    @Test void malformedOpenPurchaseAndInvalidBomInputsStillFailClosed() {
        EntityManager em=mock(EntityManager.class);Query graph=query(),inputs=query();
        when(graph.getSingleResult()).thenReturn(new Object[]{false,false});
        when(em.createNativeQuery(anyString())).thenAnswer(call->((String)call.getArgument(0)).contains("AS has_cycle")?graph:inputs);
        when(inputs.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{"P-1","铜扣",false,true}));
        assertThatThrownBy(()->service(em).validatePlanBomGraph(UUID.randomUUID())).isInstanceOf(ApiException.class)
                .hasMessageContaining("未完成采购行的单位或换算率无效");
        when(inputs.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{"P-1","铜扣",true,false}));
        assertThatThrownBy(()->service(em).validatePlanBomGraph(UUID.randomUUID())).isInstanceOf(ApiException.class)
                .hasMessageContaining("BOM、颜色或基本单位数据无效");
    }

    private static Query query(){Query query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);return query;}
    private static MrpService service(EntityManager em){return new MrpService(em,null,null,null,null,null,null,null);}
}
