package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface NoticeAcknowledgmentRepository
        extends JpaRepository<NoticeAcknowledgment, NoticeAcknowledgmentId> {

    long countByIdNoticeId(UUID noticeId);

    boolean existsByIdNoticeIdAndIdUserId(UUID noticeId, UUID userId);

    /** 列表页角标用：前 5 名最近回执人（带姓名，避免逐行 N+1）。 */
    List<NoticeAcknowledgment> findTop5ByIdNoticeIdOrderByAckedAtDesc(UUID noticeId);

    /** 详情页「全部回执人」用：前 N 名（控制器层限制 limit）。 */
    List<NoticeAcknowledgment> findTop50ByIdNoticeIdOrderByAckedAtDesc(UUID noticeId);

    /**
     * 带姓名的回执人投影（JOIN users/employees），供 {@link NoticeService#listAcknowledgers} 使用。
     * users.employee_id NOT NULL UNIQUE（V04），所以 LEFT JOIN 仅是兜底——正常都会解析到员工姓名。
     */
    @Query(value = """
            SELECT ua.user_id AS userId,
                   COALESCE(e.full_name, u.login_account) AS name,
                   ua.acked_at AS ackedAt
            FROM notice_acknowledgments ua
            JOIN users u ON u.id = ua.user_id
            LEFT JOIN employees e ON e.id = u.employee_id
            WHERE ua.notice_id = :noticeId
            ORDER BY ua.acked_at DESC
            LIMIT :limit
            """, nativeQuery = true)
    List<NoticeAcknowledgerRow> findRecentAcknowledgers(
            @Param("noticeId") UUID noticeId,
            @Param("limit") int limit);

    /** 回执人姓名投影（native query 结果接口）。 */
    interface NoticeAcknowledgerRow {
        UUID getUserId();
        String getName();
        java.time.Instant getAckedAt();
    }
}
