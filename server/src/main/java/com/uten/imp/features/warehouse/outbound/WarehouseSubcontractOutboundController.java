package com.uten.imp.features.warehouse.outbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.DrawWithdrawResult;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.ReturnToDrawRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 仓库委外出仓工作台 API(/api/warehouse/subcontract-outbound, ADR-143 §4.3)。
 *
 * <p>一行 = 一张委外人员在委外任务中心「领料」提交、仓库还没发出的领料草稿。拣货页只能把某行改少
 * (不超过提交的领料数量, 不能加行), 保存与审核出仓仍走既有 {@code /api/subcontract/material-issues}
 * 端点。仓库不再自建或补齐出仓单, 也不再「不再出仓」——结束领料由委外人员在任务详情办理;
 * 实物整张发不出时, 仓库用「退回领料」把这张草稿整张退回给委外人员(释放占用、作废草稿)。
 * 全链路不向仓库暴露价格/金额。
 */
@RestController
@RequestMapping("/api/warehouse/subcontract-outbound")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('subcontract_outbound:view')")
public class WarehouseSubcontractOutboundController {

    private final SubcontractMaterialPlanService planService;
    private final SubcontractDrawCommandService drawCommands;
    private final com.uten.imp.application.port.WarehouseTaskScopePort warehouseScopes;

    /** 待发料任务分页(出仓单号/订货单号/委外商关键字; 仓库范围 ADR-115)。 */
    @GetMapping("/tasks")
    public PageResponse<OutboundTaskListItem> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "") String warehouseScope,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        // 仓库范围(ADR-115)：MINE = 我负责的仓库；scopeWarehouseId = 指定仓库(含子仓)。
        return planService.tasks(page, size, keyword, warehouseScopes.resolve(warehouseScope, scopeWarehouseId));
    }

    /** 委外出库红数: 待仓库发出的领料草稿张数(与待发料列表同一仓库范围参数与口径)。 */
    @GetMapping("/tasks/count")
    public Map<String, Long> taskCount(
            @RequestParam(defaultValue = "") String warehouseScope,
            @RequestParam(required = false) UUID scopeWarehouseId) {
        return Map.of("count", planService.countTasks(warehouseScopes.resolve(warehouseScope, scopeWarehouseId)));
    }

    /** 拣货页: 草稿头 + 每行提交的领料数量/当前拣货量/该仓可拣量/库位。 */
    @GetMapping("/tasks/{issueId}")
    public OutboundTaskDetail taskDetail(@PathVariable UUID issueId) {
        return planService.taskDetail(issueId);
    }

    /**
     * 整张退回领料(本次不发): 实物发不出时由仓库把这张领料草稿退回委外人员, 释放占用并作废草稿,
     * 提交领料的人会收到通知(含原因)。仓库改过拣货数量也能退。权限同审核出仓: 委外出仓查看 + 执行。
     */
    @PostMapping("/tasks/{issueId}/return-to-draw")
    @PreAuthorize("hasAuthority('subcontract_outbound:view') and hasAuthority('subcontract_outbound:execute')")
    public DrawWithdrawResult returnToDraw(@PathVariable UUID issueId, @RequestBody ReturnToDrawRequest request) {
        return drawCommands.returnToDraw(issueId, request == null ? null : request.reason());
    }
}
