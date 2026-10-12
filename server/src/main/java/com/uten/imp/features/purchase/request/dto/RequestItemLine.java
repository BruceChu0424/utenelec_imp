package com.uten.imp.features.purchase.request.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

@Getter @Setter
public class RequestItemLine extends com.uten.imp.common.platformcolumns.PlatformColumnLineInput implements ServerDerivedAmounts {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull
    @jakarta.validation.constraints.DecimalMin("0.0001")
    @jakarta.validation.constraints.Digits(integer = 14, fraction = 4)
    private BigDecimal qty;
    private BigDecimal price;
    @jakarta.validation.constraints.DecimalMin("0")
    @jakarta.validation.constraints.Digits(integer=14,fraction=4)
    private BigDecimal giftQty;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
