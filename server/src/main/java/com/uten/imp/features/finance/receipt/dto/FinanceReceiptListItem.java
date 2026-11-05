package com.uten.imp.features.finance.receipt.dto;

import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 销售收款单列表行。 */
@Getter
public class FinanceReceiptListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private String receiptKind;
    private UUID salesOrderId;
    private UUID clientId;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;


    /** Existing constructor retained; reference labels are additive read-only DTO fields. */
    public FinanceReceiptListItem(UUID id, String billNo, LocalDate billDate, String receiptKind, UUID salesOrderId, UUID clientId, UUID accountId, BigDecimal amountLocal, Short status, Integer legacyId) {
        this.id=id;
        this.billNo=billNo;
        this.billDate=billDate;
        this.receiptKind=receiptKind;
        this.salesOrderId=salesOrderId;
        this.clientId=clientId;
        this.accountId=accountId;
        this.amountLocal=amountLocal;
        this.status=status;
        this.legacyId=legacyId;
    }

    private String clientName;
    public FinanceReceiptListItem withClientName(String name) { this.clientName=name; return this; }

    // Additive exact text never passes through a binary floating-point value.
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    /** The source identity is immutable; ordinary save requests cannot set it. */
    @Override
    public boolean isLegacyImported() { return super.isLegacyImported(); }

    @Override public void disableHistoryActions() {
    }
}
