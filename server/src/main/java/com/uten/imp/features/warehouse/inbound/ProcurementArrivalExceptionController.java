package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ReturnCompletionRequest;
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

/** 到货异常处理方接口（/api/procurement/arrival-exceptions）：负责人侧任务列表/详情 + 退货完结。 */
@RestController
@RequestMapping("/api/procurement/arrival-exceptions")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('supplier_return_task:view')")
public class ProcurementArrivalExceptionController {

    private final ProcurementArrivalControlService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/tasks")
    public PageResponse<ArrivalExceptionTask> tasks(
            @RequestParam(required = false) String orderType,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.ownerTasks(orderType, page, size);
    }

    @GetMapping("/count")
    public Map<String, Long> count(
            @RequestParam(required = false) String orderType) {
        return Map.of("count", service.countOwnerTasks(orderType));
    }

    @GetMapping("/{id}")
    public ArrivalExceptionTask detail(@PathVariable UUID id) {
        ArrivalExceptionTask result = service.ownerDetail(id);
        String documentNo = result.receiptBillNo() == null
                || result.receiptBillNo().isBlank()
                ? result.orderBillNo()
                : result.receiptBillNo();
        detailViewAudit.record(
                "view_procurement_arrival_exception_detail",
                "procurement_arrival_exceptions",
                id,
                documentNo,
                null,
                "采购到货异常");
        return result;
    }

    @PostMapping("/return-tasks/{id}/complete")
    @PreAuthorize("hasAuthority('supplier_return_task:view') and hasAuthority('supplier_return_task:complete')")
    public ArrivalExceptionTask completeReturn(
            @PathVariable UUID id,
            @Valid @RequestBody ReturnCompletionRequest request) {
        return service.completeReturn(id, request);
    }
}
