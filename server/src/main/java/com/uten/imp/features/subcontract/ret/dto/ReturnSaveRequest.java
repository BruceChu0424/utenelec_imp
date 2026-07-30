package com.uten.imp.features.subcontract.ret.dto;

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

/** 委外退货单新建/编辑请求（主表字段 + 明细行）。 */
@Getter
@Setter
public class ReturnSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;

    @NotNull
    private UUID warehouseId;

    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private LocalDate lastDate;
    private String remark;

    private Integer settlementStyleLegacy;
    private Integer makerLegacyId;
    private String makerName;
    private Integer approverLegacyId;
    private String approverName;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<ReturnItemLine> items;
}
