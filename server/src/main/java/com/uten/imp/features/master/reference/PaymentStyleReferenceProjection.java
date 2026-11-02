package com.uten.imp.features.master.reference;

import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleNode;
import java.util.List;

/** Document choices need the payment classification and account relation, never an opening balance. */
public final class PaymentStyleReferenceProjection {
    private PaymentStyleReferenceProjection() { }
    public static List<PaymentStyleNode> of(List<PaymentStyleNode> rows) {
        return rows.stream().map(source -> {
            var row = new PaymentStyleNode();
            row.setId(source.getId());
            row.setCode(source.getCode());
            row.setName(source.getName());
            row.setCategory(source.getCategory());
            row.setLevel(source.getLevel());
            row.setParentId(source.getParentId());
            row.setSortOrder(source.getSortOrder());
            row.setPath(source.getPath());
            row.setDepartmental(source.isDepartmental());
            row.setReceipt(source.isReceipt());
            row.setPayment(source.isPayment());
            row.setLinkedAccountLegacyId(source.getLinkedAccountLegacyId());
            row.setLinkedAccountId(source.getLinkedAccountId());
            row.setStatus(source.getStatus());
            row.setLegacyId(source.getLegacyId());
            row.setChildren(of(source.getChildren() == null ? List.of() : source.getChildren()));
            return row;
        }).toList();
    }
}
