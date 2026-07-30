package com.uten.imp.features.subcontract.inquiry.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外询价单新建/编辑请求（主表字段 + 明细行）。 */
@Getter
@Setter
public class InquirySaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private LocalDate deliverDate;
    private String remark;

    @Valid
    @NotNull
    private List<InquiryItemLine> items;
}
