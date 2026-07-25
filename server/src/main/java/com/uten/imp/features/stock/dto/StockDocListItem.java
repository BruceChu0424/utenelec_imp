package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 仓库单据列表项（统一，跨 9 类 doc_type）。 */
@Getter
@AllArgsConstructor
public class StockDocListItem {
    private UUID id;
    private String docType;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID toWarehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
}
