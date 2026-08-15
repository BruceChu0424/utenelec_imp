package com.uten.imp.features.purchase.ret.dto;

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

@Getter @Setter
public class ReturnSaveRequest {
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID receiverId;
    private UUID settlementMethodId;
    private Integer settlementStyleLegacy;
    private String remark;
    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ReturnItemLine> items;
}
