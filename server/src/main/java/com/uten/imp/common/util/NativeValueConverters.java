package com.uten.imp.common.util;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

/**
 * JPA 原生查询 / JDBC 结果集中日期、时间、数值列的健壮转换。
 *
 * <p>驱动（pgjdbc）与 Hibernate 版本不同，同一列可能返回不同的 Java 类型：
 * DATE 列可能是 {@link LocalDate} 或 {@link java.sql.Date}；TIMESTAMPTZ 列可能是
 * {@link OffsetDateTime}、{@link Instant}、{@link java.sql.Timestamp} 或
 * {@link java.util.Date}；NUMERIC 列一般是 {@link BigDecimal}，但聚合/表达式列可能
 * 退化为其它 {@link Number}。对结果直接强转会在环境变化时抛 {@link ClassCastException}
 * （典型案例：采购待检单列表 received_at 列返回 Instant）。统一走这里的转换方法。
 */
public final class NativeValueConverters {

    private NativeValueConverters() {
    }

    /** DATE 列 → LocalDate；无法识别时退化为 toString 解析，仍不行返回 null。 */
    public static LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        if (value instanceof java.sql.Timestamp timestamp) return timestamp.toLocalDateTime().toLocalDate();
        if (value instanceof java.util.Date date) {
            return date.toInstant().atZone(ZoneOffset.UTC).toLocalDate();
        }
        try {
            return LocalDate.parse(value.toString());
        } catch (RuntimeException ex) {
            return null;
        }
    }

    /** TIMESTAMPTZ 列 → OffsetDateTime（统一归一到 UTC 偏移）。 */
    public static OffsetDateTime toOffsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime offset) return offset;
        if (value instanceof Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        if (value instanceof java.util.Date date) {
            return date.toInstant().atOffset(ZoneOffset.UTC);
        }
        if (value instanceof LocalDateTime localDateTime) {
            return localDateTime.atOffset(ZoneOffset.UTC);
        }
        try {
            return OffsetDateTime.parse(value.toString());
        } catch (RuntimeException ex) {
            return null;
        }
    }

    /** TIMESTAMPTZ 列 → Instant。 */
    public static Instant toInstant(Object value) {
        if (value == null) return null;
        if (value instanceof Instant instant) return instant;
        if (value instanceof OffsetDateTime offset) return offset.toInstant();
        if (value instanceof java.util.Date date) return date.toInstant();
        if (value instanceof LocalDateTime localDateTime) {
            return localDateTime.toInstant(ZoneOffset.UTC);
        }
        try {
            return Instant.parse(value.toString());
        } catch (RuntimeException ex) {
            return null;
        }
    }

    /** NUMERIC 列 → BigDecimal（null 归一为 ZERO；其它 Number/字符串走 toString 解析）。 */
    public static BigDecimal toBigDecimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        if (value instanceof Number || value instanceof CharSequence) {
            return new BigDecimal(value.toString());
        }
        throw new IllegalArgumentException("无法转换为 BigDecimal: " + value.getClass());
    }
}
