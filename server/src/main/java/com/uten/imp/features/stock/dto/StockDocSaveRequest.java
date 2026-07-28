package com.uten.imp.features.stock.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 仓库单据新建/编辑请求（主表字段 + 明细行）。
 *
 * <p>docType 决定哪些字段有意义：TRANSFER 用 toWarehouseId（双仓）；FINISHED_IN 用 supplierId；
 * FINISHED_OUT/DRAW 用 clientId；CHECK 明细用 surplusQty/countQty。Service 按 docType 校验。
 */
@Getter
@Setter
public class StockDocSaveRequest {

    @NotBlank
    private String docType;

    private String billNo;

    @NotNull
    private LocalDate billDate;

    private UUID warehouseId;
    private UUID toWarehouseId;
    private UUID supplierId;
    private UUID clientId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private String assTeam;
    private String planNo;
    private String remark;

    @Valid
    @NotNull
    private List<StockDocItemLine> items;
}
