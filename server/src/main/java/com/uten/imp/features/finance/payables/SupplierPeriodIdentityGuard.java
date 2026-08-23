package com.uten.imp.features.finance.payables;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * 供应商财务单据的期间身份守卫：读身份（供应商/币种/业务日期）→ 校验账期开放 →
 * 重锁后校验身份未变。采购收货/退货与委外进仓/退货四条链共用同一口径，
 * 防止封账竞态期间单据身份被并发改写。
 */
@Component
public class SupplierPeriodIdentityGuard {

    /** 白名单表名：原生 SQL 不能绑定表名参数，枚举收口防注入。 */
    public enum SourceTable {
        PURCHASE_RECEIPT("purchase_receipts"),
        PURCHASE_RETURN("purchase_returns"),
        SUBCONTRACT_RECEIPT("subcontract_receipts"),
        SUBCONTRACT_RETURN("subcontract_returns");

        final String table;

        SourceTable(String table) {
            this.table = table;
        }
    }

    public record Identity(UUID supplierId, UUID currencyId, LocalDate billDate) {}

    private final EntityManager em;
    private final SupplierClosedPeriodGuard closedPeriodGuard;

    public SupplierPeriodIdentityGuard(
            EntityManager em, SupplierClosedPeriodGuard closedPeriodGuard) {
        this.em = em;
        this.closedPeriodGuard = closedPeriodGuard;
    }

    public Identity requireIdentity(SourceTable source, UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT supplier_id, currency_id, bill_date
                FROM %s
                WHERE id = :id AND COALESCE(is_deleted, FALSE) = FALSE
                """.formatted(source.table))
                .setParameter("id", id)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "供应商财务单据不存在或已删除");
        }
        Object[] row = rows.getFirst();
        return new Identity(
                (UUID) row[0], (UUID) row[1], LocalDate.parse(row[2].toString()));
    }

    public void requireOpenAtBillDate(Identity identity, String action) {
        closedPeriodGuard.requireOpen(
                identity.supplierId(), identity.currencyId(),
                identity.billDate(), action);
    }

    /** 红冲走当天：封账以当前会计期间为准，不沿用单据业务日期。 */
    public void requireOpenToday(Identity identity, String action) {
        closedPeriodGuard.requireOpen(
                identity.supplierId(), identity.currencyId(),
                BusinessTime.today(), action);
    }

    public void requireUnchanged(
            UUID supplierId, UUID currencyId, LocalDate billDate, Identity identity) {
        if (!Objects.equals(supplierId, identity.supplierId())
                || !Objects.equals(currencyId, identity.currencyId())
                || !Objects.equals(billDate, identity.billDate())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "供应商、币种或业务日期已变化，请刷新后重试");
        }
    }
}
