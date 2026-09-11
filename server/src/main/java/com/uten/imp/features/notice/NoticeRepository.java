package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.data.domain.Pageable;

import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

public interface NoticeRepository extends JpaRepository<Notice, UUID> {

    // Applied inside every list/count query, before pagination. Old broadcast or
    // unanchored workshop messages cannot inherit newly widened department access.
    String WORKSHOP_VISIBILITY = """
              AND (n.sourceEvent IS NULL OR n.sourceEvent <> 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'
                OR (:#{#workshopScope.allowed} = true
                  AND n.audienceUserId = :userId
                  AND n.aggregateKind = 'PRODUCTION_EXECUTION_SEGMENT'
                  AND EXISTS (
                    SELECT workshopTask.id FROM ProductionExecutionSegment workshopTask
                    JOIN Department workshop ON workshop.id=workshopTask.workshopDepartmentId
                    WHERE workshopTask.id=n.aggregateId AND workshopTask.deleted=false
                      AND workshop.deleted=false
                      AND (workshopTask.workshopDepartmentId IN :#{#workshopScope.departmentIds}
                           OR workshopTask.responsibleEmployeeId=:#{#workshopScope.employeeId}))))
            """;

    @Query("SELECT n.id FROM Notice n WHERE n.id IN :ids " + WORKSHOP_VISIBILITY)
    List<UUID> findScopedVisibleNoticeIds(@Param("userId") UUID userId,
            @Param("ids") Set<UUID> ids,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope);

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
            """ + WORKSHOP_VISIBILITY + """
            ORDER BY n.topPriority DESC, n.publishedAt DESC
            """)
    List<Notice> findVisible(
            @Param("userId") UUID userId,
            @Param("onlyUnread") boolean onlyUnread,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope,
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
            """ + WORKSHOP_VISIBILITY + """
            ORDER BY n.publishedAt ASC, n.id ASC
            """)
    List<Notice> findVisibleArrivalsAfter(
            @Param("userId") UUID userId,
            @Param("afterPublishedAt") Instant afterPublishedAt,
            @Param("afterId") UUID afterId,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope,
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
            """ + WORKSHOP_VISIBILITY)
    long countVisibleUnread(@Param("userId") UUID userId,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope);

    @Query("""
            SELECT COUNT(n)
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.audienceUserId = :userId
              AND n.sourceEvent IN :events
              AND (s IS NULL OR (s.deletedAt IS NULL AND s.readAt IS NULL))
            """ + WORKSHOP_VISIBILITY)
    long countUnreadBySourceEvents(@Param("userId") UUID userId, @Param("events") List<String> events,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope);

    /**
     * V459 居中审核弹窗的登录检查：当前用户名下**未办结**的待审通知——
     * 审核目录注册事件、未撤回、未删除、稍后提醒已到期（或从未稍后）。
     * 2026-09-10 生效口径（ADR-063 修订）：弹 = 未办结 且（未确认弹窗 或 稍后已到期）。
     *  - 车间任务 normal（等料/等待中）也进弹窗——「收到几个车间任务」按全部未办结计；
     *  - 「处理过不再重复弹」：popup_acknowledged 过的静默（markRead / 去工作台处理即置）；
     *  - 「稍后再看」(snooze) 到期后恒弹（snoozedUntil 非空且已到期），即使已读/已确认——
     *    markRead 不再清 snooze，用户明确要求的再提醒不被已读吞掉。
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
                    AND (
                      (s.snoozedUntil IS NOT NULL AND s.snoozedUntil <= CURRENT_TIMESTAMP)
                      OR (s.popupAcknowledgedAt IS NULL
                          AND (s.snoozedUntil IS NULL OR s.snoozedUntil <= CURRENT_TIMESTAMP))
                    )
                  ))
            """ + WORKSHOP_VISIBILITY + """
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
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope,
            Pageable pageable);

    /**
     * 人工通知登录弹窗（2026-09-10，ADR-063 §8）：人事手动发布（{@code source_event IS NULL}）、
     * 非庆典（庆典有自己的每日登录弹窗）、对当前用户可见且未删除的通知中，仍待处理的：
     * <ul>
     *   <li><b>acknowledge（打卡）模式</b>：本人尚无 {@code notice_acknowledgments} 行，
     *       且（未稍后 或 稍后已到期）。<b>无时间上限</b>——打卡是强制动作，不打卡每次登录都弹。</li>
     *   <li><b>none（只提醒）模式</b>：未确认过弹窗（{@code popup_acknowledged_at} 为空）且
     *       （从未读且未稍后 或 稍后已到期），并且发布时间在 {@code noneModeSince} 之后
     *       （服务层给 14 天窗口，避免旧提醒永久打扰）。</li>
     * </ul>
     * 可见性谓词与 {@link #findVisible} 一致（全员 / 定向本人 / selected 预建状态行）。
     * 人工通知无 source_event，故无需车间对象范围子句。排序：打卡优先 → 紧急/重要 → 置顶 → 发布时间倒序。
     */
    @Query("""
            SELECT n
            FROM Notice n
            LEFT JOIN NoticeUserState s
              ON s.id.noticeId = n.id AND s.id.userId = :userId
            WHERE n.sourceEvent IS NULL
              AND n.interactionMode <> 'bless'
              AND (
                    (n.audienceUserId IS NULL AND n.audienceScope = 'all')
                    OR n.audienceUserId = :userId
                    OR (n.audienceScope = 'selected' AND s IS NOT NULL)
                  )
              AND (s IS NULL OR s.deletedAt IS NULL)
              AND (
                    (
                      n.interactionMode = 'acknowledge'
                      AND NOT EXISTS (
                        SELECT a.id.noticeId FROM NoticeAcknowledgment a
                        WHERE a.id.noticeId = n.id AND a.id.userId = :userId
                      )
                      AND (s IS NULL OR s.snoozedUntil IS NULL OR s.snoozedUntil <= CURRENT_TIMESTAMP)
                    )
                    OR (
                      n.interactionMode <> 'acknowledge'
                      AND n.publishedAt >= :noneModeSince
                      AND (s IS NULL OR (
                            s.popupAcknowledgedAt IS NULL
                            AND (
                              (s.readAt IS NULL AND s.snoozedUntil IS NULL)
                              OR (s.snoozedUntil IS NOT NULL AND s.snoozedUntil <= CURRENT_TIMESTAMP)
                            )
                          ))
                    )
                  )
            ORDER BY
                CASE WHEN n.interactionMode = 'acknowledge' THEN 0 ELSE 1 END,
                CASE n.priority
                    WHEN 'urgent' THEN 0
                    WHEN 'important' THEN 1
                    ELSE 2 END,
                n.topPriority DESC,
                n.publishedAt DESC
            """)
    List<Notice> findVisiblePendingManualNotices(
            @Param("userId") UUID userId,
            @Param("noneModeSince") Instant noneModeSince,
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
            """ + WORKSHOP_VISIBILITY + """
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
    List<Notice> findPendingTodos(@Param("userId") UUID userId, @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope,
            Pageable pageable);

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
            """ + WORKSHOP_VISIBILITY)
    long countPendingTodos(@Param("userId") UUID userId,
            @Param("workshopScope") ReviewNoticeAudience.WorkshopScope workshopScope);

    // V454 起，按祝福对象的庆典查询（幂等去重 / 我的今日庆典 / 今日新婚新生儿）
    // 统一迁至 NoticeCelebrationSubjectRepository（聚合卡与单人卡同口径）。
}
