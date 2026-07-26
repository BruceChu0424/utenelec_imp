package com.uten.imp.features.subcontract.material_return.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外材料退货单新建/编辑请求。无币种、无 Price（材料按成本退回）。 */
@Getter
@Setter
public class MaterialReturnSaveRequest {

    @NotBlank
    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;

    @NotNull
    private UUID warehouseId;

    private UUID workerId;
    private Integer bStyle;
    private String remark;

    @Valid
    @NotNull
    private List<MaterialReturnItemLine> items;
}
