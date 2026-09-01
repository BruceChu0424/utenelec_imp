package com.uten.imp.features.warehouse.outbound;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
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
 * 仓库委外出仓工作台 API（/api/warehouse/subcontract-outbound）。
 *
 * <p>新流只出委外订货目标件：无活动子层级时直接待出仓；有子层级时先完成整批内部
 * 自制、FQC 与仓库实收，再释放目标件出仓。V304 存量
 * {@code LEGACY_BOM_COMPONENT} 行继续按冻结口径兼容。仓库任务与详情只投影
 * {@code LEGACY_READY}/{@code READY_OUTBOUND} 可执行行；草稿编辑/审核仍走既有
 * {@code /api/subcontract/material-issues} 端点。全链路不向仓库暴露价格/金额。
 */
@RestController
@RequestMapping("/api/warehouse/subcontract-outbound")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('subcontract_outbound:view')")
public class WarehouseSubcontractOutboundController {

    private final SubcontractMaterialPlanService planService;

    /** 待出仓任务分页（订货单号/委外商关键字）。 */
    @GetMapping("/tasks")
    public PageResponse<OutboundTaskListItem> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String keyword) {
        return planService.tasks(page, size, keyword);
    }

    /** 待出仓任务计数（hub 角标）。 */
    @GetMapping("/tasks/count")
    public Map<String, Long> taskCount() {
        return Map.of("count", planService.countTasks());
    }

    /** 计划详情：计划行（计划/已出仓/草稿占用/剩余 + 库位）+ 关联出仓单历史。 */
    @GetMapping("/tasks/{planId}")
    public OutboundTaskDetail taskDetail(@PathVariable UUID planId) {
        return planService.taskDetail(planId);
    }

    /** 补齐出仓草稿：有剩余量且无未审草稿时重建（红冲后补发等）。返回新草稿 id。 */
    @PostMapping("/tasks/{planId}/draft")
    @PreAuthorize("hasAuthority('subcontract_outbound:execute')")
    public Map<String, UUID> regenerateDraft(@PathVariable UUID planId) {
        return Map.of("draftId", planService.regenerateDraft(planId));
    }

    /** 不再出仓：关闭计划剩余量（委外商料够/订单变更），必填原因。 */
    @PostMapping("/tasks/{planId}/close")
    @PreAuthorize("hasAuthority('subcontract_outbound:close')")
    public void closePlan(@PathVariable UUID planId,
                          @RequestBody ClosePlanRequest req) {
        planService.closePlan(planId, req.reason());
    }

    public record ClosePlanRequest(
            @NotBlank @Size(max = 500) String reason) {
    }
}
