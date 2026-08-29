package com.uten.imp.features.purchase.order.dto;

import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

@Getter
@AllArgsConstructor
public class OrderListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    private FinanceApproval financeApproval;
    /** 当前用户无采购商业金额权限时为 true，合计金额同时由服务端置 null。 */
    private boolean priceMasked;
}
