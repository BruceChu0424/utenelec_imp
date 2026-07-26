package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 仓库单据详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class StockDocDetail {
    private UUID id;
    private Integer legacyId;
    private String docType;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID toWarehouseId;
    private UUID supplierId;
    private UUID clientId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private String assTeam;
    private String planNo;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<StockDocItemDto> items;
}
