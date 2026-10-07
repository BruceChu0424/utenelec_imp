package com.uten.imp.common.util;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

/**
 * JPA 原生查询 / JDBC 结果集中日期、时间、数值、UUID、文本列的健壮转换。
 *
 * <p>驱动（pgjdbc）与 Hibernate 版本不同，同一列可能返回不同的 Java 类型：
 * DATE 列可能是 {@link LocalDate} 或 {@link java.sql.Date}；TIMESTAMPTZ 列可能是
 * {@link OffsetDateTime}、{@link Instant}、{@link java.sql.Timestamp} 或
 * {@link java.util.Date}；NUMERIC 列一般是 {@link BigDecimal}，但聚合/表达式列可能
 * 退化为其它 {@link Number}。对结果直接强转会在环境变化时抛 {@link ClassCastException}
 * （典型案例：采购待检单列表 received_at 列返回 Instant）。统一走这里的转换方法。
 *
 * <p>新代码必须使用本类，不得再在 Service 里新建 private static 转换副本；
 * 存量域（production、subcontract、stock、purchase、sales、master、common 等）
 * 的私有副本按域渐进迁移，清单见 docs/05-架构《后端原生SQL行映射助手使用说明》。
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

    /**
     * UUID 列（或字符形式 UUID）→ UUID；null 返回 null。
     *
     * <p>语义（与全仓各 Service 私有 {@code uuid(Object)} 副本的主流实现一致）：
     * {@link UUID} 实例直接返回；其余走 {@code UUID.fromString(value.toString())}。
     * 个别旧副本仅做 {@code (UUID) value} 强转、不接受字符形式——本方法是其健壮性超集，
     * 对原本成功的输入（null / UUID 实例）结果一致。
     */
    public static UUID uuid(Object value) {
        if (value == null) return null;
        if (value instanceof UUID id) return id;
        return UUID.fromString(value.toString());
    }

    /**
     * 文本列 → String；null 返回 null，其余返回 {@code value.toString()}。
     *
     * <p>注意与少数私有副本的分歧：个别副本在 null 时返回 {@code ""}（如
     * warehouse/inbound 的 {@code str(Object)}）而非 null——那些副本语义不同，
     * 不得迁移到本方法。需要空串语义的调用点请自行 {@code Objects.toString(value, "")}。
     */
    public static String text(Object value) {
        return value == null ? null : value.toString();
    }

    /**
     * 布尔列 → boolean。null / 非布尔值按字符串解析：Boolean 实例直接返回，
     * 其余（含 null，即 "null"）走 {@code Boolean.parseBoolean(String.valueOf(value))}，
     * 因此 null 与无法识别的文本统一为 false。
     */
    public static boolean booleanValue(Object value) {
        if (value instanceof Boolean flag) return flag;
        return Boolean.parseBoolean(String.valueOf(value));
    }

    /**
     * 配套字符串规整：null / 空白串返回 null，其余去首尾空白。
     *
     * <p>虽然不属于"原生行取值"，但各 Service 私有 {@code trimToNull(String)} 副本
     * 语义完全一致（主流为 {@code trim()}；个别副本用 {@code strip()} 处理 Unicode
     * 空白，属可忽略分歧），故一并公共化。
     */
    public static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }
}
