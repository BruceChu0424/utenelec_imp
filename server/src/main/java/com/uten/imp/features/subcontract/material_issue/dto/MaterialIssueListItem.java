package com.uten.imp.features.subcontract.material_issue.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外材料出仓单列表项。 */
@Getter
@AllArgsConstructor
public class MaterialIssueListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    /** 当前用户无委外商业金额权限时为 true，合计金额同时置 null。 */
    private boolean priceMasked;
}
