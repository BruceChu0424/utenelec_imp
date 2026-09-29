package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.files.document.DocumentParseGate.Deadline;

import java.math.BigDecimal;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

/**
 * CSV/TXT 读成单个工作表: 编码 UTF-8(带或不带 BOM)否则 GB18030; 分隔符在 {@code , ; Tab |} 里自动判断;
 * 按 RFC 4180 处理引号与引号内换行; 最多 5000 行、每格 8192 字、1024 列。
 */
public final class CsvGridReader {

    private static final char[] DELIMITERS = {',', ';', '\t', '|'};
    private static final Pattern PLAIN_NUMBER = Pattern.compile("-?\\d{1,15}(\\.\\d{1,15})?");
    private static final int PROBE_LINES = 30;

    private CsvGridReader() {
    }

    static DocumentGrid read(byte[] bytes, Deadline deadline) {
        String text = decode(bytes);
        char delimiter = detectDelimiter(text);
        List<Row> rows = new ArrayList<>();
        boolean truncated = false;
        int maxColumn = -1;
        List<String> fields = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        boolean inQuotes = false;
        boolean fieldWasQuoted = false;
        int rowIndex = 0;
        int i = 0;
        int n = text.length();
        while (i <= n) {
            char c = i < n ? text.charAt(i) : '\n';
            boolean atEnd = i == n;
            if (inQuotes && !atEnd) {
                if (c == '"') {
                    if (i + 1 < n && text.charAt(i + 1) == '"') {
                        appendBounded(field, '"');
                        i += 2;
                        continue;
                    }
                    inQuotes = false;
                } else {
                    appendBounded(field, c);
                }
                i++;
                continue;
            }
            if (c == '"' && field.isEmpty() && !fieldWasQuoted && !atEnd) {
                inQuotes = true;
                fieldWasQuoted = true;
                i++;
                continue;
            }
            if (c == delimiter && !atEnd) {
                fields.add(field.toString());
                field.setLength(0);
                fieldWasQuoted = false;
                i++;
                continue;
            }
            if (c == '\r' && !atEnd) {
                i++;
                continue;
            }
            if (c == '\n') {
                fields.add(field.toString());
                field.setLength(0);
                fieldWasQuoted = false;
                boolean lastEmptyLine = atEnd && fields.size() == 1 && fields.getFirst().isEmpty();
                if (!lastEmptyLine) {
                    Row row = toRow(rowIndex, fields);
                    if (row != null) {
                        if (rows.size() >= SpreadsheetGridReader.MAX_ROWS_PER_SHEET) {
                            truncated = true;
                            break;
                        }
                        rows.add(row);
                        maxColumn = Math.max(maxColumn, row.cells().getLast().col0());
                        if ((rows.size() & 63) == 0) {
                            deadline.check();
                        }
                    }
                    rowIndex++;
                }
                fields.clear();
                i++;
                continue;
            }
            appendBounded(field, c);
            i++;
        }
        Sheet sheet = new Sheet("CSV", 0, rows, List.of(), 0, maxColumn, truncated);
        return new DocumentGrid(List.of(sheet));
    }

    private static void appendBounded(StringBuilder field, char c) {
        if (field.length() < SpreadsheetGridReader.MAX_CELL_CHARS) {
            field.append(c);
        }
    }

    private static Row toRow(int rowIndex, List<String> fields) {
        List<Cell> cells = new ArrayList<>();
        for (int col = 0; col < fields.size() && col <= SpreadsheetGridReader.MAX_COLUMN_INDEX; col++) {
            String text = SpreadsheetGridReader.cleanText(fields.get(col));
            if (text.isEmpty()) {
                continue;
            }
            if (PLAIN_NUMBER.matcher(text).matches()) {
                // 数值照常解析, 文字保留原样: 「00123」这样的编号不能丢掉前导 0。
                BigDecimal number = SpreadsheetGridReader.excelNumber(new BigDecimal(text));
                cells.add(new Cell(col, text, CellKind.NUMBER, number));
            } else {
                cells.add(Cell.text(col, text));
            }
        }
        return cells.isEmpty() ? null : new Row(rowIndex, cells);
    }

    /** UTF-8(去 BOM)能解码就用 UTF-8, 否则 GB18030。 */
    static String decode(byte[] bytes) {
        int offset = 0;
        if (bytes.length >= 3 && (bytes[0] & 0xFF) == 0xEF && (bytes[1] & 0xFF) == 0xBB && (bytes[2] & 0xFF) == 0xBF) {
            offset = 3;
        }
        byte[] body = offset == 0 ? bytes : java.util.Arrays.copyOfRange(bytes, offset, bytes.length);
        if (offset == 3 || DocumentSniffer.decodes(body, body.length, StandardCharsets.UTF_8)) {
            return new String(body, StandardCharsets.UTF_8);
        }
        return new String(body, Charset.forName("GB18030"));
    }

    /** 在前 30 行里, 选各行出现次数最稳定且大于 0 的分隔符(引号内的不算); 都没有默认逗号。 */
    static char detectDelimiter(String text) {
        char best = ',';
        double bestScore = 0;
        for (char d : DELIMITERS) {
            List<Integer> counts = new ArrayList<>();
            int count = 0;
            boolean inQuotes = false;
            for (int i = 0; i < text.length() && counts.size() < PROBE_LINES; i++) {
                char c = text.charAt(i);
                if (c == '"') {
                    inQuotes = !inQuotes;
                } else if (!inQuotes && c == d) {
                    count++;
                } else if (!inQuotes && c == '\n') {
                    counts.add(count);
                    count = 0;
                }
            }
            if (count > 0) {
                counts.add(count);
            }
            long nonZero = counts.stream().filter(x -> x > 0).count();
            if (nonZero == 0) {
                continue;
            }
            int mode = counts.stream().filter(x -> x > 0)
                    .reduce((a, b) -> countOf(counts, a) >= countOf(counts, b) ? a : b).orElse(0);
            double score = countOf(counts, mode) * Math.log1p(mode);
            if (score > bestScore) {
                bestScore = score;
                best = d;
            }
        }
        return best;
    }

    private static long countOf(List<Integer> values, int v) {
        return values.stream().filter(x -> x == v).count();
    }
}
