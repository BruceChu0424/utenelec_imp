package com.uten.imp.common.files.document;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

/**
 * 读取出来的表格(只含有值的单元格)。行号、列号都从 0 开始; 隐藏的工作表/行/列已跳过。
 *
 * @param sheets 可见工作表(按工作簿顺序)
 */
public record DocumentGrid(List<Sheet> sheets) {

    public DocumentGrid {
        sheets = List.copyOf(Objects.requireNonNull(sheets, "sheets"));
    }

    /**
     * 一个工作表。
     *
     * @param name               工作表名称
     * @param index              工作簿里的序号(从 0 开始, 含被跳过的隐藏表)
     * @param rows               有值的行(按行号升序)
     * @param merges             合并区域(值只在左上角单元格)
     * @param skippedHiddenRows  跳过的隐藏行数
     * @param maxColumn          出现过值的最大列号(从 0 开始; 没有值为 -1)
     * @param truncated          超过行数上限被截断
     */
    public record Sheet(String name, int index, List<Row> rows, List<MergedRange> merges, int skippedHiddenRows,
                        int maxColumn, boolean truncated) {

        public Sheet {
            Objects.requireNonNull(name, "name");
            rows = List.copyOf(rows);
            merges = List.copyOf(merges);
        }

        /** 按行号取行; 没有返回 null。 */
        public Row row(int index0) {
            int lo = 0;
            int hi = rows.size() - 1;
            while (lo <= hi) {
                int mid = (lo + hi) >>> 1;
                int r = rows.get(mid).index0();
                if (r == index0) {
                    return rows.get(mid);
                }
                if (r < index0) {
                    lo = mid + 1;
                } else {
                    hi = mid - 1;
                }
            }
            return null;
        }

        /** 单元格文字; 没有返回空串。 */
        public String text(int row0, int col0) {
            Row row = row(row0);
            if (row == null) {
                return "";
            }
            Cell cell = row.cell(col0);
            return cell == null ? "" : cell.text();
        }

        /** 包含某单元格的合并区域; 没有返回 null。 */
        public MergedRange mergeAt(int row0, int col0) {
            for (MergedRange m : merges) {
                if (m.contains(row0, col0)) {
                    return m;
                }
            }
            return null;
        }

        /** 最后一行的行号; 空表为 -1。 */
        public int lastRowIndex() {
            return rows.isEmpty() ? -1 : rows.getLast().index0();
        }
    }

    /**
     * 一行。
     *
     * @param index0 行号(从 0 开始)
     * @param cells  有值的单元格(按列号升序)
     */
    public record Row(int index0, List<Cell> cells) {

        public Row {
            cells = List.copyOf(cells);
        }

        /** 按列号取单元格; 没有返回 null。 */
        public Cell cell(int col0) {
            for (Cell c : cells) {
                if (c.col0() == col0) {
                    return c;
                }
                if (c.col0() > col0) {
                    return null;
                }
            }
            return null;
        }

        /** 第一个有文字的单元格文字; 没有返回空串。 */
        public String firstText() {
            for (Cell c : cells) {
                if (!c.text().isBlank()) {
                    return c.text();
                }
            }
            return "";
        }

        /** 整行文字用空格连接(判断合计行、银行行等用)。 */
        public String joinedText() {
            List<String> parts = new ArrayList<>(cells.size());
            for (Cell c : cells) {
                if (!c.text().isBlank()) {
                    parts.add(c.text());
                }
            }
            return String.join(" ", parts);
        }
    }

    /**
     * 单元格。数字按单元格里保存的值原样转成 BigDecimal(不做浮点换算), {@code text} 是便于阅读的文本
     * (数字去掉末尾 0、日期是 ISO 格式、布尔是 TRUE/FALSE)。公式只取 Excel 上次计算保存的结果, 从不返回公式本身。
     */
    public record Cell(int col0, String text, CellKind kind, BigDecimal number) {

        public Cell {
            Objects.requireNonNull(text, "text");
            Objects.requireNonNull(kind, "kind");
        }

        public static Cell text(int col0, String text) {
            return new Cell(col0, text, CellKind.TEXT, null);
        }
    }

    /** 单元格值类型。 */
    public enum CellKind { TEXT, NUMBER, DATE, BOOLEAN }

    /** 合并区域(闭区间, 从 0 开始)。 */
    public record MergedRange(int firstRow, int lastRow, int firstCol, int lastCol) {

        public boolean contains(int row0, int col0) {
            return row0 >= firstRow && row0 <= lastRow && col0 >= firstCol && col0 <= lastCol;
        }
    }

    /** 列号(从 0 开始) → Excel 列字母(A, B, ..., Z, AA...)。 */
    public static String columnLetter(int col0) {
        StringBuilder sb = new StringBuilder();
        int n = col0 + 1;
        while (n > 0) {
            int rem = (n - 1) % 26;
            sb.append((char) ('A' + rem));
            n = (n - 1) / 26;
        }
        return sb.reverse().toString();
    }

    /** Excel 列字母 → 列号(从 0 开始); 不合法返回 -1。 */
    public static int columnIndex(String letters) {
        if (letters == null || letters.isEmpty() || letters.length() > 3) {
            return -1;
        }
        int n = 0;
        for (int i = 0; i < letters.length(); i++) {
            char c = Character.toUpperCase(letters.charAt(i));
            if (c < 'A' || c > 'Z') {
                return -1;
            }
            n = n * 26 + (c - 'A' + 1);
        }
        return n - 1;
    }

    /** 空表格。 */
    public static DocumentGrid empty() {
        return new DocumentGrid(Collections.emptyList());
    }
}
