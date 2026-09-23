package com.uten.imp.features.purchase.request.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

@Getter @Setter
public class RequestItemLine implements ServerDerivedAmounts {
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal giftQty;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
}
