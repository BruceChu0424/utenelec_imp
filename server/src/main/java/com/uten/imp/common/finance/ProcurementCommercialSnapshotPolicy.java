package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.UUID;

/** Shared finance gate for purchase/subcontract commercial snapshots. */
public final class ProcurementCommercialSnapshotPolicy {
    private static final BigDecimal MAX_TAX_RATE_PERCENT = new BigDecimal("100");

    private ProcurementCommercialSnapshotPolicy() {
    }

    public static void requireComplete(
            EntityManager em,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate,
            String subject) {
        if (currencyId == null) {
            throw validation(subject + "必须选择币种");
        }
        if (exchangeRate == null || exchangeRate.signum() <= 0) {
            throw validation(subject + "汇率必须大于0");
        }
        if (taxRate == null || taxRate.signum() < 0
                || taxRate.compareTo(MAX_TAX_RATE_PERCENT) > 0) {
            throw validation(subject + "税率必须明确填写为0至100之间的百分比");
        }
        long activeCurrency = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM currencies
                WHERE id=:id AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id", currencyId).getSingleResult()).longValue();
        if (activeCurrency != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    subject + "币种不存在、已停用或未经财务核验");
        }
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
