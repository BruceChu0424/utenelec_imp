package com.uten.imp.features.subcontract.inquiry.dto;

import com.uten.imp.common.finance.ServerDerivedAmounts;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/** 委外询价单保存请求中的明细行（create/update 嵌套）。 */
@Getter
@Setter
public class InquiryItemLine implements ServerDerivedAmounts {

    private Integer lineNo;

    @NotNull
    private UUID goodsId;

    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;

    @NotNull
    private BigDecimal qty;

    private BigDecimal price;
    private BigDecimal weight;

    private String sourceDocNo;
    private String remark;
}
