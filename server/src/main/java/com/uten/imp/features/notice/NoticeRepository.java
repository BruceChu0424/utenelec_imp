package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;
import org.springframework.data.domain.Pageable;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public interface NoticeRepository extends JpaRepository<Notice, UUID> {

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
              AND (s IS NULL OR s.readAt IS NULL)
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

    /**
     * 某员工某庆典类型在指定时间点之后是否已有通知（用于一键批量祝福去重，
     * 与 {@code CelebrationScheduler} 的 (subject,type,当年) 幂等口径一致）。
     */
    @Query("""
            SELECT COUNT(n) > 0
            FROM Notice n
            WHERE n.subjectEmployeeId = :subjectId
              AND n.type = :type
              AND n.publishedAt >= :since
            """)
    boolean existsCelebrationSince(
            @Param("subjectId") UUID subjectId,
            @Param("type") String type,
            @Param("since") Instant since);

    /**
     * 查某员工某庆典类型在指定时间点之后已发的通知 ID（取最新一条），
     * 用于「我的今日庆典」卡片/弹窗跳转祝福墙。返回空列表=尚无。
     */
    @Query("""
            SELECT n.id
            FROM Notice n
            WHERE n.subjectEmployeeId = :subjectId
              AND n.type = :type
              AND n.publishedAt >= :since
            ORDER BY n.publishedAt DESC
            """)
    List<UUID> findCelebrationNoticeIds(
            @Param("subjectId") UUID subjectId,
            @Param("type") String type,
            @Param("since") Instant since);

    /**
     * 查某员工作为祝福对象、指定类型集合、指定时间点之后的通知（如今日发布的新婚/新生儿）。
     */
    @Query("""
            SELECT n
            FROM Notice n
            WHERE n.subjectEmployeeId = :subjectId
              AND n.type IN :types
              AND n.publishedAt >= :since
            ORDER BY n.publishedAt DESC
            """)
    List<Notice> findBySubjectAndTypesSince(
            @Param("subjectId") UUID subjectId,
            @Param("types") List<String> types,
            @Param("since") Instant since);
}
