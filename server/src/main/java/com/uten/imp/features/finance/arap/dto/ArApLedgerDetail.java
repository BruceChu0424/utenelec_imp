package com.uten.imp.features.finance.arap.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 应收应付台账详情（含到期日/结算方式等运行字段）。 */
@Getter
@AllArgsConstructor
public class ArApLedgerDetail {
    private UUID id;
    private String direction;
    private String sourceDocType;
    private UUID sourceDocId;
    private String sourceDocNo;
    private String billNo;
    private LocalDate billDate;
    private LocalDate dueDate;
    private UUID clientId;
    private UUID supplierId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountOriginalLocal;
    private BigDecimal amountSettled;
    private BigDecimal amountBalance;
    private boolean settled;
    private LocalDate settledDate;
    private UUID settlementTypeId;
    private Short status;
    private String legacySource;
    private Integer legacyId;
    private Short legacyBstyle;
    private String remark;

    // 名称/币种及到账、冲销、订单来源快照。
    private String clientName;
    private String supplierName;
    private String currencyCode;
    private String currencyName;
    private BigDecimal amountReceivedOriginal;
    private BigDecimal amountReceivedLocal;
    private BigDecimal amountWriteOffOriginal;
    private BigDecimal amountWriteOffLocal;
    private BigDecimal amountOffsetOriginal;
    private BigDecimal amountOffsetLocal;
    private BigDecimal amountBalanceOriginal;
    private Short settlementStyleLegacy;
    private List<String> salesOrderNos;
    private List<UUID> salesOrderIds;
    private UUID authoritativeSalesOrderId;

    // Additive exact text never passes through a binary floating-point value.
    public String getExchangeRateExact() { return com.uten.imp.common.util.DecimalText.of(exchangeRate); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountOriginalLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginalLocal); }
    public String getAmountSettledExact() { return com.uten.imp.common.util.DecimalText.of(amountSettled); }
    public String getAmountBalanceExact() { return com.uten.imp.common.util.DecimalText.of(amountBalance); }
    public String getAmountReceivedOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountReceivedOriginal); }
    public String getAmountReceivedLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountReceivedLocal); }
    public String getAmountWriteOffOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountWriteOffOriginal); }
    public String getAmountWriteOffLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountWriteOffLocal); }
    public String getAmountOffsetOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOffsetOriginal); }
    public String getAmountOffsetLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountOffsetLocal); }
    public String getAmountBalanceOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountBalanceOriginal); }
}
