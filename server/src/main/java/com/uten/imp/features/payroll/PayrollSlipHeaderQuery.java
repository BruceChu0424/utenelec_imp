package com.uten.imp.features.payroll;

import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.NumericColumnFilter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.springframework.data.domain.Sort;
import java.util.Map;
import java.util.List;
import java.util.LinkedHashMap;
import java.time.Instant;

/** Reads already-booked CNY facts; never recalculates wages or changes a slip's state. */
record PayrollSlipHeaderQuery(String sort, String order, Map<String, String> filters) {
    private static final Map<String, String> MONEY = Map.of("grossIncome", "grossIncome", "totalDeduction", "totalDeduction", "netIncome", "netIncome");

    PayrollSlipHeaderQuery {
        Map<String, String> safe = new LinkedHashMap<>();
        if (filters != null) filters.forEach((key, raw) -> {
            if (!key.startsWith("search.")) return;
            String column = key.substring(7);
            if (!MONEY.containsKey(column) && !"period".equals(column) && !"publishedAt".equals(column)) throw invalid();
            if (raw == null || raw.isBlank()) return;
            String value = raw.strip();
            if (MONEY.containsKey(column)) NumericColumnFilter.parse(value);
            else if ("publishedAt".equals(column)) JpaColumnSearch.businessDateBounds(value);
            else period(value);
            safe.put(key, value);
        });
        if (sort != null && !sort.isBlank() && !MONEY.containsKey(sort) && !"period".equals(sort) && !"publishedAt".equals(sort)) throw invalid();
        if (order != null && !java.util.Set.of("asc", "desc").contains(order.toLowerCase(java.util.Locale.ROOT))) throw invalid();
        filters = Map.copyOf(safe);
    }

    void apply(Root<PayrollSlip> root, CriteriaBuilder builder, List<Predicate> predicates) {
        filters.forEach((key, value) -> {
            String column = key.substring(7);
            if (MONEY.containsKey(column)) predicates.add(NumericColumnFilter.parse(value).predicate(builder, root.get(MONEY.get(column))));
            else if ("publishedAt".equals(column)) {
                var range = JpaColumnSearch.businessDateBounds(value);
                predicates.add(builder.greaterThanOrEqualTo(root.<Instant>get("publishedAt"), range.from().toInstant()));
                predicates.add(builder.lessThan(root.<Instant>get("publishedAt"), range.toExclusive().toInstant()));
            } else {
                var period = period(value);
                predicates.add(builder.equal(root.get("payrollYear"), period[0]));
                if (period.length > 1) predicates.add(builder.equal(root.get("payrollMonth"), period[1]));
            }
        });
    }

    Sort sorting() {
        if (sort == null || sort.isBlank()) return Sort.by(Sort.Order.desc("payrollYear"), Sort.Order.desc("payrollMonth"), Sort.Order.asc("employeeCodeSnapshot"), Sort.Order.asc("id"));
        Sort.Direction direction = "desc".equalsIgnoreCase(order) ? Sort.Direction.DESC : Sort.Direction.ASC;
        if ("period".equals(sort)) return Sort.by(new Sort.Order(direction, "payrollYear"), new Sort.Order(direction, "payrollMonth"), Sort.Order.asc("employeeCodeSnapshot"), Sort.Order.asc("id"));
        return Sort.by(new Sort.Order(direction, MONEY.getOrDefault(sort, "publishedAt")), Sort.Order.desc("payrollYear"), Sort.Order.desc("payrollMonth"), Sort.Order.asc("id"));
    }

    private static Short[] period(String value) {
        if (value.length() > 20) throw invalid();
        var match = java.util.regex.Pattern.compile("^([0-9]{4})(?:(?:-|年)([0-9]{1,2})月?)?$").matcher(value);
        if (!match.matches()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "工资期间请输入年份或年月，例如 2026、2026-10");
        int year = Integer.parseInt(match.group(1));
        Short normalizedYear = PayrollService.normalizeYear(year);
        return match.group(2) == null ? new Short[]{normalizedYear}
                : new Short[]{normalizedYear, PayrollService.normalizeMonth(Integer.parseInt(match.group(2)))};
    }

    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "工资条表头查询条件无效"); }
}
