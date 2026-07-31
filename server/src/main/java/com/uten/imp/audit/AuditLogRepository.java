package com.uten.imp.audit;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.OffsetDateTime;
import java.util.List;

public interface AuditLogRepository
        extends JpaRepository<AuditLog, Long>, JpaSpecificationExecutor<AuditLog> {

    @Query(value = """
            SELECT (created_at AT TIME ZONE 'Asia/Shanghai')::date AS business_date,
                   count(*) AS total_count,
                   count(*) FILTER (
                       WHERE risk_level IN ('critical', 'high', 'medium')
                          OR (risk_level = 'low' AND lower(action) IN (
                              'view_audit_log_detail',
                              'verify_local_audit_receipt',
                              'download_payroll_slip'
                          ))
                   ) AS risk_count
            FROM audit_log
            WHERE created_at >= :fromInclusive
              AND created_at < :toExclusive
              AND (coalesce(:actionPrefix, '') = ''
                   OR lower(action) LIKE lower(concat(:actionPrefix, '%')))
              AND (coalesce(:actorAccount, '') = ''
                   OR lower(coalesce(actor_account, '')) LIKE lower(concat('%', :actorAccount, '%')))
              AND (coalesce(:eventCategory, '') = ''
                   OR CASE
                       WHEN lower(action) IN (
                           'view_audit_log_list',
                           'view_audit_log_summary',
                           'view_audit_log_detail',
                           'verify_local_audit_receipt'
                       ) THEN 'security'
                       WHEN lower(action) = 'download_payroll_slip' THEN 'export'
                       ELSE event_category
                   END = lower(:eventCategory))
            GROUP BY business_date
            ORDER BY business_date
            """, nativeQuery = true)
    List<Object[]> summarizeDaily(
            @Param("fromInclusive") OffsetDateTime fromInclusive,
            @Param("toExclusive") OffsetDateTime toExclusive,
            @Param("actionPrefix") String actionPrefix,
            @Param("actorAccount") String actorAccount,
            @Param("eventCategory") String eventCategory);
}
