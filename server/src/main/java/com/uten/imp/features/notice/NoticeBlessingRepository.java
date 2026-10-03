package com.uten.imp.features.notice;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface NoticeBlessingRepository extends JpaRepository<NoticeBlessing, UUID> {

    @Query("SELECT count(b) FROM NoticeBlessing b WHERE b.noticeId=:noticeId AND b.deleted=false")
    long countByNoticeId(@Param("noticeId") UUID noticeId);

    Optional<NoticeBlessing> findByNoticeIdAndUserId(UUID noticeId, UUID userId);

    /** 列表页角标用：前 5 条最新祝福。 */
    @Query("SELECT b FROM NoticeBlessing b WHERE b.noticeId=:noticeId AND b.deleted=false ORDER BY b.createdAt DESC LIMIT 5")
    List<NoticeBlessing> findTop5ByNoticeIdOrderByCreatedAtDesc(@Param("noticeId") UUID noticeId);

    /** 详情页「全部祝福」用：分页（控制器层限制 size ≤ 50）。 */
    List<NoticeBlessing> findByNoticeIdOrderByCreatedAtDesc(UUID noticeId, Pageable pageable);

    /** 删除当前用户对某通知的祝福（撤回）。返回删除条数（0=本就没祝福过，幂等）。 */
    default long deleteByNoticeIdAndUserId(UUID noticeId,UUID userId){return markWithdrawn(noticeId,userId);}

    @org.springframework.data.jpa.repository.Modifying(clearAutomatically=true,flushAutomatically=true)
    @Query("UPDATE NoticeBlessing b SET b.deleted=true,b.deletedAt=CURRENT_TIMESTAMP,b.deletedBy=:userId,b.deletedReason='USER_WITHDRAW' WHERE b.noticeId=:noticeId AND b.userId=:userId AND b.deleted=false")
    int markWithdrawn(@Param("noticeId") UUID noticeId,@Param("userId") UUID userId);

    @Query(value="""
            SELECT id,blessing_id AS blessingId,payload->>'sender_name' AS senderName,
                   payload->>'content' AS content,recorded_at AS recordedAt,
                   actor_id AS actorId,operation,payload->>'is_deleted' AS deleted,
                   payload->>'deleted_reason' AS deletedReason
            FROM notice_blessing_history WHERE notice_id=:noticeId
              AND (CAST(:beforeId AS bigint) IS NULL OR id<:beforeId)
            ORDER BY id DESC LIMIT :limit
            """,nativeQuery=true)
    List<BlessingHistoryRow> findHistory(@Param("noticeId") UUID noticeId,@Param("beforeId") Long beforeId,@Param("limit") int limit);
    interface BlessingHistoryRow {
        Long getId();UUID getBlessingId();String getSenderName();String getContent();java.time.Instant getRecordedAt();
        UUID getActorId();String getOperation();String getDeleted();String getDeletedReason();
    }

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
            WHERE b.notice_id = :noticeId AND NOT b.is_deleted
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
