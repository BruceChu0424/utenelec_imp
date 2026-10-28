package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.Year;
import java.time.YearMonth;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Typed column searches run inside the owning read predicate, before count and pagination. */
public final class JpaColumnSearch {
    private static final ZoneId BUSINESS_ZONE = ZoneId.of("Asia/Shanghai");
    private JpaColumnSearch() { }

    public enum Kind { TEXT, DECIMAL, INSTANT, DATE }

    @FunctionalInterface
    public interface ExpressionBuilder {
        Expression<?> build(Root<?> root, CriteriaQuery<?> query, CriteriaBuilder cb);
    }

    /** Property paths and expression builders are application constants, never request values. */
    public record Field(Kind kind, ExpressionBuilder expression) {
        public static Field text(String property) { return text((root, query, cb) -> root.get(property)); }
        public static Field text(ExpressionBuilder builder) { return new Field(Kind.TEXT, builder); }
        public static Field decimal(String property) { return new Field(Kind.DECIMAL, (root, query, cb) -> root.get(property)); }
        public static Field decimal(ExpressionBuilder builder) { return new Field(Kind.DECIMAL, builder); }
        public static Field instant(String property) { return new Field(Kind.INSTANT, (root, query, cb) -> root.get(property)); }
        public static Field calendarDate(String property) { return new Field(Kind.DATE, (root, query, cb) -> root.get(property)); }
        public static Field referenceText(String key, Class<?> type, String name) {
            return referenceText(key, type, name, null);
        }
        public static Field referenceText(String key, Class<?> type, String name, String fallback) {
            return text((root, query, cb) -> {
                var reference = query.subquery(String.class);
                var target = reference.from(type);
                reference.select(target.get(name)).where(cb.equal(target.get("id"), root.get(key)));
                return fallback == null ? reference : cb.coalesce(reference, root.get(fallback));
            });
        }
    }

    public static Map<String, String> validate(Map<String, String> values, Map<String, Field> fields) {
        var validated = ColumnKeywordSearch.validate(values, fields.keySet());
        validated.forEach((key, value) -> {
            switch (fields.get(key).kind()) {
                case DECIMAL -> NumericColumnFilter.parse(value);
                case INSTANT, DATE -> businessDateBounds(value);
                default -> { }
            }
        });
        return validated;
    }

    @SuppressWarnings("unchecked")
    public static Predicate predicate(Root<?> root, CriteriaQuery<?> query, CriteriaBuilder cb,
                                      Map<String, String> searches, Map<String, Field> fields) {
        List<Predicate> result = new ArrayList<>();
        validate(searches, fields).forEach((key, value) -> {
            Field field = fields.get(key);
            Expression<?> expression = field.expression().build(root, query, cb);
            switch (field.kind()) {
                case TEXT -> {
                    for (String term : KeywordSearch.terms(value)) {
                        result.add(NameRefKeyword.text(cb, (Expression<String>) expression, NameRefKeyword.like(term)));
                    }
                }
                case DECIMAL -> {
                    NumericColumnFilter parsed = NumericColumnFilter.parse(value);
                    Expression<BigDecimal> number = (Expression<BigDecimal>) expression;
                    result.add(parsed.predicate(cb, number));
                }
                case INSTANT -> {
                    DateBounds range = businessDateBounds(value);
                    if (java.time.Instant.class.equals(expression.getJavaType())) {
                        Expression<java.time.Instant> timestamp = (Expression<java.time.Instant>) expression;
                        result.add(cb.greaterThanOrEqualTo(timestamp, range.from().toInstant()));
                        result.add(cb.lessThan(timestamp, range.toExclusive().toInstant()));
                    } else {
                        Expression<OffsetDateTime> timestamp = (Expression<OffsetDateTime>) expression;
                        result.add(cb.greaterThanOrEqualTo(timestamp, range.from()));
                        result.add(cb.lessThan(timestamp, range.toExclusive()));
                    }
                }
                case DATE -> {
                    DateBounds range = businessDateBounds(value);
                    Expression<LocalDate> date = (Expression<LocalDate>) expression;
                    result.add(cb.greaterThanOrEqualTo(date, range.from().toLocalDate()));
                    result.add(cb.lessThan(date, range.toExclusive().toLocalDate()));
                }
            }
        });
        return cb.and(result.toArray(new Predicate[0]));
    }

    public record DateBounds(OffsetDateTime from, OffsetDateTime toExclusive) { }

    /** A calendar prefix or inclusive date interval, interpreted in the company's business timezone. */
    public static DateBounds businessDateBounds(String value) {
        try {
            if (value == null || value.strip().isEmpty() || value.strip().length() > 128)
                throw new DateTimeParseException("date", value == null ? "" : value, 0);
            String[] parts = value.strip().split("\\.\\.", -1);
            if (parts.length > 2 || parts[0].isBlank()) throw new DateTimeParseException("range", value, 0);
            LocalDate from = dateStart(parts[0]);
            LocalDate to = dateEnd(parts.length == 2 ? parts[1] : parts[0]);
            if (!from.isBefore(to)) throw new DateTimeParseException("range", value, 0);
            return new DateBounds(from.atStartOfDay(BUSINESS_ZONE).toOffsetDateTime(),
                    to.atStartOfDay(BUSINESS_ZONE).toOffsetDateTime());
        } catch (DateTimeParseException | ArithmeticException failure) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "日期筛选请输入 YYYY、YYYY-MM、YYYY-MM-DD 或范围（如 2026-10-01..2026-10-31）");
        }
    }

    private static LocalDate dateStart(String value) {
        String text = value.strip();
        if (text.matches("[0-9]{4}")) return Year.parse(text).atDay(1);
        if (text.matches("[0-9]{4}-[0-9]{2}")) return YearMonth.parse(text).atDay(1);
        if (!text.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) throw new DateTimeParseException("date", text, 0);
        return LocalDate.parse(text);
    }

    private static LocalDate dateEnd(String value) {
        String text = value.strip();
        if (text.matches("[0-9]{4}")) return Year.parse(text).plusYears(1).atDay(1);
        if (text.matches("[0-9]{4}-[0-9]{2}")) return YearMonth.parse(text).plusMonths(1).atDay(1);
        if (!text.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) throw new DateTimeParseException("date", text, 0);
        return LocalDate.parse(text).plusDays(1);
    }
}
