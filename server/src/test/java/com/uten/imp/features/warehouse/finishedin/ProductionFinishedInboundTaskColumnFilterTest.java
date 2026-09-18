package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 产成品入库任务表头筛选（2026-09-16）：taskStage（ARRIVAL_REGISTRATION/FINAL_COUNT
 * 白名单）+ warehouseId（最终点收入库单的成品仓）全部走命名参数绑定；非法步骤 fail-closed。
 */
class ProductionFinishedInboundTaskColumnFilterTest {

    private final EntityManager em = mock(EntityManager.class);
    private final ProductionStockTaskAccessPolicy access =
            mock(ProductionStockTaskAccessPolicy.class);
    private final ProductionFinishedInboundTaskService service =
            new ProductionFinishedInboundTaskService(em, access);

    @Test
    void taskStageAndWarehouseBindAsNamedParameters() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        lenient().when(access.canAccessWarehouseTasks()).thenReturn(true);

        UUID warehouseId = UUID.randomUUID();
        service.list("", "final_count ", warehouseId, 1, 40);

        // ①两个筛选列都进 WHERE（计数 + 列表两次查询同口径），列名硬编码不拼接输入。
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, org.mockito.Mockito.atLeast(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(statement -> assertThat(statement)
                .contains("task_stage = :task_stage")
                .contains("warehouse_id = :warehouse_id"));
        // ②值经绑定参数回传：步骤归一大写。
        verify(query, org.mockito.Mockito.atLeast(2)).setParameter("task_stage", "FINAL_COUNT");
        verify(query, org.mockito.Mockito.atLeast(2)).setParameter("warehouse_id", warehouseId);
    }

    @Test
    void unknownTaskStageFailsClosed() {
        lenient().when(access.canAccessWarehouseTasks()).thenReturn(true);
        assertThatThrownBy(() -> service.list("", "SHIPPED", null, 1, 40))
                .isInstanceOf(ApiException.class);
    }
}
