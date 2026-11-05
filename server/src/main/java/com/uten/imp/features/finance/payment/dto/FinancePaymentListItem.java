package com.uten.imp.features.finance.payment.dto;

import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 采购付款单列表行。 */
@Getter
public class FinancePaymentListItem extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID accountId;
    private BigDecimal amountLocal;
    private Short status;
    private Integer legacyId;


    /** Existing constructor retained; reference labels are additive read-only DTO fields. */
    public FinancePaymentListItem(UUID id, String billNo, LocalDate billDate, UUID supplierId, UUID accountId, BigDecimal amountLocal, Short status, Integer legacyId) {
        this.id=id;
        this.billNo=billNo;
        this.billDate=billDate;
        this.supplierId=supplierId;
        this.accountId=accountId;
        this.amountLocal=amountLocal;
        this.status=status;
        this.legacyId=legacyId;
    }

    private String supplierName;
    public FinancePaymentListItem withSupplierName(String name) { this.supplierName=name; return this; }

    // Additive exact text never passes through a binary floating-point value.
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
    /** The source identity is immutable; ordinary save requests cannot set it. */
    @Override
    public boolean isLegacyImported() { return super.isLegacyImported(); }

    @Override public void disableHistoryActions() {
    }
}
