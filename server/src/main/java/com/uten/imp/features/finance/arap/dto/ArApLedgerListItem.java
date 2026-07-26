package com.uten.imp.features.finance.arap.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
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
}
