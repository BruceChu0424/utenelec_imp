package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 出入库流水查询行（名称由前端按 id 解析）。 */
@Getter
@AllArgsConstructor
public class MovementRow {
    private UUID id;
    private OffsetDateTime transactionDate;
    private Short movementType;
    private String sourceDocType;
    private UUID sourceDocId;
    private UUID goodsId;
    private UUID colorId;
    private UUID warehouseId;
    private Short direction;
    private BigDecimal qty;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal weight;
    private BigDecimal amountLocal;
    private String remark;
    /** 当前用户无 goods:cost:view 时金额已由服务端置空。 */
    private boolean costMasked;
}
