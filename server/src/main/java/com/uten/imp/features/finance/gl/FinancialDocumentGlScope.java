package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.FinanceLegacyRecordGuard;
import jakarta.persistence.EntityManager;

import java.util.List;
import java.util.UUID;

/** Scope only this writer's managed projections; never filter accounting reports or period closing. */
final class FinancialDocumentGlScope {
    private record Source(String table, List<String> types) {}

    private static final List<Source> SOURCES = List.of(
            new Source("finance_receipts", List.of("RECEIPT", "RECEIPT_REV")),
            new Source("finance_payments", List.of("PAYMENT", "PAYMENT_REV")),
            new Source("finance_expenses", List.of("EXPENSE")),
            new Source("finance_other_incomes", List.of("INCOME")),
            new Source("finance_bank_transfers", List.of("BANK_TRANSFER")));

    private FinancialDocumentGlScope() {}

    static void requireMutable(EntityManager em, String sourceType, UUID documentId) {
        for (Source source : SOURCES) {
            if (!source.types().contains(sourceType)) continue;
            List<?> rows = em.createNativeQuery("SELECT legacy_id FROM " + source.table() + " WHERE id=:id")
                    .setParameter("id", documentId).getResultList();
            // The ordinary posting path owns missing/deleted/state validation.
            // legacy_id itself is immutable and is not inferred from target AR/AP.
            if (!rows.isEmpty()) {
                Object legacyId = rows.getFirst();
                FinanceLegacyRecordGuard.requireMutable(legacyId == null ? null : ((Number) legacyId).intValue());
            }
            return;
        }
    }

    static String managedVoucherPredicate(String alias) {
        if (!alias.matches("[a-z_][a-z0-9_]*")) throw new IllegalArgumentException("Invalid internal voucher alias");
        StringBuilder sql = new StringBuilder("(CASE ");
        for (Source source : SOURCES) {
            String types = String.join(",", source.types().stream().map(type -> "'" + type + "'").toList());
            sql.append("WHEN ").append(alias).append(".source_type IN (").append(types).append(") THEN EXISTS(")
                    .append("SELECT 1 FROM ").append(source.table()).append(" cash_source WHERE cash_source.id=")
                    .append(alias).append(".source_doc_id AND cash_source.legacy_id IS NULL) ");
        }
        // V266 deliberately retained unprovable old AUTO rows. Missing identity
        // is not authority to delete them, even when no legacy head can be joined.
        return sql.append("ELSE TRUE END)").toString();
    }
}
