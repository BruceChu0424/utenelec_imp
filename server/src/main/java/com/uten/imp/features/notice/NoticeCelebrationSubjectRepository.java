package com.uten.imp.features.notice;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface NoticeCelebrationSubjectRepository
        extends JpaRepository<NoticeCelebrationSubject, UUID> {

    /** 单卡主角名单（按插入顺序稳定展示）。 */
    List<NoticeCelebrationSubject> findByNoticeIdOrderByCreatedAtAsc(UUID noticeId);

    /** 列表页批量装配主角（一次 IN 查询，避免逐卡 N+1）。 */
    List<NoticeCelebrationSubject> findByNoticeIdInOrderByCreatedAtAsc(
            Collection<UUID> noticeIds);

    /**
     * 某员工某庆典类型在指定时间点之后是否已出现在任何庆典卡（聚合或单人）。
     * 幂等去重唯一口径（调度器 / 一键批量祝福共用）。
     */
    @Query("""
            SELECT COUNT(s) > 0
            FROM NoticeCelebrationSubject s, Notice n
            WHERE s.noticeId = n.id
              AND s.employeeId = :employeeId
              AND n.type = :type
              AND n.publishedAt >= :since
            """)
    boolean existsCelebrationSince(
            @Param("employeeId") UUID employeeId,
            @Param("type") String type,
            @Param("since") Instant since);

    /**
     * 某员工某庆典类型在指定时间点之后已发通知的 ID（取最新一条），
     * 「我的今日庆典」卡片/弹窗跳转祝福墙用。
     */
    @Query("""
            SELECT n.id
            FROM NoticeCelebrationSubject s, Notice n
            WHERE s.noticeId = n.id
              AND s.employeeId = :employeeId
              AND n.type = :type
              AND n.publishedAt >= :since
            ORDER BY n.publishedAt DESC
            """)
    List<UUID> findCelebrationNoticeIds(
            @Param("employeeId") UUID employeeId,
            @Param("type") String type,
            @Param("since") Instant since);

    /**
     * 某员工作为主角、指定类型集合、指定时间点之后的通知（如今日发布的新婚/新生儿）。
     */
    @Query("""
            SELECT n
            FROM NoticeCelebrationSubject s, Notice n
            WHERE s.noticeId = n.id
              AND s.employeeId = :employeeId
              AND n.type IN :types
              AND n.publishedAt >= :since
            ORDER BY n.publishedAt DESC
            """)
    List<Notice> findBySubjectAndTypesSince(
            @Param("employeeId") UUID employeeId,
            @Param("types") List<String> types,
            @Param("since") Instant since);
}
