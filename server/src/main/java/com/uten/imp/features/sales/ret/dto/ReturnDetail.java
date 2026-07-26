package com.uten.imp.features.sales.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 销售退货详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class ReturnDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private UUID makerId;
    private UUID approverId;
    private OffsetDateTime lastDate;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private boolean arPosted;
    private List<ReturnItemDto> items;
}
