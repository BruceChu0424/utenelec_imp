package com.uten.imp.features.purchase.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

@Getter @AllArgsConstructor
public class ReturnListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private Integer legacyId;
    /** 当前用户无采购商业金额权限时为 true，合计金额同时置 null。 */
    private boolean priceMasked;
}
