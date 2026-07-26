package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售订货保存请求中的明细行。 */
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
    private BigDecimal discount;
    private BigDecimal taxAmount;
    private BigDecimal weight;
    private String clientNo;
    private String clientModel;
    private LocalDate deliverDate;
    private String sourceDocNo;
    private String remark;
}
