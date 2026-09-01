package com.uten.imp.features.warehouse.history;

import java.time.LocalDate;
import java.util.UUID;

/** Amount-free warehouse document history row. */
public record WarehouseHistoryListItem(
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
        long lineCount) {
}
