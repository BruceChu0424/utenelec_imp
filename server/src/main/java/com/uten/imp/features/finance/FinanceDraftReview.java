package com.uten.imp.features.finance;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;

import java.util.UUID;

/** A review command is bound to every stored input, line identity and document version. */
public final class FinanceDraftReview {
    private FinanceDraftReview() { }

    public enum Kind {
        RECEIPT("finance_receipts", "finance_receipt_lines", "receipt_id"),
        PAYMENT("finance_payments", "finance_payment_lines", "payment_id"),
        EXPENSE("finance_expenses", "finance_expense_items", "expense_id"),
        INCOME("finance_other_incomes", "finance_other_income_items", "income_id"),
        TRANSFER("finance_bank_transfers", "finance_bank_transfer_lines", "transfer_id");
        private final String header;
        private final String lines;
        private final String parent;
        Kind(String header, String lines, String parent) {
            this.header = header; this.lines = lines; this.parent = parent;
        }
    }

    public record View<T>(String snapshot, T detail) { }
    public record Save<T>(@NotBlank @Pattern(regexp = "[0-9a-f]{64}") String expectedSnapshot,
            @NotNull @Valid T document, boolean approveNow) { }

    public static String snapshot(EntityManager em, Kind kind, UUID id) {
        Object source = em.createNativeQuery("SELECT (to_jsonb(header) || jsonb_build_object('items', "
                + "COALESCE((SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id) FROM "
                + kind.lines + " line WHERE line." + kind.parent + "=header.id AND NOT line.is_deleted), '[]'::jsonb)))::text "
                + "FROM " + kind.header + " header WHERE header.id=:id AND NOT header.is_deleted")
                .setParameter("id", id).getSingleResult();
        return CanonicalFingerprint.sha256(java.util.List.of(kind.name(), id.toString(), String.valueOf(source)));
    }

    public static void requireCurrent(EntityManager em, Kind kind, UUID id, String expected) {
        if (expected == null || !expected.matches("[0-9a-f]{64}") || !snapshot(em, kind, id).equals(expected)) {
            throw new ApiException(ErrorCode.CONFLICT, "审核中的单据已被修改，请刷新核对后再保存审核修改");
        }
    }

    public static void requireReviewer(FinanceDocumentAccessPolicy access, SecurityContextCurrentUser user,
            UUID maker, String permission) {
        access.requireScopedOperationWritable(maker, "只能修改本人审核范围内的财务草稿", permission + ":approve");
        if (maker != null && maker.equals(user.requireEmployeeId())) {
            throw new ApiException(ErrorCode.BUSINESS, "制单人与审核人不可相同(职责分离)");
        }
    }
}
