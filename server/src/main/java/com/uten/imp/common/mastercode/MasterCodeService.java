package com.uten.imp.common.mastercode;

import jakarta.persistence.EntityManager;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/**
 * 主档/系统流水编号自动生成：{@code [前缀][顺序号]}，顺序号位数由 {@link MasterCodePrefix#width()} 决定
 * （默认 6，如货品 {@code HP000001}；工号为 4，如 {@code UT0001}）。
 *
 * <p>原子取号：单条 {@code INSERT ... ON CONFLICT DO UPDATE ... RETURNING} 由 Postgres
 * 取行锁并自增。顺序号按 prefix 全局单调递增（主档显示编号不带日期、不归零）。
 *
 * <p>回滚的事务会跳号——可接受（编号要唯一+单调，不要无缝）。
 *
 * <p>固定前缀主档通常只在 create()（实体 code 为空）时调用；分类驱动的货品、模具、客户、
 * 供应商改号由 {@link CategoryDrivenCodeService} 负责，不能套用“update 永不改号”的规则。
 *
 * <p>V279 的全局预约表是跨主档、单据和系统号的最终唯一性权威：规范化后的完整编号一经使用即
 * 终身占用。V911 对从未业务使用且有完整生命周期证明的已删货品提供窄例外，由
 * CategoryDrivenCodeService 的新货品入口受控登记释放；本固定编号服务及其它业务域不放宽。
 * 各业务表的局部索引和服务层查重只用于更早给出友好错误。
 * 编号不是关联身份，关系仍只保存 UUID。
 *
 * @see MasterCodePrefix
 */
@Service
@RequiredArgsConstructor
public class MasterCodeService {

    private static final int MAX_GLOBAL_COLLISION_RETRIES = 1024;

    private final EntityManager em;

    /** Empty on create allocates; empty on edit keeps the current display code. */
    @Transactional
    public String resolveMutableCode(MasterCodePrefix prefix, String requested,
                                     UUID entityId, String currentCode) {
        return resolveMutableCode(prefix, requested, entityId, currentCode, false);
    }

    /** Internal version recovery may restore the original UUID from its soft-deleted state. */
    @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
    public String resolveMutableCodeForRestore(MasterCodePrefix prefix, String requested,
                                              UUID entityId, String currentCode) {
        if (entityId == null) throw new ApiException(ErrorCode.CONFLICT, "编号恢复缺少原资料身份");
        return resolveMutableCode(prefix, requested, entityId, currentCode, true);
    }

    private String resolveMutableCode(MasterCodePrefix prefix, String requested, UUID entityId,
                                     String currentCode, boolean includeDeleted) {
        if (requested == null || requested.isBlank()) {
            return currentCode == null ? nextCode(prefix) : currentCode;
        }
        var result = MasterIdentifierAvailabilityService.check(em,
                MasterIdentifierAvailabilityService.Domain.valueOf(prefix.name()), requested, entityId, includeDeleted);
        if (!result.available()) throw new ApiException(ErrorCode.CONFLICT, result.message());
        return result.normalizedCode();
    }

    /**
     * 分配并返回下一个完整主档编号。
     */
    @Transactional
    public String nextCode(MasterCodePrefix prefix) {
        for (int attempt = 0; attempt < MAX_GLOBAL_COLLISION_RETRIES; attempt++) {
            Object row = em.createNativeQuery("""
                    WITH advanced AS (
                        INSERT INTO master_code_sequences (prefix, last_seq)
                        VALUES (:prefix, 1)
                        ON CONFLICT (prefix)
                        DO UPDATE SET last_seq = master_code_sequences.last_seq + 1
                        RETURNING last_seq
                    ), candidate AS (
                        SELECT :prefix || CASE
                                   WHEN length(advanced.last_seq::text) < :width
                                   THEN lpad(advanced.last_seq::text, :width, '0')
                                   ELSE advanced.last_seq::text
                               END AS value,
                               advanced.last_seq
                        FROM advanced
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
                    .setParameter("prefix", prefix.code())
                    .setParameter("width", prefix.width())
                    .getSingleResult();
            Object[] values = (Object[]) row;
            long sequence = ((Number) values[1]).longValue();
            if (sequence < 1 || sequence > maxSequence(prefix)) {
                throw new IllegalStateException(
                        "Master code sequence exhausted: " + prefix.name());
            }
            if (!Boolean.TRUE.equals(values[2])) {
                return (String) values[0];
            }
        }
        throw new IllegalStateException(
                "Unable to allocate an unused master code after "
                        + MAX_GLOBAL_COLLISION_RETRIES + " attempts: " + prefix.name());
    }

    private static long maxSequence(MasterCodePrefix prefix) {
        long exclusiveUpperBound = 1;
        for (int digit = 0; digit < prefix.width(); digit++) {
            exclusiveUpperBound = Math.multiplyExact(exclusiveUpperBound, 10L);
        }
        return Math.min(exclusiveUpperBound - 1L, Integer.MAX_VALUE);
    }
}
