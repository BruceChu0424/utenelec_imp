package com.uten.imp.common.text;

import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class IntakeTextNormalizerTest {

    @Test
    void normalizePartUnifiesWidthCaseSpacesDashesAndTrailingDot() {
        assertThat(IntakeTextNormalizer.normalizePart(" gk-12z13a / 2 usb ")).isEqualTo("GK-12Z13A/2USB");
        assertThat(IntakeTextNormalizer.normalizePart("ＧＺ２３／Ｄ")).isEqualTo("GZ23/D");
        assertThat(IntakeTextNormalizer.normalizePart("K20AD—01.")).isEqualTo("K20AD-01");
        assertThat(IntakeTextNormalizer.normalizePart("Z13N－03")).isEqualTo("Z13N-03");
        assertThat(IntakeTextNormalizer.normalizePart(null)).isEmpty();
        // PostgreSQL 的 \s 认、Java 的 \s 不认的空白也要去掉; 结尾句点只看整串最末尾。
        assertThat(IntakeTextNormalizer.normalizePart("Z13N\u2028-03")).isEqualTo("Z13N-03");
        assertThat(IntakeTextNormalizer.normalizePart("Z13N\u1680-03")).isEqualTo("Z13N-03");
        assertThat(IntakeTextNormalizer.normalizePart("GZ23/D.\u2029")).isEqualTo("GZ23/D");
    }

    @Test
    void partVariantsStripKnownPrefixesButNeverTheSuffix() {
        Map<String, Integer> v = IntakeTextNormalizer.partVariants("G-M/D");
        assertThat(v).containsEntry("G-M/D", 0).containsEntry("M/D", -4);
        assertThat(IntakeTextNormalizer.partVariants("Q120-K20AD")).containsEntry("K20AD", -4);
        assertThat(IntakeTextNormalizer.partVariants("K20AD-01")).containsOnlyKeys("K20AD-01");
        assertThat(IntakeTextNormalizer.partVariants("")).isEmpty();
    }

    @Test
    void normalizeCnStripsOwnerPrefixOrdinalSeriesAndTypePrefix() {
        assertThat(IntakeTextNormalizer.normalizeCn("尼日利亚6M 单联双控", Set.of("6M"))).isEqualTo("单联双控");
        assertThat(IntakeTextNormalizer.normalizeCn("沙特二Z9 20A开关", Set.of("Z9"))).isEqualTo("20a开关");
        assertThat(IntakeTextNormalizer.normalizeCn("Q120德式插座压板", Set.of("Q120"))).isEqualTo("德式插座压板");
        assertThat(IntakeTextNormalizer.normalizeCn("86型一开单控", Set.of())).isEqualTo("一开单控");
        assertThat(IntakeTextNormalizer.ownerPrefix("尼日利亚6M 空白面板")).isEqualTo("尼日利亚");
        assertThat(IntakeTextNormalizer.ownerPrefix("Z9 空白面板")).isNull();
    }

    @Test
    void bracketQualifiersAreRemoved() {
        assertThat(IntakeTextNormalizer.stripBracketQualifiers("V7小二孔安全门弹簧（不锈钢）")).isEqualTo("V7小二孔安全门弹簧");
        assertThat(IntakeTextNormalizer.stripBracketQualifiers("电话插保护门 (杏色)")).isEqualTo("电话插保护门 ");
    }

    @Test
    void mixedLanguageCellIsSplitByLineAndScript() {
        IntakeTextNormalizer.ScriptSplit split =
                IntakeTextNormalizer.splitByScript("20A double pole switch swith light\n20A双极开关带灯");
        assertThat(split.latin()).isEqualTo("20A double pole switch swith light");
        assertThat(split.cjk()).isEqualTo("20A双极开关带灯");
        assertThat(IntakeTextNormalizer.isLatinDominant("DOUBLE 3 PIN UNIVERSAL SOCCKET")).isTrue();
        assertThat(IntakeTextNormalizer.isLatinDominant("两开多功能三极插座")).isFalse();
    }

    @Test
    void bigramDiceComparesChineseNames() {
        assertThat(IntakeTextNormalizer.bigramDice("一开13A带A+C 双USB", "Z9一开13A带A+C双USB")).isGreaterThan(0.7);
        assertThat(IntakeTextNormalizer.bigramDice("空白面板", "德式插座压板")).isLessThan(0.2);
        assertThat(IntakeTextNormalizer.bigramDice("开", "开关")).isZero();
    }

    @Test
    void descriptionNormalizationKeepsPlusSlashDash() {
        assertThat(IntakeTextNormalizer.normalizeDescription("  DOUBLE  13A SOCKET WITH SWITCH+ DOUBLE USB(Type A+Type C） "))
                .isEqualTo("double 13a socket with switch+ double usb type a+type c");
    }
}
