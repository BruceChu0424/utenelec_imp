package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.math.BigDecimal;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 客户文件里的数字解析: 「1,800」「US$1.10」「¥21」「1.800,50」「37 800 pcs」都要能读出来。
 * 只做精确解析(BigDecimal 字符串构造), 不做任何舍入。
 */
final class IntakeNumbers {

    private static final Pattern NUMBER_TOKEN = Pattern.compile("-?\\d[\\d,.\\s']*");
    private static final Pattern CURRENCY_NOISE = Pattern.compile(
            "(?i)(US\\$|HK\\$|RMB|CNY|USD|EUR|HKD|GBP|\\$|¥|￥|€|£|元|美元|美金|人民币)");

    private IntakeNumbers() {
    }

    /** 单元格数字: 数值型直接用, 文字型按文本解析; 解析不出返回 null。 */
    static BigDecimal of(Cell cell) {
        if (cell == null) {
            return null;
        }
        if (cell.kind() == CellKind.NUMBER && cell.number() != null) {
            return cell.number();
        }
        if (cell.kind() != CellKind.TEXT) {
            return null;
        }
        return parse(cell.text());
    }

    /**
     * 文本数字。规则: 去掉货币符号与单位文字后取第一个数字片段; 同时有 . 和 , 时最后出现的那个是小数点;
     * 只有逗号时, 每个逗号后恰好 3 位数字且整数部分不以 0 开头(「1,800」)视为千分位, 否则(「0,537」「12,5」)视为小数点;
     * 空格与撇号当千分位。
     */
    static BigDecimal parse(String text) {
        if (text == null) {
            return null;
        }
        String t = IntakeTextNormalizer.nfkc(text).strip();
        if (t.isEmpty()) {
            return null;
        }
        t = CURRENCY_NOISE.matcher(t).replaceAll(" ");
        Matcher m = NUMBER_TOKEN.matcher(t);
        if (!m.find()) {
            return null;
        }
        String token = m.group().strip().replace(" ", "").replace("'", "");
        while (!token.isEmpty() && !Character.isDigit(token.charAt(token.length() - 1))) {
            token = token.substring(0, token.length() - 1);
        }
        if (token.isEmpty() || "-".equals(token)) {
            return null;
        }
        int lastDot = token.lastIndexOf('.');
        int lastComma = token.lastIndexOf(',');
        String normalized;
        if (lastDot >= 0 && lastComma >= 0) {
            if (lastComma > lastDot) {
                normalized = token.replace(".", "").replace(',', '.');
            } else {
                normalized = token.replace(",", "");
            }
        } else if (lastComma >= 0) {
            // 「0,537」整数部分是 0, 只能是小数逗号(千分位不会以 0 开头)。
            boolean thousands = token.matches("-?[1-9]\\d{0,2}(,\\d{3})+");
            normalized = thousands ? token.replace(",", "") : token.replace(',', '.');
        } else {
            normalized = token;
        }
        if (normalized.chars().filter(c -> c == '.').count() > 1) {
            // 「1.234.567」: 多个点只可能是千分位。
            normalized = normalized.replace(".", "");
        }
        try {
            return new BigDecimal(normalized);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** 大于 0 的数字。 */
    static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }
}
