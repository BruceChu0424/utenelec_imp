package com.uten.imp.features.master.warehouse;

import com.uten.imp.features.documents.DocumentDraftCountController;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchController;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundController;
import com.uten.imp.features.stock.StockDocController;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestController;
import com.uten.imp.features.stock.count.StockCountRequestController;
import com.uten.imp.features.stock.count.StockCountReviewBadgeController;
import com.uten.imp.features.stock.insight.WarehouseInsightController;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedInboundTaskController;
import com.uten.imp.features.warehouse.inbound.WarehouseInboundController;
import com.uten.imp.features.warehouse.inbound.WarehouseQualityResultController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBadgeController;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionController;
import com.uten.imp.features.warehouse.outbound.WarehouseSubcontractOutboundController;
import com.uten.imp.features.workbench.badge.WorkbenchBadgeController;
import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-149: 仓库任务的列表、facets 与各级计数端点统一只认可选的 {@code UUID scopeWarehouseId}
 * (服务端按本人范围强制、越界 403)；ADR-115 的 {@code warehouseScope=MINE} 参数全部删除。
 * 计数端点漏接范围会让徽章与列表各用一套口径, 这里按端点名钉住。
 */
class WarehouseTaskEndpointScopeContractTest {

    private static final Map<Class<?>, List<String>> SCOPED = Map.ofEntries(
            Map.entry(WarehouseInboundController.class, List.of(
                    "expectations", "expectationFacets", "expectationCount", "arrivalExceptions",
                    "arrivalExceptionFacets", "arrivalExceptionCount")),
            Map.entry(WarehouseQualityResultController.class, List.of("list", "facets", "statusCounts", "typeCounts")),
            Map.entry(ProductionFinishedInboundTaskController.class, List.of("tasks", "taskFacets", "count")),
            Map.entry(WarehouseSalesOutboundController.class, List.of("list", "pendingCount", "facets", "counts")),
            Map.entry(WarehouseSubcontractOutboundController.class, List.of("tasks", "taskCount")),
            Map.entry(FulfillmentWorkbenchController.class, List.of(
                    "warehouse", "warehouseCount", "warehouseStatusBreakdown")),
            Map.entry(StockDocController.class, List.of("list", "facets")),
            Map.entry(ProductionMaterialReturnRequestController.class, List.of("count")),
            Map.entry(WorkshopMaterialRequisitionController.class, List.of("list")),
            Map.entry(WorkshopMaterialBadgeController.class, List.of("badgeCounts")),
            Map.entry(StockCountRequestController.class, List.of("list", "counts")),
            Map.entry(StockCountReviewBadgeController.class, List.of("warehouse")),
            Map.entry(WarehouseInsightController.class, List.of("health", "cycleCount")),
            Map.entry(DocumentDraftCountController.class, List.of("statusCounts")),
            Map.entry(WorkbenchBadgeController.class, List.of("badges")));

    @Test
    void everyWarehouseTaskEndpointTakesTheOptionalSelectedWarehouseOnly() {
        for (var entry : SCOPED.entrySet()) {
            for (String name : entry.getValue()) {
                List<Method> endpoints = Arrays.stream(entry.getKey().getDeclaredMethods())
                        .filter(method -> method.getName().equals(name) && method.isAnnotationPresent(GetMapping.class))
                        .toList();
                assertThat(endpoints).as(entry.getKey().getSimpleName() + "." + name).hasSize(1);
                Parameter scope = Arrays.stream(endpoints.getFirst().getParameters())
                        .filter(parameter -> "scopeWarehouseId".equals(requestParamName(parameter)))
                        .findFirst().orElse(null);
                assertThat(scope).as(entry.getKey().getSimpleName() + "." + name + " scopeWarehouseId").isNotNull();
                assertThat(scope.getType()).isEqualTo(UUID.class);
                assertThat(scope.getAnnotation(RequestParam.class).required()).isFalse();
            }
        }
    }

    @Test
    void theOptInMineParameterIsGoneFromEveryWarehouseEndpoint() {
        for (Class<?> controller : SCOPED.keySet()) {
            for (Method method : controller.getDeclaredMethods()) {
                for (Parameter parameter : method.getParameters()) {
                    assertThat(requestParamName(parameter))
                            .as(controller.getSimpleName() + "." + method.getName())
                            .isNotEqualTo("warehouseScope");
                }
            }
        }
    }

    private static String requestParamName(Parameter parameter) {
        RequestParam param = parameter.getAnnotation(RequestParam.class);
        if (param == null) return null;
        if (!param.name().isEmpty()) return param.name();
        if (!param.value().isEmpty()) return param.value();
        return parameter.getName();
    }
}
