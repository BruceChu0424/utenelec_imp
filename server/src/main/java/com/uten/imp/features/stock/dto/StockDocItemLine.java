package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 仓库单据保存请求中的明细行（create/update 嵌套）。
 *
 * <p>baseQty 由 Service 按 qty×unitRate 算（前端只传 qty/unitRate/unitId）。
 * surplusQty/countQty 仅盘点；upstreamItemId 仅退料等链路单据。
 */
@Getter
@Setter
public class StockDocItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    private BigDecimal weight;
    private BigDecimal giftQty;

    /** 盘点盘盈(+)盘亏(-)（仅 CHECK）。 */
    private BigDecimal surplusQty;
    /** 盘点实盘数（仅 CHECK）。 */
    private BigDecimal countQty;

    private String place;

    /** 链路：退料→领料明细 等。 */
    private UUID upstreamItemId;
    private UUID executionSegmentId;
    private UUID executionSegmentSalesAllocationId;

    private String sourceDocNo;
    private String remark;
}
