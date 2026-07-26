package com.uten.imp.features.subcontract.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外退货单详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class ReturnDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID makerId;
    private UUID approverId;
    private LocalDate lastDate;
    private boolean apPosted;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<ReturnItemDto> items;

    private Integer settlementStyleLegacy;
    private Integer makerLegacyId;
    private String makerName;
    private Integer approverLegacyId;
    private String approverName;
}
