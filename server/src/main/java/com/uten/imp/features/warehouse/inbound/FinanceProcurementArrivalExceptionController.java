package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalDecisionRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
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

/** 财务侧到货异常接口（/api/finance/procurement-arrival-exceptions）：任务列表/详情 + 财务定案决策。 */
@RestController
@RequestMapping("/api/finance/procurement-arrival-exceptions")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('finance_order_approval:view')")
public class FinanceProcurementArrivalExceptionController {

    private final ProcurementArrivalControlService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/tasks")
    public PageResponse<ArrivalExceptionTask> tasks(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.financeTasks(page, size);
    }

    @GetMapping("/count")
    public Map<String, Long> count() {
        return Map.of("count", service.countFinanceTasks());
    }

    @GetMapping("/{id}")
    public ArrivalExceptionTask detail(@PathVariable UUID id) {
        ArrivalExceptionTask result = service.financeDetail(id);
        String documentNo = result.receiptBillNo() == null
                || result.receiptBillNo().isBlank()
                ? result.orderBillNo()
                : result.receiptBillNo();
        detailViewAudit.record(
                "view_finance_procurement_arrival_exception_detail",
                "procurement_arrival_exceptions",
                id,
                documentNo,
                null,
                "采购到货异常财务审批");
        return result;
    }

    @PostMapping("/{id}/decision")
    @PreAuthorize("hasAuthority('finance_order_approval:view') and "
            + "hasAnyAuthority('finance_order_approval:approve','finance_order_approval:reject')")
    public ArrivalExceptionTask decide(
            @PathVariable UUID id,
            @Valid @RequestBody ArrivalDecisionRequest request) {
        return service.financeDecide(id, request);
    }
}
