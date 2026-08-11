package com.uten.imp.features.notice;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface NoticeBlessingRepository extends JpaRepository<NoticeBlessing, UUID> {

    long countByNoticeId(UUID noticeId);

    Optional<NoticeBlessing> findByNoticeIdAndUserId(UUID noticeId, UUID userId);

    /** 列表页角标用：前 5 条最新祝福。 */
    List<NoticeBlessing> findTop5ByNoticeIdOrderByCreatedAtDesc(UUID noticeId);

    /** 详情页「全部祝福」用：分页（控制器层限制 size ≤ 50）。 */
    List<NoticeBlessing> findByNoticeIdOrderByCreatedAtDesc(UUID noticeId, Pageable pageable);

    /** 删除当前用户对某通知的祝福（撤回）。返回删除条数（0=本就没祝福过，幂等）。 */
    long deleteByNoticeIdAndUserId(UUID noticeId, UUID userId);

    /**
     * 带姓名的祝福投影（JOIN users/employees），供 {@link NoticeService#listBlessings} 使用。
     * 与 {@link NoticeAcknowledgmentRepository#findRecentAcknowledgers} 同样的姓名解析策略。
     */
    @Query(value = """
            SELECT b.id AS id,
                   b.sender_name AS senderName,
                   b.content AS content,
                   b.created_at AS createdAt,
                   b.user_id AS userId
            FROM notice_blessings b
            WHERE b.notice_id = :noticeId
            ORDER BY b.created_at DESC
            LIMIT :limit
            OFFSET :offset
            """, nativeQuery = true)
    List<NoticeBlessingRow> findPage(@Param("noticeId") UUID noticeId,
                                     @Param("limit") int limit,
                                     @Param("offset") int offset);

    /** 祝福列表投影（native query 结果接口）。 */
    interface NoticeBlessingRow {
        UUID getId();
        String getSenderName();
        String getContent();
        java.time.Instant getCreatedAt();
        UUID getUserId();
    }
}
