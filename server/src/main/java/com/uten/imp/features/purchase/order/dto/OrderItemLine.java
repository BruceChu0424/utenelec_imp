package com.uten.imp.features.purchase.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

@Getter
@Setter
public class OrderItemLine {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    /**
     * 明细级供应商（可选）：覆盖表头供应商，用于「一张订货单录入多个供应商、保存按供应商自动拆单」。
     * 为空时使用 {@link OrderSaveRequest#getSupplierId()}。
     */
    private UUID supplierId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal giftQty;
    /** 关联申请明细（新建/编辑必填；审核时回写 ordered_qty）。 */
    @NotNull private UUID requestItemId;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
