package com.uten.imp.features.notice;

import com.uten.imp.application.port.SalesManagerReviewNoticePort;
import com.uten.imp.application.port.SalesManagerReviewerEligibilityPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class SalesManagerReviewNoticeService implements SalesManagerReviewNoticePort {
    private final JdbcTemplate jdbc;
    private final NoticeService notices;
    private final SalesManagerReviewerEligibilityPort reviewers;
    private final ReviewNoticeAudience audience;

    private static String table(String kind) {
        return switch (kind) { case "quote" -> "sales_quotes"; case "order" -> "sales_orders";
            default -> throw new IllegalArgumentException("Unknown review kind"); };
    }
    @Override public void pending(String kind, UUID id) {
        publishPending(kind,id,reviewers.reviewers(kind),true);
    }
    @Override public void pendingForUser(String kind,UUID id,UUID userId) {
        publishPending(kind,id,java.util.List.of(userId),false);
    }
    private void publishPending(String kind,UUID id,java.util.List<UUID> recipients,boolean resubmission) {
        var rows = jdbc.queryForList("SELECT bill_no FROM " + table(kind)
                + " WHERE id=? AND NOT is_deleted AND manager_review_state='PENDING'", id);
        if (rows.isEmpty()) return;
        if(resubmission) resolved(kind,id,"RESUBMITTED");
        String billNo = rows.getFirst().get("bill_no").toString();
        String event="SALES_" + kind.toUpperCase(java.util.Locale.ROOT) + "_PENDING_MANAGER_REVIEW";
        for (UUID user : recipients) {
            if(!resubmission && Boolean.TRUE.equals(jdbc.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM notices WHERE audience_user_id=? AND aggregate_id=?
                        AND source_event=? AND resolved_at IS NULL)
                    """,Boolean.class,user,id,event))) continue;
            notices.publishForUser(user, "销售负责人待审核：" + billNo,
                    "请核对单据后批准或驳回；批准后转交财务审核。", "approval", "系统",
                    "/sales/manager-review/" + kind + "s/" + id,
                    event, "normal", id);
        }
    }
    @Override public void resolved(String kind, UUID id, String decision) {
        notices.resolveReviewNotices("SALES_" + kind.toUpperCase(java.util.Locale.ROOT) + "_MANAGER", id, decision);
        notices.resolveReviewNoticesByEvent("quote".equals(kind) ? "SALES_QUOTE_ACTION" : "SALES_ORDER", id,
                "SALES_" + kind.toUpperCase(java.util.Locale.ROOT) + "_MANAGER_REJECTED", decision);
    }
    @Override public void rejected(String kind, UUID id, String reason) {
        var rows = jdbc.queryForList("SELECT d.bill_no,u.id AS user_id FROM " + table(kind)
                + " d JOIN users u ON u.employee_id=" + ("quote".equals(kind) ? "d.maker_id" : "d.owner_employee_id")
                + " WHERE d.id=? AND NOT u.is_deleted AND u.status='active'", id);
        String event="SALES_" + kind.toUpperCase(java.util.Locale.ROOT) + "_MANAGER_REJECTED";
        for (var row : rows) notices.publishForUser((UUID) row.get("user_id"),
                "销售负责人已驳回：" + row.get("bill_no"), "驳回原因：" + reason + "。请修订后重新提交审核。",
                audience.eligibleEventFor((UUID)row.get("user_id"),event) ? "task" : "workflow", "系统", "/sales/" + kind + "s/" + id,
                event, "important", id);
    }
}
