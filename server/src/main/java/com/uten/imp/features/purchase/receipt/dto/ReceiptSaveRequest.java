package com.uten.imp.features.purchase.receipt.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 收货单新建/编辑请求（主表字段 + 明细行）。 */
@Getter
@Setter
public class ReceiptSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID senderId;
    private UUID receiverId;
    private String remark;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ReceiptItemLine> items;
}
