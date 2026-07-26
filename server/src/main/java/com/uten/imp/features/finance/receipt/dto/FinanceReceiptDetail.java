package com.uten.imp.features.finance.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 销售收款单详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class FinanceReceiptDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal bankFee;
    private BigDecimal otherFee;
    private UUID otherFeeStyleId;
    private UUID receiptMethodId;
    private Integer receiptMethodLegacyId;
    private String invoiceNo;
    private OffsetDateTime cancelDate;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String sourceRemark;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinanceReceiptLineDto> items;
}
