package com.uten.imp.common.time;

import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;

/**
 * 中国大陆业务日期语义。
 *
 * <p>数据库 {@code TIMESTAMPTZ}、Hibernate JDBC 和 JSON 线格式继续使用 UTC；
 * 只有“今天”“某业务日开始”等日历概念按 Asia/Shanghai 计算，避免依赖服务器所在时区。
 */
public final class BusinessTime {

    public static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");

    private BusinessTime() {}

    public static LocalDate today() {
        return LocalDate.now(ZONE);
    }

    public static OffsetDateTime startOfDay(LocalDate date) {
        return date.atStartOfDay(ZONE).toOffsetDateTime();
    }

    public static Instant startOfDayInstant(LocalDate date) {
        return date.atStartOfDay(ZONE).toInstant();
    }
}
