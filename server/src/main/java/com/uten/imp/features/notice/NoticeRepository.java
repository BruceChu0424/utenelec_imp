package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.data.domain.Pageable;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public interface NoticeRepository extends JpaRepository<Notice, UUID> {

    @Query(value="""
            SELECT id AS "shipmentId",
              (status=0 AND NOT is_deleted AND NOT rejected AND NOT finance_rejected AND finance_audit=0
                AND warehouse_work_status='PENDING_PICK' AND (finance_gate_version<2 OR
                    (sales_confirmed_at IS NOT NULL AND sales_confirmed_revision=review_revision))) AS "financePending",
              (status=0 AND NOT is_deleted AND NOT rejected AND finance_audit=1
                AND warehouse_work_status='PENDING_PICK') AS "pickPending",
              (status=0 AND NOT is_deleted AND NOT rejected AND finance_rejected AND warehouse_work_status='PENDING_PICK') AS "correctionPending"
            FROM sales_shipments WHERE id IN (:ids)
            """,nativeQuery=true)
    List<ShipmentReviewStateRow> findShipmentReviewStates(@Param("ids") java.util.Set<UUID> ids);

    interface ShipmentReviewStateRow {
        UUID getShipmentId();
        boolean getFinancePending();
        boolean getPickPending();
        boolean getCorrectionPending();
    }

    @Query("""
            SELECT n
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR s.deletedAt IS NULL)
              AND (:onlyUnread = false OR s IS NULL OR s.readAt IS NULL)
            ORDER BY n.topPriority DESC, n.publishedAt DESC
            """)
    List<Notice> findVisible(
            @Param("userId") UUID userId,
            @Param("onlyUnread") boolean onlyUnread,
            Pageable pageable);


    @Query("""
            SELECT n
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR s.deletedAt IS NULL)
              AND (s IS NULL OR (
                    s.readAt IS NULL
                    AND s.popupAcknowledgedAt IS NULL
                  ))
              AND (n.resolvedAt IS NULL)
              AND (s IS NULL OR s.snoozedUntil IS NULL OR s.snoozedUntil <= CURRENT_TIMESTAMP)
              AND (
                    n.publishedAt > :afterPublishedAt
                    OR (n.publishedAt = :afterPublishedAt AND n.id > :afterId)
                  )
            ORDER BY n.publishedAt ASC, n.id ASC
            """)
    List<Notice> findVisibleArrivalsAfter(
            @Param("userId") UUID userId,
            @Param("afterPublishedAt") Instant afterPublishedAt,
            @Param("afterId") UUID afterId,
            Pageable pageable);

    /**
     * V459 办结撤回：按 (aggregateKind, aggregateId) 批量置办结时间与原因，
     * 一次 UPDATE 撤回该聚合全部接收人的待审通知；仅未办结行，幂等。
     */
    @org.springframework.data.jpa.repository.Modifying
    @Query("""
            UPDATE Notice n
               SET n.resolvedAt = CURRENT_TIMESTAMP,
                   n.resolvedReason = :reason
             WHERE n.aggregateKind = :aggregateKind
               AND n.aggregateId = :aggregateId
               AND n.resolvedAt IS NULL
            """)
    int resolveReviewPendingByAggregate(
            @Param("aggregateKind") String aggregateKind,
            @Param("aggregateId") UUID aggregateId,
            @Param("reason") String reason);

    @Query("""
            SELECT COUNT(n)
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR (s.deletedAt IS NULL AND s.readAt IS NULL))
            """)
    long countVisibleUnread(@Param("userId") UUID userId);

    @Query("""
            SELECT COUNT(n)
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.audienceUserId = :userId
              AND n.sourceEvent IN :events
              AND (s IS NULL OR (s.deletedAt IS NULL AND s.readAt IS NULL))
            """)
    long countUnreadBySourceEvents(@Param("userId") UUID userId, @Param("events") List<String> events);

    /**
     * V459 居中审核弹窗的登录检查：当前用户名下**未办结**的待审通知——
     * 审核目录注册事件、未撤回、未删除、稍后提醒已到期（或从未稍后）；
     * 已读与否不影响（读没读不重要，办没办才重要；「稍后再看」是唯一静默途径）。
     */
    @Query("""
            SELECT n
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.audienceUserId = :userId
              AND n.sourceEvent IN :events
              AND n.aggregateId IS NOT NULL AND n.aggregateKind IS NOT NULL
              AND n.resolvedAt IS NULL
              AND (s IS NULL OR (
                    s.deletedAt IS NULL
                    AND (s.snoozedUntil IS NULL OR s.snoozedUntil <= CURRENT_TIMESTAMP)
                  ))
            ORDER BY
                CASE n.priority
                    WHEN 'urgent' THEN 0
                    WHEN 'important' THEN 1
                    ELSE 2 END,
                n.publishedAt DESC
            """)
    List<Notice> findVisiblePendingReviews(
            @Param("userId") UUID userId,
            @Param("events") List<String> events,
            Pageable pageable);

    @Query("""
            SELECT n
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.kind = 'TODO'
              AND (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR (s.deletedAt IS NULL AND s.taskCompletedAt IS NULL))
            ORDER BY
              CASE WHEN n.dueAt IS NULL THEN 1 ELSE 0 END,
              n.dueAt,
              CASE n.priority
                WHEN 'urgent' THEN 0
                WHEN 'important' THEN 1
                ELSE 2
              END,
              n.publishedAt DESC
            """)
    List<Notice> findPendingTodos(@Param("userId") UUID userId, Pageable pageable);

    @Query("""
            SELECT COUNT(n)
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.kind = 'TODO'
              AND (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR (s.deletedAt IS NULL AND s.taskCompletedAt IS NULL))
            """)
    long countPendingTodos(@Param("userId") UUID userId);

    // V454 起，按祝福对象的庆典查询（幂等去重 / 我的今日庆典 / 今日新婚新生儿）
    // 统一迁至 NoticeCelebrationSubjectRepository（聚合卡与单人卡同口径）。
}
