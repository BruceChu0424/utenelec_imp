package com.uten.imp.features.expenseclaim;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Only commercial submission facts belong in a revision; reviewer checks are workflow state. */
final class ExpenseClaimSubmissionSnapshot {
    private static final com.fasterxml.jackson.databind.ObjectMapper JSON=new com.fasterxml.jackson.databind.ObjectMapper();
    private ExpenseClaimSubmissionSnapshot() {}

    static String capture(ExpenseClaim claim, List<ExpenseClaimItem> items, List<ExpenseClaimInvoice> invoices) {
        return capture(claim,items,invoices,null);
    }

    static String capture(ExpenseClaim claim,List<ExpenseClaimItem> items,List<ExpenseClaimInvoice> invoices,
            Map<UUID,com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row> platformFields) {
        return capture(claim,items,invoices,platformFields,null);
    }

    static String capture(ExpenseClaim claim,List<ExpenseClaimItem> items,List<ExpenseClaimInvoice> invoices,
            Map<UUID,com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row> platformFields,
            com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row headerFields) {
        var snapshot = JsonNodeFactory.instance.objectNode();
        snapshot.put("schemaVersion", platformFields==null?1:2);
        snapshot.put("title", claim.getTitle());
        snapshot.put("remark", claim.getRemark());
        snapshot.put("totalAmount", text(claim.getTotalAmount()));
        if(headerFields!=null)snapshot.set("platformFields",JSON.valueToTree(headerFields));
        var itemRows = snapshot.putArray("items");
        for (var item : items) {
            var row = itemRows.addObject();
            row.put("id", text(item.getId()));
            row.put("lineNo", item.getLineNo());
            row.put("category", item.getCategory());
            row.put("amount", text(item.getAmount()));
            row.put("date", text(item.getExpenseDate()));
            row.put("description", item.getDescription());
            if(platformFields!=null) {
                var fields=platformFields.get(item.getId());
                if(fields==null)throw new IllegalStateException("Missing expense platform-field snapshot");
                row.set("platformFields",JSON.valueToTree(fields));
            }
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
