package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** UUID-authoritative resolver for the legacy B_PStyle settlement dictionary. */
public final class SettlementMethodReferenceResolver {

    private SettlementMethodReferenceResolver() {}

    public static SettlementMethodReference resolve(
            EntityManager em, UUID id, Integer legacyId, String label) {
        String subject = label == null || label.isBlank() ? "结帐方式" : label.trim();
        if (legacyId != null && legacyId <= 0) {
            throw invalid(subject + "旧编号必须大于 0");
        }
        if (id == null) {
            if (legacyId == null) return null;
            throw invalid(subject + "必须使用系统 UUID；旧编号仅作历史快照");
        }

        SettlementMethodReference target = find(em, "method.id = :value", id);
        if (target == null) {
            throw invalid(subject + "不存在、已停用，或旧编号没有 UUID 映射");
        }
        if (id != null && legacyId != null && !Objects.equals(legacyId, target.legacyId())) {
            throw new ApiException(ErrorCode.CONFLICT, subject + " UUID 与旧编号不一致");
        }
        return target;
    }

    private static SettlementMethodReference find(EntityManager em, String predicate, Object value) {
        List<?> rows = em.createNativeQuery("""
                        SELECT method.id, method.legacy_id, method.code,
                               method.name, method.system_role
                        FROM settlement_methods method
                        WHERE %s
                          AND method.status = '使用'
                          AND COALESCE(method.is_deleted, false) = false
                        """.formatted(predicate))
                .setParameter("value", value)
                .setMaxResults(2)
                .getResultList();
        if (rows.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT, "结帐方式映射不唯一");
        }
        if (rows.isEmpty()) return null;
        Object[] row = (Object[]) rows.getFirst();
        return new SettlementMethodReference(
                (UUID) row[0],
                row[1] == null ? null : ((Number) row[1]).intValue(),
                row[2] == null ? null : row[2].toString(),
                row[3] == null ? null : row[3].toString(),
                row[4] == null ? null : row[4].toString());
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    public record SettlementMethodReference(
            UUID id,
            Integer legacyId,
            String code,
            String name,
            String systemRole) {}
}
