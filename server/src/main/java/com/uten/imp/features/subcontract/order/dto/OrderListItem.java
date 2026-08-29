package com.uten.imp.features.subcontract.order.dto;

import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 委外订货单列表项。 */
@Getter
@AllArgsConstructor
public class OrderListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID settlementMethodId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean fulfill;
    private Integer legacyId;
    private FinanceApproval financeApproval;
    /** 当前用户无委外商业金额权限时为 true，结算方式和合计金额同时置 null。 */
    private boolean priceMasked;
}
