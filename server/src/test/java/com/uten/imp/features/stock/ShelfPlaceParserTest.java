package com.uten.imp.features.stock;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThat;

/** 库位号「库行-层-位」三段解析规则（Java 侧 DTO 真值；SQL 侧同一 pattern 用于筛选/排序/布局）。 */
class ShelfPlaceParserTest {

    @Test
    void parsesThreeSegmentPlaceIntoRackLevelSlot() {
        var p = ShelfPlaceParser.parse("A31-3-1");
        assertThat(p.parsed()).isTrue();
        assertThat(p.rack()).isEqualTo("A31");
        assertThat(p.level()).isEqualTo(3);
        assertThat(p.slot()).isEqualTo(1);
    }

    @Test
    void trimsWhitespaceKeepsRackCaseAndAcceptsDigitOnlyRack() {
        var padded = ShelfPlaceParser.parse("  a30-12-9 ");
        assertThat(padded.parsed()).isTrue();
        assertThat(padded.rack()).isEqualTo("a30");
        assertThat(padded.level()).isEqualTo(12);
        assertThat(padded.slot()).isEqualTo(9);

        var digits = ShelfPlaceParser.parse("30-1-2");
        assertThat(digits.parsed()).isTrue();
        assertThat(digits.rack()).isEqualTo("30");
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "19",            // 老库残值
            "Y12",           // 老库残值（字母+数字，无分隔）
            "A30-1",         // 两段式
            "A30-1-2-3",     // 四段式
            "A-1-1",         // 库行无数字
            "A30-x-1",       // 层非数字
            "A30-1234567-1", // 层超过 6 位
            "A30-1-1234567", // 位超过 6 位
            "A30--1",        // 空段
            "A30-1-",        // 尾空段
            "   ",
            ""
    })
    void anythingElseIsUnparsedWithEmptyRackAndNullLevelSlot(String raw) {
        var p = ShelfPlaceParser.parse(raw);
        assertThat(p.parsed()).isFalse();
        assertThat(p.rack()).isEmpty();
        assertThat(p.level()).isNull();
        assertThat(p.slot()).isNull();
    }

    @Test
    void nullIsUnparsed() {
        assertThat(ShelfPlaceParser.parse(null).parsed()).isFalse();
    }

    @Test
    void sixDigitSegmentsAreTheUpperBound() {
        assertThat(ShelfPlaceParser.parse("A30-999999-999999").parsed()).isTrue();
        assertThat(ShelfPlaceParser.parse("A30-1000000-1").parsed()).isFalse();
    }

    @Test
    void sqlPatternAndDigitCapAreEmbeddedInEveryShelfQuery() {
        for (String sql : new String[] {
                ShelfLabelSql.rows(false, false, false, false),
                ShelfLabelSql.rows(true, true, true, true),
                ShelfLabelSql.racks(false, false),
                ShelfLabelSql.layout(true, false)}) {
            assertThat(sql)
                    .contains("~ '" + ShelfPlaceParser.SQL_PATTERN + "'")
                    .contains("length(split_part(base.place, '-', 2)) <= " + ShelfPlaceParser.MAX_DIGITS)
                    .contains("length(split_part(base.place, '-', 3)) <= " + ShelfPlaceParser.MAX_DIGITS)
                    .doesNotContain("{");
        }
    }
}
