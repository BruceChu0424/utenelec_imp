package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid;

import java.util.Collections;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;

/**
 * 一个工作表的明细表版式: 表头在哪一行、每列是什么。
 *
 * @param headerRow0    表头第一行(从 0 开始)
 * @param headerRowSpan 表头占几行(英文一行 + 中文一行的表头为 2)
 * @param roles         列号(从 0 开始) → 角色
 * @param headerTexts   规范化的表头文字(指纹原文; 多行表头用换行分隔)
 * @param fingerprint   headerTexts 的 SHA-256(64 位小写十六进制)
 * @param source        LEARNED / RULES / AI
 * @param fileCurrency  表头里写明的币种(CNY/USD/EUR/HKD), 没有为 null
 * @param headerUnit    表头里写明的数量单位(如 order qty(pcs) → pcs), 没有为 null
 * @param score         规则打分(认出的不同角色数)
 */
record IntakeLayout(int headerRow0, int headerRowSpan, Map<Integer, ColumnRole> roles, String headerTexts,
                    String fingerprint, String source, String fileCurrency, String headerUnit, int score) {

    static final String SOURCE_LEARNED = "LEARNED";
    static final String SOURCE_RULES = "RULES";
    static final String SOURCE_AI = "AI";

    IntakeLayout {
        roles = Collections.unmodifiableMap(new TreeMap<>(roles));
    }

    /** 第一个数据行(从 0 开始)。 */
    int firstDataRow0() {
        return headerRow0 + headerRowSpan;
    }

    /** 某角色所在列; 没有返回 -1。 */
    int column(ColumnRole role) {
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            if (e.getValue() == role) {
                return e.getKey();
            }
        }
        return -1;
    }

    boolean has(ColumnRole role) {
        return column(role) >= 0;
    }

    /** 结果与学习用: 列字母 → 角色名(不含 IGNORED)。 */
    Map<String, String> columnRolesByLetter() {
        Map<String, String> out = new LinkedHashMap<>();
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            if (e.getValue() != ColumnRole.IGNORED) {
                out.put(DocumentGrid.columnLetter(e.getKey()), e.getValue().name());
            }
        }
        return out;
    }

    /** 每个角色一列的反查表。 */
    Map<ColumnRole, Integer> columnsByRole() {
        Map<ColumnRole, Integer> out = new EnumMap<>(ColumnRole.class);
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            out.putIfAbsent(e.getValue(), e.getKey());
        }
        return out;
    }
}
