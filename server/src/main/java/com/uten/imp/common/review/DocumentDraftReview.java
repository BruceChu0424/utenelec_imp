package com.uten.imp.common.review;

import jakarta.persistence.EntityManager;

import java.util.UUID;

/** Read-only stored inputs used by reversal fact fingerprints. */
public final class DocumentDraftReview {
    private DocumentDraftReview() { }

    public enum Kind {
        PURCHASE_RECEIPT("purchase_receipts", "purchase_receipt_items", "receipt_id", true),
        PURCHASE_RETURN("purchase_returns", "purchase_return_items", "return_id", true),
        SUBCONTRACT_RECEIPT("subcontract_receipts", "subcontract_receipt_items", "receipt_id", true),
        SUBCONTRACT_RETURN("subcontract_returns", "subcontract_return_items", "return_id", true),
        PLAN("production_plans", "production_plan_items", "plan_id", false, "production_planning_drafts"),
        DAILY_REPORT("production_daily_reports", "production_daily_report_items", "report_id", false,
                "production_daily_report_material_usages", "production_daily_report_workers"),
        STOCK("stock_documents", "stock_document_items", "doc_id", true);

        private final String header, lines, parent;
        private final boolean softDeletedLines;
        private final String[] additionalChildren;
        Kind(String header, String lines, String parent, boolean softDeletedLines, String... additionalChildren) {
            this.header = header; this.lines = lines; this.parent = parent;
            this.softDeletedLines = softDeletedLines;
            this.additionalChildren = additionalChildren;
        }
    }

    /** Covers stored header, every native input/line identity and extension cells without mutation. */
    public static String storedInputs(EntityManager em, Kind kind, UUID id) {
        String liveLines = "line." + kind.parent + "=header.id"
                + (kind.softDeletedLines ? " AND NOT line.is_deleted" : "");
        StringBuilder additional = new StringBuilder();
        for (String table : kind.additionalChildren) {
            additional.append(",'").append(table).append("',COALESCE((SELECT jsonb_agg(to_jsonb(extra) ORDER BY to_jsonb(extra)::text) FROM ")
                    .append(table).append(" extra WHERE extra.").append(kind.parent).append("=header.id),'[]'::jsonb)");
        }
        String sql = "SELECT jsonb_build_object('header',to_jsonb(header),'items',"
                + "COALESCE((SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id) FROM "
                + kind.lines + " line WHERE " + liveLines + "),'[]'::jsonb),'fields',"
                + "COALESCE((SELECT jsonb_agg(to_jsonb(fields) ORDER BY fields.scope,fields.record_id) "
                + "FROM platform_record_fields fields WHERE fields.record_id=header.id OR fields.record_id IN "
                + "(SELECT line.id FROM " + kind.lines + " line WHERE " + liveLines + ")), '[]'::jsonb)" + additional + ")::text "
                + "FROM " + kind.header + " header WHERE header.id=:id AND NOT header.is_deleted";
        Object source = em.createNativeQuery(sql).setParameter("id", id).getSingleResult();
        return String.valueOf(source);
    }

}
