package com.uten.imp.features.subcontract.receipt.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外进仓单新建/编辑请求（主表字段 + 明细行）。 */
@Getter
@Setter
public class ReceiptSaveRequest {

    @NotBlank
    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID senderId;
    private LocalDate lastDate;
    private String remark;

    @Valid
    @NotNull
    private List<ReceiptItemLine> items;
}
