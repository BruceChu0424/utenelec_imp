package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售订货详情（主表全字段 + 明细列表 + BOM 展开只读列表）。 */
@Getter
@AllArgsConstructor
public class OrderDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private String contractNo;
    private String linkPhone;
    private String signAddr;
    private String shipAddr;
    private BigDecimal deposit;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private String sourceDocNo;
    private List<OrderItemDto> items;
    /** BOM 展开只读（design 20 §一·13，本期不做编辑）。 */
    private List<OrderCostItemDto> costItems;
}
