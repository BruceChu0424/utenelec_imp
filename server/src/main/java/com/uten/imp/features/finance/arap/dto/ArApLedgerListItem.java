package com.uten.imp.features.finance.arap.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 应收应付台账列表行（只读查询，@PreAuthorize ar_ap_ledger:view）。 */
@Getter
@AllArgsConstructor
public class ArApLedgerListItem {
    private UUID id;
    private String direction;          // AR / AP
    private String sourceDocType;      // SALES_SHIPMENT / PURCHASE_RECEIPT / ...
    private UUID sourceDocId;
    private String sourceDocNo;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;             // AR 时填
    private UUID supplierId;           // AP 时填
    private UUID currencyId;
    private BigDecimal amountOriginalLocal;
    private BigDecimal amountSettled;
    private BigDecimal amountBalance;
    private boolean settled;
    private LocalDate settledDate;
    private Short status;
    private Short legacyBstyle;
    private String remark;

    // V236：专业应收展示元数据；旧字段保留以兼容既有调用方。
    private String clientName;
    private String supplierName;
    private String currencyCode;
    private String currencyName;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountReceivedOriginal;
    private BigDecimal amountReceivedLocal;
    private BigDecimal amountWriteOffOriginal;
    private BigDecimal amountWriteOffLocal;
    private BigDecimal amountBalanceOriginal;
    private LocalDate dueDate;
    private Short settlementStyleLegacy;
    private List<String> salesOrderNos;
}
