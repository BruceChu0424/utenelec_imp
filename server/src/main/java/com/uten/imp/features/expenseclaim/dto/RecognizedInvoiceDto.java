package com.uten.imp.features.expenseclaim.dto;

import java.math.BigDecimal;
import java.time.LocalDate;

/**
 * 发票识别结果（预填建议）：全部字段可空——识别不确定就留空，由人工补全；
 * 前端低置信（空）字段高亮，人工确认后才登记入库。
 */
public record RecognizedInvoiceDto(
        String invoiceType,
        String invoiceCode,
        String invoiceNo,
        LocalDate issueDate,
        String sellerName,
        String sellerTaxNo,
        String buyerName,
        String buyerTaxNo,
        BigDecimal amountExclTax,
        BigDecimal taxAmount,
        BigDecimal totalAmount,
        /** 销售方全称到提取的明细品名摘要（第一行），供报销明细「说明」预填。 */
        String itemSummary) {
}
