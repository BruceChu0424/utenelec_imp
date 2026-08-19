package com.uten.imp.features.purchase.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 收货单列表项。 */
@Getter
@AllArgsConstructor
public class ReceiptListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private Integer legacyId;
    /** 价格已对当前用户脱敏（合计金额置 null，前端渲染 ***；V302 收货单价格脱敏）。 */
    private boolean priceMasked;
}
