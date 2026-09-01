package com.uten.imp.features.warehouse.history;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Amount-free warehouse history detail. */
public record WarehouseHistoryDetail(
        UUID id,
        String type,
        String billNo,
        LocalDate billDate,
        UUID supplierId,
        String supplierName,
        UUID warehouseId,
        String warehouseName,
        Short status,
        boolean closed,
        String sourceDocumentNo,
        UUID makerId,
        String makerName,
        UUID approverId,
        String approverName,
        String remark,
        List<WarehouseHistoryLine> lines) {

    public WarehouseHistoryDetail {
        lines = lines == null ? List.of() : List.copyOf(lines);
    }
}
