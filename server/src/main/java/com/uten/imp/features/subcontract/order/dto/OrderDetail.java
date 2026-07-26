package com.uten.imp.features.subcontract.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外订货单详情（主表全字段 + 明细列表；BOM 成本子表只读走 /cost-items 端点）。 */
@Getter
@AllArgsConstructor
public class OrderDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID purchaserId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private boolean fulfill;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<OrderItemDto> items;
}
