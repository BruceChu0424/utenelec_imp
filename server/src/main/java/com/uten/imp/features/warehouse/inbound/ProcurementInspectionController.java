package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import com.uten.imp.features.warehouse.inbound.dto.ProcurementInspectionItemDto;
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

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 采购/委外收货待检（IQC）API。
 *
 * <ul>
 *   <li>GET  /api/procurement/inspection/pending-receipts → 全局待检单列表（质检工作台入口）</li>
 *   <li>GET  /api/procurement/inspection?receiptType=&receiptId= → 该单的待检明细投影
 *       （含货品/颜色/来源订货单号，供逐行 PASS/FAIL 处置）</li>
 *   <li>POST /api/procurement/inspection/{receiptType}/{receiptId}/{inspectionItemId}/dispose
 *       → PASS（品质放行：形成仓库待入库任务）/ FAIL（不合格：只记事实）；两者均不直接写库存</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/procurement/inspection")
@RequiredArgsConstructor
public class ProcurementInspectionController {

    private final ProcurementInspectionService service;

    @GetMapping("/pending-receipts")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public List<com.uten.imp.features.warehouse.inbound.dto.PendingInspectionReceiptView> pendingReceipts() {
        return service.pendingReceiptSummaries().stream()
                .map(com.uten.imp.features.warehouse.inbound.dto.PendingInspectionReceiptView::from)
                .toList();
    }

    @GetMapping("/pending-receipts/{receiptType}/{receiptId}")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public Object pendingReceipt(@PathVariable String receiptType,@PathVariable UUID receiptId) {
        String type=receiptType.toUpperCase(java.util.Locale.ROOT);
        if(!java.util.Set.of("PURCHASE","SUBCONTRACT").contains(type))throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"收货单类型无效");
        Object value=service.pendingPayloads("IQC",java.util.Set.of("iqc:"+type+":"+receiptId)).get("iqc:"+type+":"+receiptId);
        if(value==null)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"收货单当前没有待检明细");
        return value;
    }

    @GetMapping
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public List<ProcurementInspectionItemDto> list(
            @RequestParam String receiptType,
            @RequestParam UUID receiptId) {
        return service.pendingForReceipt(receiptType, receiptId).stream()
                .map(row -> {
                    BigDecimal received = dec(row[6]);
                    BigDecimal passed = dec(row[7]);
                    BigDecimal failed = dec(row[8]);
                    return new ProcurementInspectionItemDto(
                            (UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                            (UUID) row[4], dec(row[5]), received, passed, failed,
                            received.subtract(passed).subtract(failed), (String) row[9],
                            (String) row[10], (String) row[11], (String) row[12],
                            (UUID) row[13], (String) row[14], nullableDec(row[15]),
                            (UUID) row[16], (String) row[17], (String) row[18],
                            WarehouseQualityResultService.preStocked(
                                    row[19], row[20], row[21], row[22], row[23]), (String)row[24]);
                })
                .toList();
    }

    @GetMapping("/pending-count")
    @com.uten.imp.security.BusinessTaskRead
    @PreAuthorize("hasAuthority('procurement_inspection:view') and hasAuthority('procurement_inspection:handle')")
    public Map<String, Long> pendingCount() {
        return Map.of("count", service.pendingReceiptCount());
    }

    @PostMapping("/{receiptType}/{receiptId}/{inspectionItemId}/dispose")
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void dispose(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId,
            @PathVariable UUID inspectionItemId,
            @Valid @RequestBody InspectionDispositionRequest request) {
        service.dispose(receiptType, receiptId, inspectionItemId, request);
    }

    /**
     * 同一收货单内多条待检明细一次性合格放行。服务端校验完整集合后在单事务内执行，
     * 任何一条已变化都会令整批回滚，禁止客户端循环伪装批量成功。
     */
    @PostMapping("/{receiptType}/{receiptId}/pass-batch")
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void passBatch(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId,
            @Valid @RequestBody BatchInspectionPassRequest request) {
        service.passBatch(receiptType, receiptId, request);
    }

    /**
     * 批量检验报告（2026-09-05「提交报告」）：每行合格+不合格数量一次提交；
     * 含不合格数量时结论原因必填。整批同事务，任一冲突整批回滚。
     */
    @PostMapping("/{receiptType}/{receiptId}/decide-batch")
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public void decideBatch(
            @PathVariable String receiptType,
            @PathVariable UUID receiptId,
            @Valid @RequestBody BatchInspectionDecideRequest request) {
        service.decideBatch(receiptType, receiptId, request);
    }

    /**
     * 品质批量审批整份检验报告（2026-10-10）：多张采购/委外收货单一次请求原子执行
     * （服务端单事务，联合预锁 + 按报告顺序逐单），任一单冲突整批回滚并按单号报错；
     * 同一报告体响应丢失后重试静默重放，替代前端逐单循环发 decide-batch。
     */
    @PostMapping("/decide-report")
    @PreAuthorize("hasAuthority('procurement_inspection:view')"
            + " and hasAuthority('procurement_inspection:handle')")
    public com.uten.imp.features.warehouse.inbound.dto.BatchInspectionReportResponse decideReport(
            @Valid @RequestBody com.uten.imp.features.warehouse.inbound.dto.BatchInspectionReportRequest request) {
        return service.decideReport(request);
    }

    /** Read-only query with the exact original report body, never a second quality write. */
    @PostMapping("/{receiptType}/{receiptId}/decide-batch/receipt")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public com.uten.imp.features.warehouse.inbound.dto.InspectionCommandResolution decideBatchReceipt(
            @PathVariable String receiptType,@PathVariable UUID receiptId,@Valid @RequestBody BatchInspectionDecideRequest request){
        return service.decideBatchReceipt(receiptType,receiptId,request);
    }

    @PostMapping("/{receiptType}/{receiptId}/pass-batch/receipt")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public com.uten.imp.features.warehouse.inbound.dto.InspectionCommandResolution passBatchReceipt(
            @PathVariable String receiptType,@PathVariable UUID receiptId,@Valid @RequestBody BatchInspectionPassRequest request){
        return service.passBatchReceipt(receiptType,receiptId,request);
    }

    @GetMapping("/{receiptType}/{receiptId}/{inspectionItemId}/disposition-receipt")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public com.uten.imp.features.warehouse.inbound.dto.InspectionCommandResolution dispositionReceipt(
            @PathVariable String receiptType,@PathVariable UUID receiptId,@PathVariable UUID inspectionItemId,
            @RequestParam String idempotencyKey){
        return service.dispositionReceipt(receiptType,receiptId,inspectionItemId,idempotencyKey);
    }

    private static BigDecimal dec(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static BigDecimal nullableDec(Object value) {
        return value == null ? null : (BigDecimal) value;
    }
}
