package com.uten.imp.common.time;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.time.LocalDate;
import java.time.Period;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class WorkAnniversaryTest {

    @ParameterizedTest
    @CsvSource({
            // 2/29 入职：非闰年 2/28 过周年，闰年等到 2/29
            "2024-02-29,2027-02-28,true",
            "2024-02-29,2027-03-01,false",
            "2024-02-29,2028-02-28,false",
            "2024-02-29,2028-02-29,true",
            "2024-02-29,2025-02-28,true",
            // 普通入职日：月日相同且满 1 年
            "2020-02-28,2027-02-28,true",
            "2020-02-28,2028-02-28,true",
            "2020-02-28,2028-02-29,false",
            "2021-10-05,2026-10-05,true",
            "2021-10-05,2026-10-04,false",
            // 入职当天 / 入职日之前都不算周年
            "2026-10-05,2026-10-05,false",
            "2028-02-29,2028-02-29,false",
            "2027-02-28,2026-02-28,false"
    })
    void anniversaryFallsOnFeb28InCommonYearsForLeapDayHires(String hire, String day, boolean expected) {
        assertEquals(expected, WorkAnniversary.isAnniversaryOn(LocalDate.parse(hire), LocalDate.parse(day)));
    }

    @Test
    void missingHireDateIsNeverAnAnniversary() {
        assertFalse(WorkAnniversary.isAnniversaryOn(null, LocalDate.of(2027, 2, 28)));
    }

    @ParameterizedTest
    @CsvSource({
            // 2/29 入职在非闰年 2/28 即满 N 年(Period.between / PostgreSQL age() 此日只算 N-1)
            "2024-02-29,2027-02-27,2",
            "2024-02-29,2027-02-28,3",
            "2024-02-29,2027-03-01,3",
            "2024-02-29,2028-02-28,3",
            "2024-02-29,2028-02-29,4",
            "2024-02-29,2025-02-28,1",
            "2020-02-28,2027-02-28,7",
            "2021-10-05,2026-10-04,4",
            "2021-10-05,2026-10-05,5",
            "2026-10-05,2026-10-05,0",
            "2026-10-05,2026-12-31,0",
            "2026-10-05,2026-01-01,0"
    })
    void completedYearsCountTheLeapDayAnniversaryOnFeb28(String hire, String day, int expected) {
        assertEquals(expected, WorkAnniversary.completedYears(LocalDate.parse(hire), LocalDate.parse(day)));
    }

    @Test
    void completedYearsDiffersFromPeriodBetweenOnlyForLeapDayHiresOnCommonYearFeb28() {
        List<LocalDate> hires = new ArrayList<>();
        for (LocalDate d = LocalDate.of(2020, 1, 1); d.getYear() == 2020; d = d.plusDays(1)) {
            hires.add(d);
        }
        for (LocalDate hire : hires) {
            for (LocalDate day = LocalDate.of(2026, 1, 1); day.getYear() <= 2028; day = day.plusDays(1)) {
                int ours = WorkAnniversary.completedYears(hire, day);
                int period = Period.between(hire, day).getYears();
                boolean leapEdge = hire.getMonthValue() == 2 && hire.getDayOfMonth() == 29
                        && day.getMonthValue() == 2 && day.getDayOfMonth() == 28 && !day.isLeapYear();
                assertEquals(leapEdge ? period + 1 : period, ours, hire + " -> " + day);
            }
        }
    }

    @Test
    void sqlMatchListAgreesWithInMemoryRuleForEveryHireMonthDayOfCommonAndLeapYears() {
        // 每个可能的入职月日(取闰年 2020 覆盖 2/29)在 2027(非闰) / 2028(闰) 每一天：
        // SQL 侧 to_char(hire_date,'MM-DD') IN celebratedOn(day) 且入职年份 < 当年 == isAnniversaryOn
        for (int year : new int[] {2027, 2028}) {
            for (LocalDate day = LocalDate.of(year, 1, 1); day.getYear() == year; day = day.plusDays(1)) {
                List<String> sqlMonthDays = WorkAnniversary.celebratedOn(day);
                for (LocalDate hire = LocalDate.of(2020, 1, 1); hire.getYear() == 2020; hire = hire.plusDays(1)) {
                    String hireMonthDay = String.format("%02d-%02d", hire.getMonthValue(), hire.getDayOfMonth());
                    boolean sql = sqlMonthDays.contains(hireMonthDay) && hire.getYear() < day.getYear();
                    assertEquals(WorkAnniversary.isAnniversaryOn(hire, day), sql, hire + " -> " + day);
                }
            }
        }
        assertEquals(List.of("02-28", "02-29"), WorkAnniversary.celebratedOn(LocalDate.of(2027, 2, 28)));
        assertEquals(List.of("02-28"), WorkAnniversary.celebratedOn(LocalDate.of(2028, 2, 28)));
        assertTrue(WorkAnniversary.isAnniversaryOn(LocalDate.of(2024, 2, 29), LocalDate.of(2027, 2, 28)));
    }
}
