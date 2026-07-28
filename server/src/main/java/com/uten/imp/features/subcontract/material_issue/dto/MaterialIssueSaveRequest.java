package com.uten.imp.features.subcontract.material_issue.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 委外材料出仓单新建/编辑请求。无币种、无 Price/Total（材料按成本发出）。
 */
@Getter
@Setter
public class MaterialIssueSaveRequest {

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID supplierId;

    @NotNull
    private UUID warehouseId;            // 发出仓必填（库存流水用）

    private UUID workerId;
    private LocalDate deliverDate;
    private String remark;

    private Integer operatorLegacyId;
    private String operatorName;
    private Integer makerLegacyId;
    private String makerName;
    private Integer approverLegacyId;
    private String approverName;

    @Valid
    @NotNull
    private List<MaterialIssueItemLine> items;
}
