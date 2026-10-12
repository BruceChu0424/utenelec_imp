package com.uten.imp.common.review;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;

import java.util.List;
import java.util.UUID;

/** Fixed domain registrations; authorization and lock order remain in the owning service. */
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

    public record View<T>(String snapshot, T detail) { }
    public record Save<T>(@NotBlank @Pattern(regexp = "[0-9a-f]{64}") String expectedSnapshot,
                          @NotNull @Valid T document, boolean approveNow) { }

    /** Covers stored header, every native input/line identity and existing extension cells. */
    public static String snapshot(EntityManager em, Kind kind, UUID id) {
        return CanonicalFingerprint.sha256(List.of(kind.name(), id.toString(), storedInputs(em, kind, id)));
    }

    /** Internal domain input projection; callers decide which fields a reviewer may amend. */
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

    public static void requireCurrent(EntityManager em, Kind kind, UUID id, String expected) {
        if (expected == null || !expected.matches("[0-9a-f]{64}") || !snapshot(em, kind, id).equals(expected))
            throw new ApiException(ErrorCode.CONFLICT, "审核中的单据已变化，请重新读取并核对后再保存");
    }

    public static void requireReviewer(DocumentAccessPolicy access, SecurityContextCurrentUser user,
                                       UUID maker, String permission) {
        user.requireId();
        access.requireScopedOperationWritable(maker, "只能修改本人审核范围内的草稿", permission + ":approve");
    }
}
