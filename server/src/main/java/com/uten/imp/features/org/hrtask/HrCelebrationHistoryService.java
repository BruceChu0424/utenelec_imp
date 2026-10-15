package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Published facts, not current birthday/hire dates or reactions on the blessing wall. */
@Service
@RequiredArgsConstructor
public class HrCelebrationHistoryService {
    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;

    public record Publication(UUID id, UUID noticeId, UUID employeeId, String employeeName,
            String type, String eventLabel, Instant publishedAt, String publisher) {}

    private static final String RELATION = """
            FROM notices notice
            LEFT JOIN notice_celebration_subjects subject ON notice.id = subject.notice_id
            LEFT JOIN notice_user_states state ON state.notice_id = notice.id AND state.user_id = ?
            WHERE notice.type = ?
              AND notice.source_event IS NULL
              AND ((notice.audience_user_id IS NULL AND notice.audience_scope = 'all')
                OR notice.audience_user_id = ?
                OR (notice.audience_scope = 'selected' AND state.user_id IS NOT NULL))
              AND state.deleted_at IS NULL
            """;

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public PageResponse<Publication> list(String type, int requestedPage, int requestedSize) {
        if (!Set.of("birthday", "anniversary").contains(type)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "庆典类型不正确");
        }
        AuthUser actor = currentUser.get().filter(user -> !user.isVisitor())
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN));
        if (!allowed(actor, "employee:view") || !allowed(actor, "notice:read")
                || ("birthday".equals(type) && !allowed(actor, "employee:pii:view"))) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        int size = Math.max(1, Math.min(100, requestedSize));
        Long count = jdbc.queryForObject("SELECT COUNT(*) " + RELATION, Long.class,
                actor.getId(), type, actor.getId());
        long total = count == null ? 0 : count;
        int totalPages = (int) Math.min(Integer.MAX_VALUE, (total + size - 1) / size);
        int page = totalPages == 0 ? 1 : Math.min(Math.max(1, requestedPage), totalPages);
        List<Publication> items = jdbc.query("""
                SELECT COALESCE(subject.id, notice.id) AS id, notice.id AS notice_id,
                       COALESCE(subject.employee_id, notice.subject_employee_id) AS employee_id,
                       COALESCE(subject.employee_name, notice.subject_name, '主角未留存') AS employee_name,
                       notice.type, COALESCE(subject.event_label, notice.event_label, '') AS event_label,
                       notice.published_at, notice.publisher
                """ + RELATION + " ORDER BY notice.published_at DESC, notice.id DESC, subject.id DESC LIMIT ? OFFSET ?",
                (row, index) -> new Publication(row.getObject("id", UUID.class),
                        row.getObject("notice_id", UUID.class), row.getObject("employee_id", UUID.class),
                        row.getString("employee_name"), row.getString("type"), row.getString("event_label"),
                        row.getTimestamp("published_at").toInstant(), row.getString("publisher")),
                actor.getId(), type, actor.getId(), size, (long) (page - 1) * size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    private static boolean allowed(AuthUser actor, String permission) {
        return actor.isSuperAdmin() || actor.getPermissions().contains(permission);
    }
}
