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

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;

    /** 申请明细真FK（可选；审核订货时回写 application_items.ordered_qty）。 */
    private UUID applicationItemId;

    private LocalDate deliverDate;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
