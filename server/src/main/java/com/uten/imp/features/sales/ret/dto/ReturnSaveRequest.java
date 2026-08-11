package com.uten.imp.features.sales.ret.dto;

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

/** 销售退货新建/编辑请求。 */
@Getter
@Setter
public class ReturnSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    @NotNull
    private UUID clientId;

    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private String remark;
    /** 退货原因（销售退货专属）。 */
    private String returnReason;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ReturnItemLine> items;
}
