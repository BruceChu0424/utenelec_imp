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
              AND (s IS NULL OR (
                    s.readAt IS NULL
                    AND s.popupAcknowledgedAt IS NULL
                  ))
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

    // V454 起，按祝福对象的庆典查询（幂等去重 / 我的今日庆典 / 今日新婚新生儿）
    // 统一迁至 NoticeCelebrationSubjectRepository（聚合卡与单人卡同口径）。
}
