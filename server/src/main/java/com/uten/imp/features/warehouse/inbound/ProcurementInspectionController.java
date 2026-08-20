package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
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
import java.time.LocalDate;
import java.time.OffsetDateTime;
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
 *       → PASS（合格放行：进可用库存 + 整单结案后唤醒生产）/ FAIL（不合格：只记事实）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/procurement/inspection")
@RequiredArgsConstructor
public class ProcurementInspectionController {

    private final ProcurementInspectionService service;

    /** 待检单聚合行（IQC 工作台）。 */
    public record PendingInspectionReceiptDto(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            String billNo,
            LocalDate billDate,
            @JsonSerialize(using = ToStringSerializer.class) UUID supplierId,
            String supplierName,
            @JsonSerialize(using = ToStringSerializer.class) UUID warehouseId,
            long itemCount,
            BigDecimal pendingBaseQty,
            OffsetDateTime firstReceivedAt,
            OffsetDateTime lastReceivedAt) {
    }

    @GetMapping("/pending-receipts")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
    public List<PendingInspectionReceiptDto> pendingReceipts() {
        return service.pendingReceiptSummaries().stream()
                .map(row -> new PendingInspectionReceiptDto(
                        (String) row[0],
                        (UUID) row[1],
                        (String) row[7],
                        toLocalDate(row[8]),
                        (UUID) row[9],
                        (String) row[10],
                        (UUID) row[6],
                        ((Number) row[2]).longValue(),
                        dec(row[3]),
                        toOffsetDateTime(row[4]),
                        toOffsetDateTime(row[5])))
                .toList();
    }

    /** 原生查询 DATE 列安全转 LocalDate（驱动可能返回 java.sql.Date 或 LocalDate）。 */
    private static LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    /**
     * 原生查询 TIMESTAMPTZ 列安全转 OffsetDateTime。驱动/Hibernate 版本不同，
     * 可能返回 OffsetDateTime、Instant、java.sql.Timestamp 或 java.util.Date，
     * 直接强转会在部分环境抛 ClassCastException（如待检单列表 row[4]/row[5] 返回 Instant）。
     */
    private static OffsetDateTime toOffsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime odt) return odt;
        if (value instanceof java.time.Instant instant) return instant.atOffset(java.time.ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp ts) return ts.toInstant().atOffset(java.time.ZoneOffset.UTC);
        if (value instanceof java.util.Date date) return date.toInstant().atOffset(java.time.ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
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
                            (UUID) row[13], (String) row[14]);
                })
                .toList();
    }

    @GetMapping("/pending-count")
    @PreAuthorize("hasAuthority('procurement_inspection:view')")
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

    private static BigDecimal dec(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }
}
