package com.uten.imp.features.subcontract.inquiry.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外询价单详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class InquiryDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<InquiryItemDto> items;
}
