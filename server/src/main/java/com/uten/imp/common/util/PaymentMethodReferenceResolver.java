package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * UUID-authoritative resolver for receipt/payment methods.
 *
 * <p>RecStyle/PaidStyle share the independent {@code finance_payment_methods} master. Normal API
 * writes require its UUID. A supplied legacy key is only a consistency shadow beside the UUID; it
 * is never resolved online or against the unrelated M_Style/payment_styles hierarchy.</p>
 */
public final class PaymentMethodReferenceResolver {

    private PaymentMethodReferenceResolver() {}

    public static PaymentMethodReference resolve(
            EntityManager em, UUID id, Integer legacyId, String label, Direction direction) {
        String subject = label == null || label.isBlank() ? "结算方式" : label.trim();
        if (legacyId != null && legacyId <= 0) {
            throw invalid(subject + "旧编号必须大于 0");
        }
        if (id == null) {
            if (legacyId == null) return null;
            throw invalid(subject + "必须使用系统 UUID；旧编号仅作历史快照");
        }

        PaymentMethodReference target =
                find(em, "method.id = :value", "value", id, direction);
        if (target == null) {
            throw invalid(subject + "不存在、已停用、名称尚未确认，或旧编号没有 UUID 映射");
        }
        if (id != null && legacyId != null && !Objects.equals(legacyId, target.legacyId())) {
            throw new ApiException(ErrorCode.CONFLICT, subject + " UUID 与旧编号不一致");
        }
        return target;
    }

    private static PaymentMethodReference find(
            EntityManager em, String predicate, String parameter, Object value, Direction direction) {
        List<?> rows = em.createNativeQuery("""
                        SELECT method.id, method.legacy_id
                        FROM finance_payment_methods method
                        WHERE %s
                          AND method.status = '使用'
                          AND COALESCE(method.is_deleted, false) = false
                          AND method.legacy_name_confirmed = true
                          AND (:direction = 'ANY'
                               OR (:direction = 'RECEIPT' AND method.is_receipt)
                               OR (:direction = 'PAYMENT' AND method.is_payment))
                        """.formatted(predicate))
                .setParameter(parameter, value)
                .setParameter("direction", direction == null ? Direction.ANY.name() : direction.name())
                .setMaxResults(2)
                .getResultList();
        if (rows.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT, "结算方式映射不唯一");
        }
        if (rows.isEmpty()) return null;
        Object[] row = (Object[]) rows.getFirst();
        return new PaymentMethodReference(
                (UUID) row[0], row[1] == null ? null : ((Number) row[1]).intValue());
    }

    private static ApiException invalid(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    public record PaymentMethodReference(UUID id, Integer legacyId) {}

    public enum Direction { ANY, RECEIPT, PAYMENT }
}
