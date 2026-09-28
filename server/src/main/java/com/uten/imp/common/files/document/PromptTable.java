package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;

import java.util.Set;

/**
 * 把表格的一段行压成发给大模型的紧凑文本, 每行一条:
 * {@code R12 | A:1 | B:Z9 | C:WHITE | E:GZ23/D}(行号从 1 开始、列用字母; 空单元格不输出;
 * 单元格内换行变成 {@code " / "}; 每格最多 200 字)。超过总长度上限时在末尾加截断标记。
 *
 * <p>行号列号让模型回答时能引用来源位置, 服务端据此核对; 被排除的行(例如银行账号、卖方信息)不输出。
 */
public final class PromptTable {

    public static final int MAX_CELL_CHARS = 200;
    public static final String TRUNCATION_MARKER = "[TRUNCATED: more rows omitted]";

    private PromptTable() {
    }

    /**
     * @param sheet         工作表
     * @param fromRow0      起始行号(从 0 开始, 含)
     * @param toRow0        结束行号(从 0 开始, 含)
     * @param maxChars      输出总长度上限
     * @param excludedRows0 不输出的行号(从 0 开始); 可为空
     */
    public static String render(Sheet sheet, int fromRow0, int toRow0, int maxChars, Set<Integer> excludedRows0) {
        StringBuilder out = new StringBuilder();
        for (Row row : sheet.rows()) {
            if (row.index0() < fromRow0 || row.index0() > toRow0) {
                continue;
            }
            if (excludedRows0 != null && excludedRows0.contains(row.index0())) {
                continue;
            }
            String line = renderRow(row);
            if (line == null) {
                continue;
            }
            if (out.length() + line.length() + 1 > maxChars) {
                return out.append(TRUNCATION_MARKER).toString();
            }
            out.append(line).append('\n');
        }
        return out.toString().stripTrailing();
    }

    /** 单行; 没有可输出的单元格返回 null。 */
    public static String renderRow(Row row) {
        StringBuilder line = new StringBuilder("R").append(row.index0() + 1);
        boolean any = false;
        for (Cell cell : row.cells()) {
            String text = cellText(cell.text());
            if (text.isEmpty()) {
                continue;
            }
            line.append(" | ").append(DocumentGrid.columnLetter(cell.col0())).append(':').append(text);
            any = true;
        }
        return any ? line.toString() : null;
    }

    /** 单元格文字: 换行变 " / ", 合并空白, 截断到 200 字。 */
    public static String cellText(String text) {
        if (text == null) {
            return "";
        }
        String t = text.replace("\r\n", "\n").replace('\r', '\n').replace("\n", " / ")
                .replaceAll("[\\t\\x0B\\f ]+", " ").strip();
        if (t.length() > MAX_CELL_CHARS) {
            t = t.substring(0, MAX_CELL_CHARS) + "...";
        }
        return t;
    }
}
