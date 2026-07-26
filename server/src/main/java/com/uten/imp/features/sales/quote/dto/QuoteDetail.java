package com.uten.imp.features.sales.quote.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售报价详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class QuoteDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate validUntil;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<QuoteItemDto> items;
}
