package com.uten.imp.common.time;

import java.time.LocalDate;
import java.time.MonthDay;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Optional;

/**
 * 生日月日 {@code employees.birth_month_day}('MM-DD'，不含年份)的统一判定口径。
 *
 * <p>V282 起出生日期只存密文 {@code employee_sensitive.birth_date_enc}，明文
 * {@code employees.birth_date} 恒为 NULL(写入被触发器拒绝)。HR 任务中心生日提醒、
 * 庆典自动发布、本人「今日庆典」一律按本类匹配：2/29 生日在非闰年按 2/28 庆祝
 * ({@link MonthDay#atYear} 语义)。
 */
public final class BirthMonthDay {

    private static final MonthDay LEAP_DAY = MonthDay.of(2, 29);

    private BirthMonthDay() {}

    /** 'MM-DD' → MonthDay；空值、格式错或不存在的月日(如 02-30)返回 empty，调用方按「未登记生日」跳过。 */
    public static Optional<MonthDay> parse(String value) {
        if (value == null || value.isBlank()) {
            return Optional.empty();
        }
        try {
            return Optional.of(MonthDay.parse("--" + value.trim()));
        } catch (DateTimeParseException e) {
            return Optional.empty();
        }
    }

    /** 下一次庆祝日(今天也算)；2/29 在非闰年落到 2/28。 */
    public static LocalDate nextOccurrence(MonthDay birthday, LocalDate today) {
        LocalDate thisYear = birthday.atYear(today.getYear());
        return thisYear.isBefore(today) ? birthday.atYear(today.getYear() + 1) : thisYear;
    }

    /** 该 birth_month_day 是否在 {@code day} 这天过生日。 */
    public static boolean isBirthdayOn(String birthMonthDay, LocalDate day) {
        return parse(birthMonthDay).map(md -> md.atYear(day.getYear()).equals(day)).orElse(false);
    }

    /**
     * 在 {@code day} 这天过生日的全部 birth_month_day 取值，供 SQL {@code IN (...)} 匹配：
     * 通常只有当天月日；非闰年 2/28 另含 '02-29'。与 {@link #isBirthdayOn} 同一口径。
     */
    public static List<String> celebratedOn(LocalDate day) {
        String own = format(MonthDay.from(day));
        return LEAP_DAY.atYear(day.getYear()).equals(day) && !day.isLeapYear()
                ? List.of(own, format(LEAP_DAY))
                : List.of(own);
    }

    private static String format(MonthDay md) {
        return String.format("%02d-%02d", md.getMonthValue(), md.getDayOfMonth());
    }
}
