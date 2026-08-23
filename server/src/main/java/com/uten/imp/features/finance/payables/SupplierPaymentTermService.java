package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.temporal.TemporalAdjusters;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * Resolves an immutable supplier AP due date from the settlement-method policy
 * and the supplier's positive {@code tday} override.
 *
 * <p>The recognition paths that call this service currently know only the
 * receipt/document date. Policies based on a later business event (IQC
 * acceptance, statement confirmation or invoice receipt) deliberately return
 * {@code null}; the later event must create its own scheduled payable instead
 * of guessing a due date at receipt posting time.</p>
 */
@Service
@RequiredArgsConstructor
public class SupplierPaymentTermService {

    private static final int MAX_DUE_DAYS = 3_650;
    private static final int MAX_MONTHS_AHEAD = 120;

    private final EntityManager em;

    /**
     * Resolve the due date while the caller owns the receipt/return posting
     * transaction. A missing settlement method means that no contractual due
     * date was selected, so the AP remains valid with a null due date.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public LocalDate resolveDueDate(
            UUID supplierId,
            UUID settlementMethodId,
            LocalDate receiptDate) {
        if (receiptDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "应付立账日期缺失，无法计算付款到期日");
        }
        if (settlementMethodId == null) {
            return null;
        }
        if (supplierId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "应付供应商缺失，无法计算付款到期日");
        }

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT method.system_role,
                               method.terms_base,
                               method.due_rule,
                               method.default_due_days,
                               method.fixed_day_of_month,
                               method.months_ahead,
                               supplier.tday
                        FROM suppliers supplier
                        JOIN settlement_methods method ON method.id = :methodId
                        WHERE supplier.id = :supplierId
                          AND COALESCE(supplier.is_deleted, false) = false
                          AND supplier.status = '使用'
                          AND COALESCE(method.is_deleted, false) = false
                          AND method.status = '使用'
                        FOR SHARE OF supplier, method
                        """)
                .setParameter("supplierId", supplierId)
                .setParameter("methodId", settlementMethodId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "供应商或结算方式不存在、已停用，无法计算付款到期日");
        }

        Object[] row = rows.getFirst();
        return calculateDueDate(
                receiptDate,
                text(row[0]),
                text(row[1]),
                text(row[2]),
                integer(row[3]),
                integer(row[4]),
                integer(row[5]),
                integer(row[6]));
    }

    static LocalDate calculateDueDate(
            LocalDate receiptDate,
            String systemRole,
            String termsBase,
            String dueRule,
            Integer defaultDueDays,
            Integer fixedDayOfMonth,
            Integer monthsAhead,
            Integer supplierDueDays) {
        if (receiptDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "应付立账日期缺失，无法计算付款到期日");
        }

        String normalizedRole = systemRole == null
                ? null : systemRole.trim().toUpperCase(Locale.ROOT);
        if ("CASH".equals(normalizedRole)) {
            return receiptDate;
        }

        String normalizedBase = requiredEnum(termsBase, "账期基准");
        String normalizedRule = switch (requiredEnum(dueRule, "到期规则")) {
            case "NET_DAYS" -> "NET_DAYS";
            case "EOM_PLUS_DAYS" -> "EOM_PLUS_DAYS";
            case "FIXED_DAY_OF_MONTH" -> "FIXED_DAY_OF_MONTH";
            default -> throw new ApiException(
                    ErrorCode.CONFLICT, "未知到期规则：" + dueRule.trim().toUpperCase(Locale.ROOT));
        };
        LocalDate baseDate = switch (normalizedBase) {
            case "RECEIPT_DATE" -> receiptDate;
            case "STATEMENT_END" -> receiptDate.with(TemporalAdjusters.lastDayOfMonth());
            case "QC_ACCEPTANCE_DATE", "STATEMENT_CONFIRM_DATE", "INVOICE_DATE" -> null;
            default -> throw new ApiException(
                    ErrorCode.CONFLICT, "未知账期基准：" + normalizedBase);
        };
        if (baseDate == null) {
            return null;
        }

        try {
            return switch (normalizedRule) {
                case "NET_DAYS" -> baseDate.plusDays(
                        effectiveDueDays(supplierDueDays, defaultDueDays));
                case "EOM_PLUS_DAYS" -> baseDate
                        .with(TemporalAdjusters.lastDayOfMonth())
                        .plusDays(effectiveDueDays(supplierDueDays, defaultDueDays));
                case "FIXED_DAY_OF_MONTH" -> fixedDayDueDate(
                        baseDate, fixedDayOfMonth, monthsAhead);
                default -> throw new ApiException(
                        ErrorCode.CONFLICT, "未知到期规则：" + normalizedRule);
            };
        } catch (DateTimeException | ArithmeticException ex) {
            throw new ApiException(ErrorCode.CONFLICT, "供应商账期超出有效日期范围");
        }
    }

    private static long effectiveDueDays(Integer supplierDueDays, Integer defaultDueDays) {
        Integer days = supplierDueDays != null && supplierDueDays > 0
                ? supplierDueDays
                : defaultDueDays;
        if (days == null || days < 0 || days > MAX_DUE_DAYS) {
            throw new ApiException(ErrorCode.CONFLICT, "结算方式缺少有效的到期天数配置");
        }
        return days.longValue();
    }

    private static LocalDate fixedDayDueDate(
            LocalDate baseDate,
            Integer fixedDayOfMonth,
            Integer monthsAhead) {
        if (fixedDayOfMonth == null || fixedDayOfMonth < 1 || fixedDayOfMonth > 31) {
            throw new ApiException(ErrorCode.CONFLICT, "固定付款日必须在 1 至 31 之间");
        }
        int ahead = monthsAhead == null ? 0 : monthsAhead;
        if (ahead < 0 || ahead > MAX_MONTHS_AHEAD) {
            throw new ApiException(ErrorCode.CONFLICT, "固定付款月偏移配置无效");
        }
        YearMonth targetMonth = YearMonth.from(baseDate).plusMonths(ahead);
        LocalDate candidate = targetMonth.atDay(
                Math.min(fixedDayOfMonth, targetMonth.lengthOfMonth()));
        if (candidate.isBefore(baseDate)) {
            targetMonth = targetMonth.plusMonths(1);
            candidate = targetMonth.atDay(
                    Math.min(fixedDayOfMonth, targetMonth.lengthOfMonth()));
        }
        return candidate;
    }

    private static String requiredEnum(String value, String label) {
        if (value == null || value.isBlank()) {
            throw new ApiException(ErrorCode.CONFLICT, "结算方式缺少" + label + "配置");
        }
        return value.trim().toUpperCase(Locale.ROOT);
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static Integer integer(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }
}
