package com.uten.imp.common.mastercode;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 主档编号自动生成：{@code [前缀][6位顺序号]}，如货品 {@code HP000001}。
 *
 * <p>原子取号：单条 {@code INSERT ... ON CONFLICT DO UPDATE ... RETURNING} 由 Postgres
 * 取行锁并自增，微秒级、无死锁面。顺序号按 prefix 全局单调递增（主档编号是永久标识，不带日期、不归零）。
 *
 * <p>回滚的事务会跳号——可接受（编号要唯一+单调，不要无缝）。
 *
 * <p>调用方应在 create()（实体 code 为空）时调用；update() 永不重新生成（保留既有号）。
 * 前缀与遗留 code 零碰撞（见 {@link MasterCodePrefix}），加上各主档表的部分唯一索引
 * （{@code WHERE legacy_id IS NULL AND is_deleted = false}），新编号唯一性双重保证。
 *
 * @see MasterCodePrefix
 */
@Service
@RequiredArgsConstructor
public class MasterCodeService {

    private final EntityManager em;

    /**
     * 分配并返回下一个完整主档编号。
     */
    @Transactional
    public String nextCode(MasterCodePrefix prefix) {
        // Postgres 原子 upsert + RETURNING：INSERT 新 prefix 行返回 1；已存在则自增返回新值。
        Object row = em.createNativeQuery("""
                INSERT INTO master_code_sequences (prefix, last_seq)
                VALUES (:p, 1)
                ON CONFLICT (prefix)
                DO UPDATE SET last_seq = master_code_sequences.last_seq + 1
                RETURNING last_seq
                """)
                .setParameter("p", prefix.code())
                .getSingleResult();
        // 单列原生查询：Hibernate 一般返回标量；个别配置包成 Object[]，两种都兜底。
        int next = (row instanceof Object[] a) ? ((Number) a[0]).intValue() : ((Number) row).intValue();
        return String.format("%s%06d", prefix.code(), next);
    }
}
