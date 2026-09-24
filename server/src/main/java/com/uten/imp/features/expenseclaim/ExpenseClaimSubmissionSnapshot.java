package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import java.math.BigDecimal;
import java.util.List;

/** Only commercial submission facts belong in a revision; reviewer checks are workflow state. */
final class ExpenseClaimSubmissionSnapshot {
    private ExpenseClaimSubmissionSnapshot() {}

    static String capture(ExpenseClaim claim, List<ExpenseClaimItem> items, List<ExpenseClaimInvoice> invoices) {
        var snapshot = JsonNodeFactory.instance.objectNode();
        snapshot.put("schemaVersion", 1);
        snapshot.put("title", claim.getTitle());
        snapshot.put("remark", claim.getRemark());
        snapshot.put("totalAmount", text(claim.getTotalAmount()));
        var itemRows = snapshot.putArray("items");
        for (var item : items) {
            var row = itemRows.addObject();
            row.put("id", text(item.getId()));
            row.put("lineNo", item.getLineNo());
            row.put("category", item.getCategory());
            row.put("amount", text(item.getAmount()));
            row.put("date", text(item.getExpenseDate()));
            row.put("description", item.getDescription());
        }
        var invoiceRows = snapshot.putArray("invoices");
        for (var invoice : invoices) {
            var row = invoiceRows.addObject();
            row.put("id", text(invoice.getId()));
            row.put("lineNo", invoice.getLineNo());
            row.put("invoiceType", invoice.getInvoiceType());
            row.put("invoiceCode", invoice.getInvoiceCode());
            row.put("invoiceNo", invoice.getInvoiceNo());
            row.put("issueDate", text(invoice.getIssueDate()));
            row.put("sellerName", invoice.getSellerName());
            row.put("sellerTaxNo", invoice.getSellerTaxNo());
            row.put("buyerName", invoice.getBuyerName());
            row.put("buyerTaxNo", invoice.getBuyerTaxNo());
            row.put("amountExclTax", text(invoice.getAmountExclTax()));
            row.put("taxAmount", text(invoice.getTaxAmount()));
            row.put("totalAmount", text(invoice.getTotalAmount()));
            row.put("attachmentId", text(invoice.getAttachmentId()));
            row.put("remark", invoice.getRemark());
        }
        return snapshot.toString();
    }

    private static String text(Object value) {
        return value == null ? null : value instanceof BigDecimal amount ? amount.toPlainString() : value.toString();
    }
}
