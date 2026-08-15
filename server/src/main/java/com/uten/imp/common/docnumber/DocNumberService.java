package com.uten.imp.common.docnumber;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 单据号自动生成：{@code [前缀][YYYYMMDD][6位日流水]}，如 {@code CD20260814000001}。
 *
 * <p>原子取号：单条 {@code INSERT ... ON CONFLICT DO UPDATE ... RETURNING} 由 Postgres
 * 取行锁并自增。顺序号按不可变命名空间和上海业务日期归零。
 *
 * <p><b>时区固定 {@code Asia/Shanghai}</b>（永不用 JVM 默认），否则 UTC 机器月初错位一天。
 *
 * <p>前缀由数据库注册表按枚举名解析，客户端日期、JVM 默认时区和制单人工号均不参与编号。
 *
 * @see DocNumberPrefix
 */
@Service
@RequiredArgsConstructor
public class DocNumberService {

    private static final int MAX_COLLISION_RETRIES = 1024;
    private static final long MAX_DAILY_SEQUENCE = 999999L;

    private final EntityManager em;

    /**
     * 分配并返回下一个完整单据号。调用方应在 create()（实体 id/billNo 为空）时调用；
     * update() 永不重新生成（保留既有号）。
     */
    @Transactional
    public String nextNumber(DocNumberPrefix prefix) {
        for (int attempt = 0; attempt < MAX_COLLISION_RETRIES; attempt++) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    WITH selected_namespace AS (
                        SELECT namespace_key, fixed_prefix
                        FROM business_identifier_namespaces
                        WHERE namespace_key = :namespace
                          AND identifier_family = 'DOCUMENT'
                    ), business_day AS (
                        SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date
                               AS sequence_date
                    ), advanced AS (
                        INSERT INTO business_document_sequences (
                            namespace_key, sequence_date, last_seq)
                        SELECT namespace.namespace_key, day.sequence_date, 1
                        FROM selected_namespace namespace
                        CROSS JOIN business_day day
                        ON CONFLICT (namespace_key, sequence_date)
                        DO UPDATE SET last_seq = business_document_sequences.last_seq + 1
                        RETURNING namespace_key, sequence_date, last_seq
                    ), candidate AS (
                        SELECT namespace.fixed_prefix
                                   || to_char(advanced.sequence_date, 'YYYYMMDD')
                                   || lpad(advanced.last_seq::text, 6, '0') AS value,
                               advanced.last_seq
                        FROM advanced
                        JOIN selected_namespace namespace USING (namespace_key)
                    )
                    SELECT candidate.value,
                           candidate.last_seq,
                           EXISTS (
                               SELECT 1
                               FROM business_identifier_reservations reservation
                               WHERE reservation.normalized_identifier =
                                     upper(btrim(candidate.value))) AS already_reserved
                    FROM candidate
                    """)
                    .setParameter("namespace", prefix.name())
                    .getResultList();
            if (rows.size() != 1) {
                throw new IllegalStateException(
                        "Unregistered document number namespace: " + prefix.name());
            }
            Object[] row = rows.get(0);
            String candidate = (String) row[0];
            long sequence = ((Number) row[1]).longValue();
            if (sequence < 1 || sequence > MAX_DAILY_SEQUENCE) {
                throw new IllegalStateException(
                        "Daily document number sequence exhausted: " + prefix.name());
            }
            if (!Boolean.TRUE.equals(row[2])) {
                return candidate;
            }
        }
        throw new IllegalStateException(
                "Unable to allocate an unused document number after "
                        + MAX_COLLISION_RETRIES + " attempts: " + prefix.name());
    }
}
