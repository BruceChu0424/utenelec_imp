package com.uten.imp.features.subcontract.waste.dto;

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

/** 委外损耗单新建/编辑请求。无币种、无 Price。 */
@Getter
@Setter
public class WasteSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;

    @NotNull
    private UUID warehouseId;

    private UUID workerId;
    private BigDecimal totalWeight;
    private String remark;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<WasteItemLine> items;
}
