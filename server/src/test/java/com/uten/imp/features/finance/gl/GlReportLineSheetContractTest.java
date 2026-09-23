package com.uten.imp.features.finance.gl;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-112: 「同一张表里一个科目只能归一行」的表划分有两份实现——服务端 {@link GlReportLine#sheets()} 与
 * 库函数 fn_finance_report_line_sheet(默认补齐用, 按行键前缀)。这里锁定两者一致, 并锁定默认名单只落在可配置的科目行上。
 */
class GlReportLineSheetContractTest {

    @Test
    void everyStyleLineOfOneSheetSharesTheSheetPrefixUsedByTheDatabaseFunction() {
        List<String> prefixes = List.of("MFG_", "ADM_", "PROFIT", "OP_");
        List<List<GlReportLine>> sheets = GlReportLine.sheets();
        assertThat(sheets).hasSize(prefixes.size());
        for (int index = 0; index < sheets.size(); index++) {
            String prefix = prefixes.get(index);
            for (GlReportLine line : sheets.get(index)) {
                if (!line.configurable() || !"STYLE".equals(line.bindingKind())) continue;
                if ("PROFIT".equals(prefix)) {
                    assertThat(line.key()).isIn("PL_TAX", "SALES_FEE", "PL_FINANCE");
                } else {
                    assertThat(line.key()).as("表 %s 的科目行", prefix).startsWith(prefix);
                }
            }
        }
    }

    @Test
    void siblingsAreOtherStyleLinesOfTheSameSheetOnly() {
        assertThat(GlReportLine.styleSiblings("ADM_OFFICE")).contains("ADM_RENT").doesNotContain("ADM_OFFICE", "OP_OFFICE");
        assertThat(GlReportLine.styleSiblings("MFG_DEPRECIATION")).contains("MFG_OTHER");
        assertThat(GlReportLine.styleSiblings("SALES_FEE")).containsExactlyInAnyOrder("PL_TAX", "PL_FINANCE");
        assertThat(GlReportLine.styleSiblings("LABOR_DIRECT")).as("人工行绑部门, 不参与科目互斥")
                .doesNotContain("LABOR_DIRECT", "LABOR_INDIRECT");
    }

    @Test
    void defaultNamesOnlyTargetConfigurableStyleLines() throws Exception {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/V665__finance_report_line_bindings.sql"));
        String values = migration.substring(migration.indexOf("FROM (VALUES"), migration.indexOf(") AS defaults"));
        Set<String> keys = new TreeSet<>();
        var matcher = java.util.regex.Pattern.compile("\\('([A-Z_]+)', '").matcher(values);
        while (matcher.find()) keys.add(matcher.group(1));
        assertThat(keys).isNotEmpty();
        for (String key : keys) {
            GlReportLine line = GlReportLine.configurable(key);
            assertThat(line).as("默认名单里的行 %s 必须是可配置行", key).isNotNull();
            assertThat(line.source()).as("默认名单只落在科目行(人工/折旧行不猜): %s", key)
                    .isEqualTo(GlReportLine.Source.STYLES);
        }
    }
}
