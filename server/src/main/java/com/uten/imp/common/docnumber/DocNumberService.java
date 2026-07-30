package com.uten.imp.common.docnumber;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.ZoneId;

/**
 * 单据号自动生成：{@code [前缀][YYMM][4位月内顺序号]}，如 {@code CD26070001}。
 *
 * <p>原子取号：单条 {@code INSERT ... ON CONFLICT DO UPDATE ... RETURNING} 由 Postgres
 * 取行锁并自增，微秒级、无死锁面。顺序号按 {@code (prefix, period=YYMM)} 月度归零。
 *
 * <p><b>时区固定 {@code Asia/Shanghai}</b>（永不用 JVM 默认），否则 UTC 机器月初错位一天。
 *
 * <p>回滚的事务会跳号——可接受（单号要唯一+单调，不要无缝）。
 *
 * @see DocNumberPrefix
 */
@Service
@RequiredArgsConstructor
public class DocNumberService {

    private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");

    private final EntityManager em;

    /**
     * 分配并返回下一个完整单据号。调用方应在 create()（实体 id/billNo 为空）时调用；
     * update() 永不重新生成（保留既有号）。
     */
    @Transactional
    public String nextNumber(DocNumberPrefix prefix) {
        LocalDate today = LocalDate.now(ZONE);
        int period = (today.getYear() % 100) * 100 + today.getMonthValue();
        // Postgres 原子 upsert + RETURNING：INSERT 新 (prefix,period) 行返回 1；已存在则自增返回新值。
        Object row = em.createNativeQuery("""
                INSERT INTO doc_number_sequences (prefix, period, last_seq)
                VALUES (:p, :per, 1)
                ON CONFLICT (prefix, period)
                DO UPDATE SET last_seq = doc_number_sequences.last_seq + 1
                RETURNING last_seq
                """)
                .setParameter("p", prefix.code())
                .setParameter("per", period)
                .getSingleResult();
        // 单列原生查询：Hibernate 一般返回标量；个别配置包成 Object[]，两种都兜底。
        int next = (row instanceof Object[] a) ? ((Number) a[0]).intValue() : ((Number) row).intValue();
        return String.format("%s%04d%04d", prefix.code(), period, next);
    }
}
