package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Recoverable warehouse queue for production finished-in physical counts. */
@RestController
@RequestMapping("/api/warehouse/production-finished-in")
@RequiredArgsConstructor
public class ProductionFinishedInboundTaskController {

    private final ProductionFinishedInboundTaskService service;
    private final ProductionFinishedArrivalRegistrationService arrivalRegistrations;
    private final com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes;

    @GetMapping("/tasks")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public PageResponse<ProductionFinishedInboundTask> tasks(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) String taskStage,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "40") int size,
            @RequestParam(required = false) UUID scopeWarehouseId,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestParam(required = false) String taskNo,
            @RequestParam(required = false) String planNo) {
        // 仓库数据范围(ADR-149)：服务端按本人范围强制过滤；scopeWarehouseId = 在可选范围内挑一个仓(含下级)。
        // 2026-09-25 单号列统一：sort/order 表头排序 + 任务单号/生产计划号表头值筛选。
        return service.list(keyword, taskStage, warehouseId, page, size,
                warehouseScopes.current(scopeWarehouseId),
                sort, order, taskNo, planNo);
    }

    /** 产成品入库任务 facets（2026-09-25 单号列统一）：{taskNo/planNo:[各单号]}——
     *  同列表过滤口径（不含单号列自身值筛选）。 */
    @GetMapping("/tasks/facets")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, List<Map<String, Object>>> taskFacets(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(required = false) String taskStage,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return service.facets(keyword, taskStage, warehouseId,
                warehouseScopes.current(scopeWarehouseId));
    }

    /** 产成品待点收待办数(徽章来源 finishedInbound): 与列表同一仓库范围(ADR-149)。 */
    @GetMapping("/tasks/count")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public Map<String, Long> count(@RequestParam(required = false) UUID scopeWarehouseId) {
        return Map.of("count", service.countPending(warehouseScopes.current(scopeWarehouseId)));
    }

    // 产成品入库登记只有这一组端点(ADR-151 §5)：单张 = 1 个来源、多选 = N 个来源，
    // 按实物交接批(ADR-148)一行；原按单张报工的读取/登记端点已删除。
    @GetMapping("/arrival-registrations/batch")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public List<ArrivalRegistrationView> batchArrivalRegistrations(
            @RequestParam List<UUID> reportIds) {
        return arrivalRegistrations.batchDetail(reportIds);
    }

    @PostMapping("/arrival-registrations/batch")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public BatchArrivalRegistrationResult registerArrivalBatch(
            @Valid @RequestBody BatchArrivalRegistrationRequest request) {
        return arrivalRegistrations.batchRegister(request);
    }

    // 2026-09-27 库位记忆与建议统一：登记(单张/批量)同事务自动记忆库位，原「记住库位」
    // 两个端点、按报工取建议库位两个端点、上次所用成品仓端点一并删除；建议库位改走
    // POST /api/warehouse/place-suggestions(与采购/委外到货登记同一口径)，
    // 上次所用仓库由客户端本机记忆。

    /** V548 登记撤回（仅品质未处理）：与登记同权限 + 仓储对象范围；registrationId 是登记批次 UUID。 */
    @PostMapping("/arrival-registrations/{registrationId}/reverse")
    @PreAuthorize("hasAuthority('stock_doc:view')"
            + " and hasAuthority('stock_doc:approve')")
    public ArrivalRegistrationView reverseArrivalRegistration(
            @PathVariable UUID registrationId,
            @Valid @RequestBody ArrivalRegistrationReversalRequest request) {
        return arrivalRegistrations.reverse(registrationId, request);
    }
}
