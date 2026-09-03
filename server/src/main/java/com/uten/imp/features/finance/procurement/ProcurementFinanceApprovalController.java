package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalTask;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchApprovalRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchRejectionRequest;
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

import java.util.Map;
import java.util.UUID;

/** 采购/委外订货单财务审批任务接口（/api/finance/procurement-approvals）。 */
@RestController
@RequestMapping("/api/finance/procurement-approvals")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('finance_order_approval:view')")
public class ProcurementFinanceApprovalController {

    private final ProcurementFinanceApprovalService service;

    @GetMapping("/tasks")
    public PageResponse<ApprovalTask> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(defaultValue = "") String orderType,
            @RequestParam(defaultValue = "") String keyword) {
        return service.tasks(page, size, orderType, keyword);
    }

    @GetMapping("/count")
    public Map<String, Long> count() {
        return Map.of("count", service.countTasks());
    }

    /** 待审任务按订货类型计数（全部/采购/委外筛选卡的全量口径）。 */
    @GetMapping("/type-counts")
    public Map<String, Long> typeCounts() {
        return service.countTasksByType();
    }

    /**
     * 审核详情（财务专用视图，与采购/委外业务详情页分离）：
     * 任务身份 + 订单头 + 供应商应付快照 + 明细 + 审批历史；
     * allowedActions 仅 PENDING case 按当前审核员实时资格返回。
     */
    @GetMapping("/tasks/{caseId}/review")
    public ProcurementApprovalContracts.ApprovalReview review(
            @PathVariable UUID caseId) {
        return service.review(caseId);
    }

    /** 整批同事务通过；任一 case/version/快照失败则全部回滚。remark 选填留痕。 */
    @PostMapping("/tasks/batch-approve")
    @PreAuthorize("hasAuthority('finance_order_approval:view') and "
            + "hasAuthority('finance_order_approval:approve')")
    public BatchDecisionResponse approveBatch(
            @Valid @RequestBody BatchApprovalRequest request) {
        return service.approveBatch(request.items(), request.remark());
    }

    /** 整批使用同一退回原因；任一项失败则全部回滚。 */
    @PostMapping("/tasks/batch-reject")
    @PreAuthorize("hasAuthority('finance_order_approval:view') and "
            + "hasAuthority('finance_order_approval:reject')")
    public BatchDecisionResponse rejectBatch(
            @Valid @RequestBody BatchRejectionRequest request) {
        return service.rejectBatch(request.items(), request.reason());
    }
}
