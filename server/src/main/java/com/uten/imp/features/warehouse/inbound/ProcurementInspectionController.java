package com.uten.imp.features.warehouse.inbound;

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
import java.util.UUID;

/**
 * 采购/委外收货待检（IQC）API。
 *
 * <ul>
 *   <li>GET  /api/procurement/inspection?receiptType=&receiptId= → 该单的待检明细投影</li>
 *   <li>POST /api/procurement/inspection/{receiptType}/{receiptId}/{inspectionItemId}/dispose
 *       → PASS（合格放行：进可用库存 + 整单结案后唤醒生产）/ FAIL（不合格：只记事实）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/procurement/inspection")
@RequiredArgsConstructor
public class ProcurementInspectionController {

    private final ProcurementInspectionService service;

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
                            received.subtract(passed).subtract(failed), (String) row[9]);
                })
                .toList();
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
