package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
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
 *
 * <p>重量(ADR-135)一律是千克、最多 4 位小数, 填 0 视为没称; 按重量计的货品(或行单位本身是重量单位)
 * 服务端丢弃客户端重量, 由库存账按数量精确换算。
 */
@Getter
@Setter
public class StockDocItemLine extends com.uten.imp.common.platformcolumns.PlatformColumnLineInput {

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

    /** 本行实称重量(千克, 整行, 不乘换算率); 盘点单不用本列(见 countWeight)。 */
    @DecimalMin("0")
    @Digits(integer = 14, fraction = 4)
    private BigDecimal weight;

    /** 数量是否按称重计数推算(按称重改数量); 为真时本行不进单重学习。 */
    private Boolean qtyFromWeight;

    private BigDecimal giftQty;

    /** 盘点盘盈(+)盘亏(-)（仅 CHECK）。 */
    private BigDecimal surplusQty;
    /** 盘点实盘数（仅 CHECK）。 */
    private BigDecimal countQty;
    /** 盘点实盘重量(千克, 仅 CHECK, 可空); 审核时把本维度库存重量定为此值(盘点定重)。 */
    @DecimalMin("0")
    @Digits(integer = 14, fraction = 4)
    private BigDecimal countWeight;

    private String place;

    /** 链路：退料→领料明细 等。 */
    private UUID upstreamItemId;
    private UUID executionSegmentId;
    private UUID executionSegmentSalesAllocationId;

    private String sourceDocNo;
    private String remark;
}
