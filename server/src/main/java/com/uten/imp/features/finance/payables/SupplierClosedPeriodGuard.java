package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Serializes supplier money events with monthly close and rejects backdated
 * mutation at or before the latest both-confirmed/closed supplier statement.
 */
@Service
@RequiredArgsConstructor
public class SupplierClosedPeriodGuard {
    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public void requireOpen(
            UUID supplierId, UUID currencyId, LocalDate businessDate, String action) {
        if (supplierId == null || currencyId == null || businessDate == null) {
            throw conflict(label(action) + "缺少供应商、币种或业务日期，禁止绕过供应商封账");
        }
        @SuppressWarnings("unchecked")
        List<UUID> suppliers = em.createNativeQuery("""
                SELECT id FROM suppliers
                WHERE id=:supplierId AND COALESCE(is_deleted,FALSE)=FALSE
                FOR SHARE
                """).setParameter("supplierId", supplierId).getResultList();
        if (suppliers.size() != 1) {
            throw conflict(label(action) + "供应商不存在或已删除，禁止写入");
        }
        Object value = em.createNativeQuery("""
                SELECT MAX(period_end)
                FROM supplier_settlement_batches
                WHERE supplier_id=:supplierId AND currency_id=:currencyId
                  AND (
                    status <> 'REVERSED'
                    OR (supplier_confirmed_at IS NOT NULL AND internal_confirmed_at IS NOT NULL)
                    OR status='CLOSED'
                  )
                  AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("supplierId", supplierId)
                .setParameter("currencyId", currencyId)
                .getSingleResult();
        LocalDate closedThrough = value == null ? null : LocalDate.parse(value.toString());
        if (isClosed(businessDate, closedThrough)) {
            throw conflict(label(action) + "业务日期 " + businessDate
                    + " 已被供应商月结封账(截止 " + closedThrough
                    + ")，请在下一开放期间登记调整");
        }
    }

    static boolean isClosed(LocalDate businessDate, LocalDate closedThrough) {
        return businessDate != null && closedThrough != null
                && !businessDate.isAfter(closedThrough);
    }

    static boolean contributesToClosedThrough(
            String status,boolean supplierConfirmed,boolean internalConfirmed){
        return status!=null&&(!"REVERSED".equals(status)
                ||supplierConfirmed&&internalConfirmed
                ||"CLOSED".equals(status));
    }

    private static String label(String action) {
        return action == null || action.isBlank() ? "供应商财务事件：" : action.trim() + "：";
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
