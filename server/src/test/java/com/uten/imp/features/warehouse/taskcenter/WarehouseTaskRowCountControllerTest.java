package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskRowCountPort;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchController;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundController;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestController;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskController;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBadgeController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPositionQueryService;
import com.uten.imp.features.warehouse.outbound.WarehouseSubcontractOutboundController;
import com.uten.imp.security.BusinessTaskRead;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class WarehouseTaskRowCountControllerTest {
    @Test void warehouseBadgeEndpointsForwardScopedPhysicalFactsWithoutDocumentDeduplication() {
        UUID warehouse=UUID.randomUUID();
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var scopes=mock(WarehouseTaskScopePort.class);
        org.mockito.Mockito.doCallRealMethod().when(scopes).currentForRead(org.mockito.ArgumentMatchers.any());
        when(scopes.current(warehouse)).thenReturn(scope);
        var rows=mock(WarehouseTaskRowCountPort.class);
        when(rows.inboundExpectations(scope)).thenReturn(Map.of("PURCHASE",2L,"SUBCONTRACT",3L));
        when(rows.finishedInbound(scope)).thenReturn(2L);
        when(rows.subcontractOutbound(scope)).thenReturn(2L);
        when(rows.productionReturn(scope)).thenReturn(2L);
        when(rows.salesOutbound(scope)).thenReturn(Map.of("PENDING_PICK",2L,"LEGACY_PENDING",3L));
        when(rows.productionDraw(scope)).thenReturn(Map.of("OPEN_ANY",5L,"READY_TO_PICK",2L,"PARTIAL",1L,"MATERIALS_TO_DEFINE",2L));

        assertThat(new WarehouseInboundController(null,null,null,null,null,scopes,rows).expectationCount(warehouse))
                .containsEntry("count",5L).containsEntry("PURCHASE",2L).containsEntry("SUBCONTRACT",3L);
        assertThat(new ProductionFinishedInboundTaskController(null,null,scopes,rows).count(warehouse)).containsEntry("count",2L);
        assertThat(new WarehouseSubcontractOutboundController(null,null,scopes,rows).taskCount(warehouse)).containsEntry("count",2L);
        assertThat(new ProductionMaterialReturnRequestController(null,scopes,rows).count(warehouse)).containsEntry("count",2L);
        var sales=new WarehouseSalesOutboundController(null,null,scopes,rows);
        assertThat(sales.pendingCount(warehouse)).containsEntry("count",2L);
        assertThat(sales.counts(warehouse)).containsEntry("PENDING_PICK",2L).containsEntry("LEGACY_PENDING",3L);
        var draw=new FulfillmentWorkbenchController(null,scopes,rows);
        assertThat(draw.warehouseCount(warehouse)).containsEntry("count",5L).containsEntry("pending",5L)
                .containsEntry("READY_TO_PICK",2L).containsEntry("PARTIAL",1L).containsEntry("MATERIALS_TO_DEFINE",2L);
        assertThat(draw.warehouseStatusBreakdown(warehouse)).containsEntry("OPEN_ANY",5L);
    }

    /**
     * 2026-11-08「委外出库下明明有一条待发料, 一级『出库』却没有数量徽章」: 列表(浏览范围 currentForRead)
     * 看得到的行, 计数却按职责范围(current)算成 0。仓库任务中心每个计数端点都必须读它所标注的列表的浏览范围——
     * 这里让两种范围故意不同(持「全部仓库只读」的账号就是如此), 只有浏览范围才有数。
     */
    @Test void everyWarehouseTaskCountReadsTheBrowsingRangeOfTheListItLabels() {
        UUID selected=UUID.randomUUID();
        var browse=new WarehouseTaskScope(true,List.of(selected,UUID.randomUUID()),false);
        var responsibility=new WarehouseTaskScope(true,List.of(selected),false);
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.currentForRead(selected)).thenReturn(browse);
        when(scopes.current(selected)).thenReturn(responsibility);
        var rows=mock(WarehouseTaskRowCountPort.class);
        when(rows.inboundExpectations(browse)).thenReturn(Map.of("PURCHASE",1L,"SUBCONTRACT",1L));
        when(rows.finishedInbound(browse)).thenReturn(1L);
        when(rows.subcontractOutbound(browse)).thenReturn(1L);
        when(rows.productionReturn(browse)).thenReturn(1L);
        when(rows.salesOutbound(browse)).thenReturn(Map.of("PENDING_PICK",1L));
        when(rows.productionDraw(browse)).thenReturn(Map.of("OPEN_ANY",1L));
        var arrivals=mock(ProcurementArrivalControlService.class);
        when(arrivals.countWarehouseExceptionsByType(browse)).thenReturn(Map.of("PURCHASE",1L,"SUBCONTRACT",0L));
        var quality=mock(WarehouseQualityResultService.class);
        var typeCounts=new WarehouseQualityResultService.TypeCounts(
                Map.of("PURCHASE",1L,"SUBCONTRACT",0L),Map.of("PURCHASE",0L,"SUBCONTRACT",0L));
        when(quality.typeCounts(browse)).thenReturn(typeCounts);
        var positions=mock(WorkshopMaterialPositionQueryService.class);
        var workshop=new WorkshopMaterialDtos.BadgeCounts(1,1,0);
        when(positions.badgeCounts(browse)).thenReturn(workshop);

        assertThat(new WarehouseSubcontractOutboundController(null,null,scopes,rows).taskCount(selected))
                .as("委外出库待发料").containsEntry("count",1L);
        var inbound=new WarehouseInboundController(arrivals,null,null,null,null,scopes,rows);
        assertThat(inbound.expectationCount(selected)).as("预计到货").containsEntry("count",2L);
        assertThat(inbound.arrivalExceptionCount(selected)).as("到货异常").containsEntry("count",1L);
        assertThat(new ProductionFinishedInboundTaskController(null,null,scopes,rows).count(selected))
                .as("产成品待点收").containsEntry("count",1L);
        assertThat(new ProductionMaterialReturnRequestController(null,scopes,rows).count(selected))
                .as("车间退料待实收").containsEntry("count",1L);
        var sales=new WarehouseSalesOutboundController(null,null,scopes,rows);
        assertThat(sales.pendingCount(selected)).as("销售待出库").containsEntry("count",1L);
        assertThat(sales.counts(selected)).as("销售出库分组").containsEntry("PENDING_PICK",1L);
        var draw=new FulfillmentWorkbenchController(null,scopes,rows);
        assertThat(draw.warehouseCount(selected)).as("生产待领").containsEntry("count",1L);
        assertThat(draw.warehouseStatusBreakdown(selected)).as("生产领料分状态").containsEntry("OPEN_ANY",1L);
        assertThat(new WarehouseQualityResultController(quality,scopes).typeCounts(selected))
                .as("品质检查结果大类").isSameAs(typeCounts);
        assertThat(new WorkshopMaterialBadgeController(positions,scopes).badgeCounts(selected))
                .as("内料仓待发/待收").isSameAs(workshop);
        verify(scopes,never()).current(any());
    }

    /**
     * 计数是展示层数字(ADR-184 修订二): 与列表、工作台徽章汇总同按会话主体浏览, 不挂 @BusinessTaskRead
     * 任务改写(改写会剥超管目录镜像并把浏览范围收回职责范围)。只读查看恒 0 的语义仍由原方法权限守住——
     * 这里逐个钉住动作码门槛没有被一起摘掉。
     */
    @Test void warehouseTaskCountsBrowseUnderTheSessionPrincipalAndKeepTheirActionGates() throws Exception {
        String inbound="hasAuthority('warehouse_inbound:view') and hasAuthority('warehouse_inbound:stock_in')";
        String stock="hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve')";
        String sales="hasAuthority('warehouse_sales_outbound:view') and hasAuthority('warehouse_sales_outbound:execute')";
        Map<Method,String> gates=new LinkedHashMap<>();
        gates.put(WarehouseSubcontractOutboundController.class.getMethod("taskCount",UUID.class),
                "hasAuthority('subcontract_outbound:view') and hasAuthority('subcontract_outbound:execute')");
        gates.put(WarehouseInboundController.class.getMethod("expectationCount",UUID.class),inbound);
        gates.put(WarehouseInboundController.class.getMethod("arrivalExceptionCount",UUID.class),inbound);
        gates.put(ProductionFinishedInboundTaskController.class.getMethod("count",UUID.class),stock);
        gates.put(ProductionMaterialReturnRequestController.class.getMethod("count",UUID.class),stock);
        gates.put(WarehouseSalesOutboundController.class.getMethod("pendingCount",UUID.class),sales);
        gates.put(WarehouseSalesOutboundController.class.getMethod("counts",UUID.class),sales);
        gates.put(FulfillmentWorkbenchController.class.getMethod("warehouseCount",UUID.class),"hasAuthority('stock_doc:view')");
        gates.put(FulfillmentWorkbenchController.class.getMethod("warehouseStatusBreakdown",UUID.class),"hasAuthority('stock_doc:view')");
        gates.put(WorkshopMaterialBadgeController.class.getMethod("badgeCounts",UUID.class),"hasAuthority('workshop_material:view')");
        // 品质结果: 类级查看门槛 + 桶内入库/退回动作资格(服务内按会话权限判定)。
        gates.put(WarehouseQualityResultController.class.getMethod("typeCounts",UUID.class),null);
        for (var gate:gates.entrySet()) {
            Method method=gate.getKey();
            String name=method.getDeclaringClass().getSimpleName()+"."+method.getName();
            assertThat(method.isAnnotationPresent(BusinessTaskRead.class)).as(name+" 不挂任务改写").isFalse();
            PreAuthorize gateAnnotation=method.getAnnotation(PreAuthorize.class);
            if (gate.getValue()==null) assertThat(gateAnnotation).as(name).isNull();
            else assertThat(gateAnnotation).as(name+" 动作门槛").isNotNull()
                    .extracting(PreAuthorize::value).isEqualTo(gate.getValue());
        }
        assertThat(WarehouseQualityResultService.class
                .getMethod("taskStatusCounts",String.class,String.class,UUID.class)
                .isAnnotationPresent(BusinessTaskRead.class)).as("品质结果分段 TASK_* 桶与大类同口径").isFalse();
    }
}
