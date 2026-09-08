package com.uten.imp.features.finance.bank_transfer.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 银行存取款单详情。 */
@Getter
@AllArgsConstructor
public class FinanceBankTransferDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID outAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private String invoiceNo;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinanceBankTransferLineDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;

    // Additive exact text never passes through a binary floating-point value.
    public String getExchangeRateExact() { return com.uten.imp.common.util.DecimalText.of(exchangeRate); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
}
