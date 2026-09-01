package com.uten.imp.features.stock.dto;

import com.fasterxml.jackson.annotation.JsonIgnore;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/** 仓库单据明细返回 DTO（统一）。 */
@Getter
@AllArgsConstructor
public class StockDocItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private String goodsCodeSnapshot;
    private String goodsNameSnapshot;
    private String goodsSnapshotSource;
    private OffsetDateTime goodsSnapshotLockedAt;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal reportedQty;
    private BigDecimal baseQty;
    /** 内部库存过账事实；仓库实物行响应不序列化单价或金额。 */
    @JsonIgnore
    private BigDecimal price;
    @JsonIgnore
    private BigDecimal amountOriginal;
    @JsonIgnore
    private BigDecimal amountLocal;
    private BigDecimal weight;
    private BigDecimal giftQty;
    private BigDecimal surplusQty;
    private BigDecimal countQty;
    private String place;
    private UUID upstreamItemId;
    private UUID executionSegmentId;
    private UUID executionSegmentSalesAllocationId;
    private UUID sourceDailyReportItemId;
    private String sourceDocNo;
    private String remark;
    private LocalDate billDate;
    /** 已出库量（仅 DRAW 领料行；qty−issuedQty=剩余可出）。 */
    private BigDecimal issuedQty;
    /** 当前用户无 goods:cost:view 时单价和金额已由服务端置空。 */
    private boolean costMasked;
}
