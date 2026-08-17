package com.uten.imp.features.finance.procurement;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalTask;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

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
            @RequestParam(defaultValue = "") String orderType) {
        return service.tasks(page, size, orderType);
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
}
