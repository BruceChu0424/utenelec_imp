package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 报销单发票登记行（要素明细；详情接口返回）。 */
public record ExpenseClaimInvoiceDto(
        UUID id,
        int lineNo,
        String invoiceType,
        String invoiceCode,
        String invoiceNo,
        LocalDate issueDate,
        String sellerName,
        String sellerTaxNo,
        String buyerName,
        BigDecimal amountExclTax,
        BigDecimal taxAmount,
        BigDecimal totalAmount,
        String checkState,
        UUID attachmentId,
        String remark, String buyerTaxNo, String verificationRemark, java.time.Instant verifiedAt, String verifiedByName) {
}
