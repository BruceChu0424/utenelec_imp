package com.uten.imp.common.time;

import java.time.LocalDate;
import java.util.List;

/**
 * 入职周年 {@code employees.hire_date} 的统一判定口径。
 *
 * <p>HR 任务中心「今日周年」、庆典自动发布 {@code CelebrationScheduler}、本人「今日庆典」、
 * 手动 / 一键祝福派生的「入职N周年」一律按本类：第 N 个周年日 = {@code hireDate.plusYears(N)}，
 * 2/29 入职在非闰年按 2/28 过周年(与生日 {@link BirthMonthDay} 同一闰日规则)；满 1 年起才算周年。
 *
 * <p>年数不用 {@link java.time.Period#between} / PostgreSQL {@code age()}：两者对 2/29 入职在非闰年
 * 2/28 只算 N-1 年(差 1 天满月)，会出现「今天过周年，卡上却写 入职2周年」。
 */
public final class WorkAnniversary {

    private WorkAnniversary() {}

    /** {@code hireDate} 在 {@code day} 这天是否过入职周年(满 1 年起；2/29 入职非闰年按 2/28)。 */
    public static boolean isAnniversaryOn(LocalDate hireDate, LocalDate day) {
        if (hireDate == null || day == null) {
            return false;
        }
        int years = day.getYear() - hireDate.getYear();
        return years >= 1 && hireDate.plusYears(years).equals(day);
    }

    /**
     * 截至 {@code day} 已满的入职整年数：最大的 N 使 {@code hireDate.plusYears(N)} 不晚于 {@code day}。
     * 周年当天(含 2/29 入职的非闰年 2/28)即记满 N 年；{@code day} 不晚于入职日返回 0。
     */
    public static int completedYears(LocalDate hireDate, LocalDate day) {
        if (!day.isAfter(hireDate)) {
            return 0;
        }
        int years = day.getYear() - hireDate.getYear();
        return hireDate.plusYears(years).isAfter(day) ? years - 1 : years;
    }

    /**
     * 在 {@code day} 这天过入职周年的 hire_date 月日 'MM-DD'，供 SQL
     * {@code to_char(hire_date, 'MM-DD') IN (...)} 匹配：通常只有当天月日，非闰年 2/28 另含 '02-29'
     * (闰日规则与生日共用 {@link BirthMonthDay#celebratedOn})。「满 1 年」由调用方另加
     * {@code EXTRACT(YEAR FROM hire_date) < day 的年份}，两者合起来与 {@link #isAnniversaryOn} 同一口径。
     */
    public static List<String> celebratedOn(LocalDate day) {
        return BirthMonthDay.celebratedOn(day);
    }
}
