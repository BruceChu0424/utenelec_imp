package com.uten.imp.features.notice;

import com.uten.imp.application.port.SalesQuoteFinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SalesQuoteNoticePort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 销售报价核价流程通知(ADR-134)。
 *
 * <ul>
 *   <li>提交核价 → 全部合格核价人(提交人本人除外), 落点财务核价页, 聚合 = 报价 id;</li>
 *   <li>退回 / 确认 / 财务撤销确认 → 报价负责人(制单人), 落点报价详情;</li>
 *   <li>撤回 / 退回 / 确认 → 按 (SALES_QUOTE, 报价 id) 撤回核价人的待办。</li>
 * </ul>
 *
 * <p><b>事务语义</b>: 与业务同事务(与 {@link HrNoticeService} 同口径), 本类无 @Transactional,
 * 在报价服务的写事务里执行; 通知写失败随业务一起回滚, 不做提交后旁路投递。
 * 文案只写单号、客户、原因与下一步, 不出现代号与金额。
 */
@Service
@RequiredArgsConstructor
public class SalesQuoteNoticeService implements SalesQuoteNoticePort {

    public static final String EVENT_PENDING_REVIEW = "SALES_QUOTE_PENDING_FINANCE_REVIEW";
    public static final String EVENT_RETURNED = "SALES_QUOTE_FINANCE_RETURNED";
    public static final String EVENT_CONFIRMED = "SALES_QUOTE_FINANCE_CONFIRMED";
    public static final String EVENT_FINANCE_REOPENED = "SALES_QUOTE_FINANCE_REOPENED";
    /** 办结撤回按此聚合类型定位(登记 ReviewNoticeCatalog 后生效)。 */
    public static final String AGGREGATE_SALES_QUOTE = "SALES_QUOTE";

    private static final String TYPE_APPROVAL = "approval";
    private static final String TYPE_TASK = "task";
    private static final String PUBLISHER = "系统";

    private final NoticeService noticeService;
    private final JdbcTemplate jdbc;
    private final SalesQuoteFinanceReviewerEligibilityPort reviewers;

    @Override
    public void notifySubmittedForReview(UUID quoteId) {
        QuoteRef quote = quote(quoteId);
        if (quote == null) return;
        UUID submitterUser = userOfEmployee(quote.submittedBy());
        boolean resubmission = quote.resubmission();
        for (UUID reviewer : reviewers.eligibleUserIds()) {
            if (reviewer.equals(submitterUser)) continue;
            noticeService.publishForUser(
                    reviewer,
                    (resubmission ? "报价重新提交, 待核价：" : "报价待核价：") + quote.billNo(),
                    quote.sellerLabel() + " 提交了客户 " + quote.clientName() + " 的报价单 " + quote.billNo()
                            + "(" + quote.lineCount() + " 行货品)"
                            + (resubmission ? ", 这是修改后重新提交的版本, 请对照修订记录核对价格、折扣、数量与删除行。" : "。")
                            + "请认领后核对报价明细, 确认或退回。",
                    TYPE_APPROVAL, PUBLISHER,
                    "/finance/quote-review/" + quoteId,
                    EVENT_PENDING_REVIEW, "normal", quoteId);
        }
    }

    @Override
    public void notifyReturned(UUID quoteId) {
        QuoteRef quote = quote(quoteId);
        if (quote == null) return;
        UUID owner = userOfEmployee(quote.makerId());
        if (owner == null) return;
        String reason = quote.returnReason() == null || quote.returnReason().isBlank()
                ? "未填写原因" : quote.returnReason().strip();
        noticeService.publishForUser(
                owner,
                "报价被财务退回：" + quote.billNo(),
                "客户 " + quote.clientName() + " 的报价单 " + quote.billNo() + " 被财务"
                        + (quote.returnedByName().isBlank() ? "" : " " + quote.returnedByName())
                        + " 退回。退回原因: " + reason + "。请修改后重新提交财务核价。",
                TYPE_TASK, PUBLISHER,
                "/sales/quotes/" + quoteId,
                EVENT_RETURNED, "important", null);
    }

    @Override
    public void notifyConfirmed(UUID quoteId) {
        QuoteRef quote = quote(quoteId);
        if (quote == null) return;
        UUID owner = userOfEmployee(quote.makerId());
        if (owner == null) return;
        noticeService.publishForUser(
                owner,
                "报价已核价, 待客户确认：" + quote.billNo(),
                "客户 " + quote.clientName() + " 的报价单 " + quote.billNo() + " 已由财务"
                        + (quote.confirmedByName().isBlank() ? "" : " " + quote.confirmedByName())
                        + " 核价确认。请与客户核对当前版本，在报价详情记录「客户已同意」后生成订货单；客户不同意时可重新议价或取消报价。",
                TYPE_TASK, PUBLISHER,
                "/sales/quotes/" + quoteId,
                EVENT_CONFIRMED, "normal", null);
    }

    @Override
    public void notifyFinanceReopened(UUID quoteId) {
        QuoteRef quote = quote(quoteId);
        if (quote == null) return;
        UUID owner = userOfEmployee(quote.makerId());
        if (owner == null) return;
        noticeService.publishForUser(
                owner,
                "财务正在重新核价：" + quote.billNo(),
                "客户 " + quote.clientName() + " 的报价单 " + quote.billNo()
                        + " 已被财务撤销确认, 正在重新核价; 核价完成前暂时不能转订货单。",
                TYPE_TASK, PUBLISHER,
                "/sales/quotes/" + quoteId,
                EVENT_FINANCE_REOPENED, "normal", null);
    }

    @Override
    public void resolveReviewNotices(UUID quoteId, String reason) {
        noticeService.resolveReviewNotices(AGGREGATE_SALES_QUOTE, quoteId, reason);
    }

    private QuoteRef quote(UUID quoteId) {
        List<Map<String, Object>> rows = jdbc.queryForList("""
                SELECT quote.bill_no, quote.maker_id, quote.submitted_by,
                       (SELECT COUNT(*) FROM sales_quote_revision_logs history
                        WHERE history.quote_id = quote.id AND history.action = 'SUBMIT') > 1 AS resubmission,
                       quote.finance_return_reason,
                       COALESCE(client.name, '') AS client_name,
                       COALESCE(seller.full_name, maker.full_name, '') AS seller_name,
                       COALESCE(returned_by.full_name, '') AS returned_by_name,
                       COALESCE(confirmed_by.full_name, '') AS confirmed_by_name,
                       (SELECT COUNT(*) FROM sales_quote_items item WHERE item.quote_id = quote.id) AS line_count
                FROM sales_quotes quote
                LEFT JOIN clients client ON client.id = quote.client_id
                LEFT JOIN employees seller ON seller.id = quote.seller_id
                LEFT JOIN employees maker ON maker.id = quote.maker_id
                LEFT JOIN employees returned_by ON returned_by.id = quote.finance_returned_by
                LEFT JOIN employees confirmed_by ON confirmed_by.id = quote.finance_confirmed_by
                WHERE quote.id = ? AND NOT quote.is_deleted
                """, quoteId);
        if (rows.isEmpty()) return null;
        Map<String, Object> row = rows.getFirst();
        return new QuoteRef(
                Objects.toString(row.get("bill_no"), ""),
                (UUID) row.get("maker_id"),
                (UUID) row.get("submitted_by"),
                Boolean.TRUE.equals(row.get("resubmission")),
                (String) row.get("finance_return_reason"),
                Objects.toString(row.get("client_name"), ""),
                Objects.toString(row.get("seller_name"), ""),
                Objects.toString(row.get("returned_by_name"), ""),
                Objects.toString(row.get("confirmed_by_name"), ""),
                row.get("line_count") instanceof Number number ? number.longValue() : 0L);
    }

    /** 员工 → 启用账号(停用/删除账号跳过)。 */
    private UUID userOfEmployee(UUID employeeId) {
        if (employeeId == null) return null;
        List<UUID> users = jdbc.queryForList("""
                SELECT id FROM users
                WHERE employee_id = ? AND is_deleted = FALSE AND status = 'active'
                ORDER BY id LIMIT 1
                """, UUID.class, employeeId);
        return users.isEmpty() ? null : users.getFirst();
    }

    private record QuoteRef(String billNo, UUID makerId, UUID submittedBy, boolean resubmission,
                            String returnReason, String clientName, String sellerName,
                            String returnedByName, String confirmedByName, long lineCount) {
        String sellerLabel() {
            return sellerName.isBlank() ? "业务员" : "业务员 " + sellerName;
        }
    }
}
