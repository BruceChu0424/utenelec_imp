package com.uten.imp.common.time;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import java.time.LocalDate;
import java.time.MonthDay;
import java.util.List;
import java.util.Optional;
import java.util.TreeSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BirthMonthDayTest {

    @Test
    void parsesStoredMonthDayIncludingLeapDay() {
        assertEquals(Optional.of(MonthDay.of(10, 3)), BirthMonthDay.parse("10-03"));
        assertEquals(Optional.of(MonthDay.of(2, 29)), BirthMonthDay.parse(" 02-29 "));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"  ", "02-30", "13-01", "2-3", "1990-10-03", "10/03"})
    void blankOrImpossibleValuesAreTreatedAsNoBirthday(String value) {
        assertEquals(Optional.empty(), BirthMonthDay.parse(value));
        assertFalse(BirthMonthDay.isBirthdayOn(value, LocalDate.of(2027, 2, 28)));
    }

    @ParameterizedTest
    @CsvSource({
            // 非闰年：2/29 生日落到 2/28
            "02-29,2027-02-01,2027-02-28",
            "02-29,2027-02-28,2027-02-28",
            "02-29,2027-03-01,2028-02-29",
            "02-29,2028-02-28,2028-02-29",
            "10-03,2026-10-03,2026-10-03",
            "10-03,2026-10-04,2027-10-03",
            "01-01,2026-12-31,2027-01-01"
    })
    void nextOccurrenceRollsLeapDayToFeb28InCommonYears(String stored, String today, String expected) {
        MonthDay birthday = BirthMonthDay.parse(stored).orElseThrow();
        assertEquals(LocalDate.parse(expected), BirthMonthDay.nextOccurrence(birthday, LocalDate.parse(today)));
    }

    @Test
    void sqlMatchListAgreesWithInMemoryRuleForEveryDayOfCommonAndLeapYears() {
        List<String> allStored = new java.util.ArrayList<>();
        for (LocalDate d = LocalDate.of(2028, 1, 1); d.getYear() == 2028; d = d.plusDays(1)) {
            allStored.add(String.format("%02d-%02d", d.getMonthValue(), d.getDayOfMonth()));
        }
        for (int year : new int[] {2027, 2028}) {
            for (LocalDate day = LocalDate.of(year, 1, 1); day.getYear() == year; day = day.plusDays(1)) {
                LocalDate current = day;
                TreeSet<String> expected = new TreeSet<>(allStored.stream()
                        .filter(v -> BirthMonthDay.isBirthdayOn(v, current)).toList());
                assertEquals(expected, new TreeSet<>(BirthMonthDay.celebratedOn(day)), day.toString());
            }
        }
        assertEquals(List.of("02-28", "02-29"), BirthMonthDay.celebratedOn(LocalDate.of(2027, 2, 28)));
        assertEquals(List.of("02-28"), BirthMonthDay.celebratedOn(LocalDate.of(2028, 2, 28)));
        assertEquals(List.of("02-29"), BirthMonthDay.celebratedOn(LocalDate.of(2028, 2, 29)));
        assertTrue(BirthMonthDay.isBirthdayOn("02-29", LocalDate.of(2027, 2, 28)));
        assertFalse(BirthMonthDay.isBirthdayOn("02-29", LocalDate.of(2028, 2, 28)));
    }
}
