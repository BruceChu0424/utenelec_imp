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
    /** 行级仓库（V787，手工出入库单逐行选仓）；空 = 沿用表头仓。 */
    private UUID warehouseId;
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
    /** 累计车间申请量；本次可发=申请量-已发量，原始需求 qty 保持不变。 */
    private BigDecimal requestedQty;
    /** 数量是否按称重计数推算(ADR-135)。 */
    private boolean qtyFromWeight;
    /** 盘点实盘重量(千克, 仅 CHECK)。 */
    private BigDecimal countWeight;
    /** 盘点保存时的账面重量快照(千克, 仅 CHECK, 只用于显示; null = 当时未知)。 */
    private BigDecimal bookWeight;
    /**
     * 已出库重量(千克, 仅领料/退料行): 本行库存流水重量按方向累计, 恒为正数或 0
     * (领料 = 发出减取消出库, 退料 = 实收减红冲; 客户端原样显示, 不取绝对值);
     * 有任何一笔重量未知时为 null, 还没有流水时也为 null。
     */
    private BigDecimal issuedWeightKg;
    /** 已出库重量里含按库存均重或单重估算的部分(显示「≈」)。 */
    private boolean issuedWeightEstimated;
}
