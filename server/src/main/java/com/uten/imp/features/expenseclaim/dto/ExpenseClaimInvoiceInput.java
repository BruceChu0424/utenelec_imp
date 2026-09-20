package com.uten.imp.features.expenseclaim.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 发票登记/修改入参。号码/代码形状（8 位+10/12 位代码，或 20 位数电票无代码）、
 * 金额勾稽（不含税+税额=价税合计）由服务层校验，勾稽不符落 MISMATCH 状态供审批人复核。
 */
public record ExpenseClaimInvoiceInput(
        @Size(max = 20) String invoiceType,
        @Size(max = 20) String invoiceCode,
        @NotBlank @Size(max = 60) String invoiceNo,
        LocalDate issueDate,
        @Size(max = 200) String sellerName,
        @Size(max = 20) String sellerTaxNo,
        @Size(max = 200) String buyerName,
        @DecimalMin("0.00") @Digits(integer = 16, fraction = 2) BigDecimal amountExclTax,
        @DecimalMin("0.00") @Digits(integer = 16, fraction = 2) BigDecimal taxAmount,
        @NotNull @DecimalMin(value = "0.01") @Digits(integer = 16, fraction = 2)
        BigDecimal totalAmount,
        UUID attachmentId,
        @Size(max = 500) String remark, Long expectedVersion, @Size(max=20) String buyerTaxNo) {
    public ExpenseClaimInvoiceInput(String invoiceType, String invoiceCode, String invoiceNo, LocalDate issueDate,
        String sellerName, String sellerTaxNo, String buyerName, BigDecimal amountExclTax, BigDecimal taxAmount,
        BigDecimal totalAmount, UUID attachmentId, String remark) {
        this(invoiceType,invoiceCode,invoiceNo,issueDate,sellerName,sellerTaxNo,buyerName,amountExclTax,taxAmount,totalAmount,attachmentId,remark,null,null);
    }
}
