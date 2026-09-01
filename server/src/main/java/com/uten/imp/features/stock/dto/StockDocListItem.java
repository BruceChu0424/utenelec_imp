package com.uten.imp.features.stock.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
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
    /** 内部库存过账事实；仓库 API 永不序列化成本。 */
    @JsonIgnore
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    /** 领料车间/部门（DRAW 用；各车间领料统计筛选）。 */
    private UUID departmentId;
    /** 出库进度（仅 DRAW）：0未出库/1部分出库/2已出完；其他类型恒 null。 */
    private Short issueStatus;
    /** 当前用户无 goods:cost:view 时合计金额已由服务端置空。 */
    private boolean costMasked;
}
