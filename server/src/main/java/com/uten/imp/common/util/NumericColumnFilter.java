package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.function.BiConsumer;
import java.util.regex.Pattern;

/** Exact decimal header query shared by server-owned table filters. */
public record NumericColumnFilter(String operator, BigDecimal lower, BigDecimal upper) {
    private static final String DECIMAL = "[+-]?[0-9]+(?:\\.[0-9]+)?";
    private static final Pattern COMPARISON = Pattern.compile("^(<=|>=|!=|=|<|>)?\\s*(" + DECIMAL + ")$");
    private static final Pattern RANGE = Pattern.compile("^(" + DECIMAL + ")\\s*\\.\\.\\s*(" + DECIMAL + ")$");

    public static NumericColumnFilter parse(String input) {
        if (input == null) throw invalid();
        String value = input.strip();
        if (value.length() > 128 || value.contains("...")) throw invalid();
        var range = RANGE.matcher(value);
        if (range.matches()) {
            BigDecimal lower = new BigDecimal(range.group(1));
            BigDecimal upper = new BigDecimal(range.group(2));
            if (lower.compareTo(upper) > 0) throw invalid();
            return new NumericColumnFilter("BETWEEN", lower, upper);
        }
        var comparison = COMPARISON.matcher(value);
        if (!comparison.matches()) throw invalid();
        return new NumericColumnFilter(comparison.group(1) == null ? "=" : comparison.group(1),
                new BigDecimal(comparison.group(2)), null);
    }

    /** The expression and parameter name must come from the caller's fixed whitelist. */
    public String sql(String expression, String parameter) {
        return upper == null ? expression + " " + operator + " :" + parameter
                : expression + " BETWEEN :" + parameter + "_lower AND :" + parameter + "_upper";
    }

    public void bind(String parameter, BiConsumer<String, BigDecimal> binder) {
        if (upper == null) binder.accept(parameter, lower);
        else {
            binder.accept(parameter + "_lower", lower);
            binder.accept(parameter + "_upper", upper);
        }
    }

    /** Same exact-decimal contract for fully authorized in-memory/cursor rows. */
    public boolean matches(BigDecimal value) {
        if (value == null) return false;
        int comparison = value.compareTo(lower);
        if (upper != null) return comparison >= 0 && value.compareTo(upper) <= 0;
        return switch (operator) {
            case "=" -> comparison == 0;
            case "!=" -> comparison != 0;
            case ">" -> comparison > 0;
            case ">=" -> comparison >= 0;
            case "<" -> comparison < 0;
            case "<=" -> comparison <= 0;
            default -> throw invalid();
        };
    }

    public jakarta.persistence.criteria.Predicate predicate(jakarta.persistence.criteria.CriteriaBuilder builder,
            jakarta.persistence.criteria.Expression<BigDecimal> field) {
        if (upper != null) return builder.between(field, lower, upper);
        return switch (operator) {
            case "=" -> builder.equal(field, lower);
            case "!=" -> builder.notEqual(field, lower);
            case ">" -> builder.greaterThan(field, lower);
            case ">=" -> builder.greaterThanOrEqualTo(field, lower);
            case "<" -> builder.lessThan(field, lower);
            case "<=" -> builder.lessThanOrEqualTo(field, lower);
            default -> throw invalid();
        };
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                "数值筛选请输入数字、比较条件（如 >=0）或范围（如 -10..0）");
    }
}
