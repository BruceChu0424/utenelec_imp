package com.uten.imp.features.subcontract.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外订货单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class OrderItemLine {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    /**
     * 明细级委外商（可选）：覆盖表头供应商，用于「一张订货单录入多个委外商、保存按委外商自动拆单」。
     * 为空时使用 {@link OrderSaveRequest#getSupplierId()}。
     */
    private UUID supplierId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    /**
     * 申请明细真FK（申请分解行必填；审核订货时回写 ordered_qty）。
     * V304 起允许为空 = 委外自建手工行（无申请来源），提交财务时只对非空行做来源校验。
     */
    private UUID applicationItemId;

    private LocalDate deliverDate;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
