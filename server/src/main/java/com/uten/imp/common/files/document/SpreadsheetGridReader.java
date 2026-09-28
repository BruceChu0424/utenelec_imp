package com.uten.imp.common.files.document;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.files.document.DocumentGrid.MergedRange;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.files.document.DocumentParseGate.Deadline;
import com.uten.imp.common.web.ApiException;
import org.apache.poi.EncryptedDocumentException;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.openxml4j.opc.OPCPackage;
import org.apache.poi.openxml4j.util.ZipSecureFile;
import org.apache.poi.poifs.filesystem.DirectoryNode;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.DateUtil;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.util.XMLHelper;
import org.apache.poi.xssf.eventusermodel.ReadOnlySharedStringsTable;
import org.apache.poi.xssf.eventusermodel.XSSFReader;
import org.apache.poi.xssf.model.StylesTable;
import org.apache.poi.xssf.usermodel.XSSFCellStyle;
import org.xml.sax.Attributes;
import org.xml.sax.InputSource;
import org.xml.sax.SAXException;
import org.xml.sax.XMLReader;
import org.xml.sax.helpers.DefaultHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.math.BigDecimal;
import java.math.MathContext;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * 把 xlsx / xls / csv 读成 {@link DocumentGrid}(客户文件识别用; 只读值, 不执行任何内容)。
 *
 * <p>上限(SPEC §4): 压缩包 ≤ 15 MiB、单个工作表 XML ≤ 8 MiB、非图片部件合计 ≤ 32 MiB、条目 ≤ 1024
 * (见 {@link ZipSafety}); 最多读 8 个可见工作表; 每表最多 5000 行; 每格最多 8192 字。
 * 公式只取 Excel 保存的上次计算结果, 从不计算、从不返回公式文本; 隐藏的工作表/行/列与批注都跳过;
 * 合并区域只在左上角有值。xlsx 用 SAX 流式读取(不建整本 DOM), xls 用 HSSF 并设记录长度上限。
 * 进程内同一时间只解析一个文件, 单次墙钟 60 秒({@link DocumentParseGate})。
 */
public final class SpreadsheetGridReader {

    public static final int MAX_SHEETS = 8;
    public static final int MAX_ROWS_PER_SHEET = 5000;
    public static final int MAX_CELL_CHARS = 8192;
    /** 最多读到第几列(0 起, 含): 超出的列忽略(客户表格的内容不会在这么远)。 */
    public static final int MAX_COLUMN_INDEX = 1023;
    private static final int MAX_CELLS_PER_SHEET = 200_000;
    private static final int MAX_MERGES_PER_SHEET = 10_000;
    private static final MathContext EXCEL_PRECISION = new MathContext(15, RoundingMode.HALF_EVEN);
    private static final String RELATIONSHIP_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    private SpreadsheetGridReader() {
    }

    /** 读取表格类文件; 不支持的类型抛 IllegalArgumentException(调用方应先嗅探)。 */
    public static DocumentGrid read(byte[] bytes, DocumentKind kind) {
        return switch (kind) {
            case XLSX -> DocumentParseGate.run(deadline -> readXlsx(bytes, deadline));
            case XLS -> DocumentParseGate.run(deadline -> readXls(bytes, deadline));
            case CSV -> DocumentParseGate.run(deadline -> CsvGridReader.read(bytes, deadline));
            default -> throw new IllegalArgumentException("not a spreadsheet: " + kind);
        };
    }

    // ------------------------------------------------------------------ xlsx (SAX)

    static DocumentGrid readXlsx(byte[] bytes, Deadline deadline) {
        ZipSafety.inspectSpreadsheet(bytes);
        // POI 的压缩包限制是进程级静态值: 每次解析前重新设定, 防止别处放宽后影响这里。
        synchronized (ZipSecureFile.class) {
            ZipSecureFile.setMinInflateRatio(0.005d);
            ZipSecureFile.setMaxEntrySize(ZipSafety.MAX_MEDIA_BYTES);
            ZipSecureFile.setMaxFileCount(ZipSafety.MAX_ENTRIES + 64);
            ZipSecureFile.setMaxTextSize(ZipSafety.MAX_SHEET_XML_BYTES);
        }
        try (OPCPackage pkg = OPCPackage.open(new ByteArrayInputStream(bytes))) {
            XSSFReader reader = new XSSFReader(pkg);
            WorkbookInfo info = parseWorkbook(reader);
            StylesTable styles = reader.getStylesTable();
            ReadOnlySharedStringsTable strings = new ReadOnlySharedStringsTable(pkg, false);
            List<Sheet> sheets = new ArrayList<>();
            for (SheetRef ref : info.sheets()) {
                if (!ref.visible()) {
                    continue;
                }
                if (sheets.size() >= MAX_SHEETS) {
                    break;
                }
                deadline.check();
                try (InputStream in = reader.getSheet(ref.relId())) {
                    XlsxSheetHandler handler = new XlsxSheetHandler(strings, styles, info.date1904(), deadline);
                    XMLReader xml = XMLHelper.newXMLReader();
                    xml.setContentHandler(handler);
                    try {
                        xml.parse(new InputSource(in));
                    } catch (StopParsing stop) {
                        handler.truncated = true;
                    }
                    sheets.add(handler.toSheet(ref.name(), ref.index()));
                }
            }
            return new DocumentGrid(sheets);
        } catch (ApiException e) {
            throw e;
        } catch (SAXException e) {
            if (e.getException() instanceof ApiException api) {
                throw api;
            }
            throw unreadable();
        } catch (Exception e) {
            throw unreadable();
        }
    }

    private static ApiException unreadable() {
        return ZipSafety.rejected("这个 Excel 文件打不开或已损坏, 请另存为普通的 .xlsx 后再试");
    }

    private record SheetRef(String name, int index, String relId, boolean visible) {
    }

    private record WorkbookInfo(List<SheetRef> sheets, boolean date1904) {
    }

    private static WorkbookInfo parseWorkbook(XSSFReader reader) throws Exception {
        List<SheetRef> refs = new ArrayList<>();
        boolean[] date1904 = {false};
        try (InputStream in = reader.getWorkbookData()) {
            XMLReader xml = XMLHelper.newXMLReader();
            xml.setContentHandler(new DefaultHandler() {
                @Override
                public void startElement(String uri, String localName, String qName, Attributes atts) {
                    String name = localName == null || localName.isEmpty() ? qName : localName;
                    if ("workbookPr".equals(name)) {
                        String v = atts.getValue("date1904");
                        date1904[0] = "1".equals(v) || "true".equalsIgnoreCase(v);
                    } else if ("sheet".equals(name)) {
                        String relId = atts.getValue(RELATIONSHIP_NS, "id");
                        if (relId == null) {
                            relId = atts.getValue("r:id");
                        }
                        String state = atts.getValue("state");
                        boolean visible = state == null || "visible".equalsIgnoreCase(state);
                        String sheetName = atts.getValue("name");
                        refs.add(new SheetRef(sheetName == null ? "Sheet" + (refs.size() + 1) : sheetName, refs.size(),
                                relId, visible && relId != null));
                    }
                }
            });
            xml.parse(new InputSource(in));
        }
        return new WorkbookInfo(refs, date1904[0]);
    }

    /** SAX 中止信号(行数到上限)。 */
    private static final class StopParsing extends SAXException {
        StopParsing() {
            super("row limit reached");
        }
    }

    /** 单个工作表的 SAX 处理: 只收集有值的单元格, 跳过隐藏行列, 公式只取缓存值。 */
    static final class XlsxSheetHandler extends DefaultHandler {

        private final ReadOnlySharedStringsTable strings;
        private final StylesTable styles;
        private final boolean date1904;
        private final Deadline deadline;
        private final List<int[]> hiddenColumns = new ArrayList<>();
        private final List<Row> rows = new ArrayList<>();
        private final List<MergedRange> merges = new ArrayList<>();
        private List<Cell> currentCells;
        private int currentRow = -1;
        private boolean rowHidden;
        private int skippedHiddenRows;
        private int maxColumn = -1;
        private int cellCount;
        boolean truncated;

        private int cellCol;
        private String cellType;
        private int cellStyle;
        private boolean inValue;
        private boolean inInlineText;
        private boolean inPhonetic;
        private final StringBuilder value = new StringBuilder();
        private final StringBuilder inline = new StringBuilder();

        XlsxSheetHandler(ReadOnlySharedStringsTable strings, StylesTable styles, boolean date1904, Deadline deadline) {
            this.strings = strings;
            this.styles = styles;
            this.date1904 = date1904;
            this.deadline = deadline;
        }

        @Override
        public void startElement(String uri, String localName, String qName, Attributes atts) throws SAXException {
            String name = localName == null || localName.isEmpty() ? qName : localName;
            switch (name) {
                case "col" -> {
                    if (isTrue(atts.getValue("hidden"))) {
                        int min = parseInt(atts.getValue("min"), 1);
                        int max = parseInt(atts.getValue("max"), min);
                        hiddenColumns.add(new int[]{min - 1, max - 1});
                    }
                }
                case "row" -> {
                    if (rows.size() >= MAX_ROWS_PER_SHEET) {
                        throw new StopParsing();
                    }
                    if ((rows.size() & 63) == 0) {
                        try {
                            deadline.check();
                        } catch (ApiException e) {
                            throw new SAXException(e);
                        }
                    }
                    int r = parseInt(atts.getValue("r"), currentRow + 2);
                    currentRow = r - 1;
                    rowHidden = isTrue(atts.getValue("hidden"));
                    if (rowHidden) {
                        skippedHiddenRows++;
                    }
                    currentCells = new ArrayList<>();
                }
                case "c" -> {
                    String ref = atts.getValue("r");
                    cellCol = ref == null ? (currentCells == null || currentCells.isEmpty() ? 0
                            : currentCells.getLast().col0() + 1) : columnOfRef(ref);
                    cellType = atts.getValue("t");
                    cellStyle = parseInt(atts.getValue("s"), 0);
                    value.setLength(0);
                    inline.setLength(0);
                }
                case "v" -> {
                    inValue = true;
                    value.setLength(0);
                }
                case "rPh" -> inPhonetic = true;
                case "t" -> inInlineText = !inPhonetic;
                case "mergeCell" -> {
                    if (merges.size() < MAX_MERGES_PER_SHEET) {
                        MergedRange m = parseRange(atts.getValue("ref"));
                        if (m != null) {
                            merges.add(m);
                        }
                    }
                }
                default -> {
                    // 公式 <f>、批注引用、格式等一律不读。
                }
            }
        }

        @Override
        public void endElement(String uri, String localName, String qName) {
            String name = localName == null || localName.isEmpty() ? qName : localName;
            switch (name) {
                case "v" -> inValue = false;
                case "t" -> inInlineText = false;
                case "rPh" -> inPhonetic = false;
                case "c" -> finishCell();
                case "row" -> {
                    if (!rowHidden && currentCells != null && !currentCells.isEmpty()) {
                        rows.add(new Row(currentRow, currentCells));
                    }
                    currentCells = null;
                }
                default -> {
                }
            }
        }

        @Override
        public void characters(char[] ch, int start, int length) {
            if (inValue) {
                if (value.length() < MAX_CELL_CHARS * 2) {
                    value.append(ch, start, length);
                }
            } else if (inInlineText) {
                if (inline.length() < MAX_CELL_CHARS * 2) {
                    inline.append(ch, start, length);
                }
            }
        }

        private void finishCell() {
            if (currentCells == null || rowHidden || cellCol < 0 || cellCol > MAX_COLUMN_INDEX || isHiddenColumn(cellCol)) {
                return;
            }
            if (cellCount >= MAX_CELLS_PER_SHEET) {
                return;
            }
            Cell cell = buildCell();
            if (cell == null) {
                return;
            }
            currentCells.add(cell);
            cellCount++;
            maxColumn = Math.max(maxColumn, cellCol);
        }

        private Cell buildCell() {
            String t = cellType == null ? "n" : cellType;
            String raw = value.toString();
            switch (t) {
                case "s" -> {
                    int idx = parseInt(raw.strip(), -1);
                    if (idx < 0 || idx >= strings.getCount()) {
                        return null;
                    }
                    return textCell(strings.getItemAt(idx).getString());
                }
                case "inlineStr" -> {
                    return textCell(inline.length() > 0 ? inline.toString() : raw);
                }
                case "str" -> {
                    return textCell(raw);
                }
                case "b" -> {
                    String v = raw.strip();
                    if (v.isEmpty()) {
                        return null;
                    }
                    return new Cell(cellCol, "1".equals(v) || "true".equalsIgnoreCase(v) ? "TRUE" : "FALSE",
                            CellKind.BOOLEAN, null);
                }
                case "e" -> {
                    return null;
                }
                case "d" -> {
                    String v = raw.strip();
                    if (v.isEmpty()) {
                        return null;
                    }
                    return new Cell(cellCol, isoDate(v), CellKind.DATE, null);
                }
                default -> {
                    String v = raw.strip();
                    if (v.isEmpty()) {
                        return null;
                    }
                    BigDecimal number;
                    try {
                        number = new BigDecimal(v);
                    } catch (NumberFormatException e) {
                        return textCell(v);
                    }
                    if (isDateStyle(cellStyle)) {
                        try {
                            LocalDateTime dt = DateUtil.getLocalDateTime(number.doubleValue(), date1904);
                            if (dt != null) {
                                return new Cell(cellCol, formatDateTime(dt), CellKind.DATE, null);
                            }
                        } catch (RuntimeException ignored) {
                            // 不是合法日期序号: 按数字处理。
                        }
                    }
                    BigDecimal rounded = excelNumber(number);
                    return new Cell(cellCol, plain(rounded), CellKind.NUMBER, rounded);
                }
            }
        }

        private Cell textCell(String text) {
            String cleaned = cleanText(text);
            return cleaned.isEmpty() ? null : Cell.text(cellCol, cleaned);
        }

        private boolean isDateStyle(int styleIndex) {
            if (styles == null || styleIndex <= 0) {
                return false;
            }
            try {
                XSSFCellStyle style = styles.getStyleAt(styleIndex);
                if (style == null) {
                    return false;
                }
                return DateUtil.isADateFormat(style.getDataFormat(), style.getDataFormatString());
            } catch (RuntimeException e) {
                return false;
            }
        }

        private boolean isHiddenColumn(int col) {
            for (int[] range : hiddenColumns) {
                if (col >= range[0] && col <= range[1]) {
                    return true;
                }
            }
            return false;
        }

        Sheet toSheet(String name, int index) {
            return new Sheet(name, index, rows, merges, skippedHiddenRows, maxColumn, truncated);
        }
    }

    // ------------------------------------------------------------------ xls (HSSF)

    static DocumentGrid readXls(byte[] bytes, Deadline deadline) {
        synchronized (HSSFWorkbook.class) {
            HSSFWorkbook.setMaxRecordLength((int) ZipSafety.MAX_COMPRESSED_BYTES);
        }
        try (POIFSFileSystem fs = new POIFSFileSystem(new ByteArrayInputStream(bytes))) {
            DirectoryNode root = fs.getRoot();
            if (root.hasEntryCaseInsensitive("EncryptedPackage") || root.hasEntryCaseInsensitive("EncryptionInfo")) {
                throw ZipSafety.rejected("这个 Excel 设置了打开密码, 请去掉密码后再上传");
            }
            if (root.hasEntryCaseInsensitive("_VBA_PROJECT_CUR") || root.hasEntryCaseInsensitive("_VBA_PROJECT")
                    || root.hasEntryCaseInsensitive("Macros")) {
                throw ZipSafety.rejected("这个 Excel 带有宏, 为了安全不能识别, 请另存为普通的 .xlsx 后再试");
            }
            try (HSSFWorkbook wb = new HSSFWorkbook(root, false)) {
                List<Sheet> sheets = new ArrayList<>();
                for (int i = 0; i < wb.getNumberOfSheets() && sheets.size() < MAX_SHEETS; i++) {
                    if (wb.isSheetHidden(i) || wb.isSheetVeryHidden(i)) {
                        continue;
                    }
                    deadline.check();
                    sheets.add(readHssfSheet(wb.getSheetAt(i), wb.getSheetName(i), i, deadline));
                }
                return new DocumentGrid(sheets);
            }
        } catch (ApiException e) {
            throw e;
        } catch (EncryptedDocumentException e) {
            throw ZipSafety.rejected("这个 Excel 设置了打开密码, 请去掉密码后再上传");
        } catch (Exception e) {
            throw ZipSafety.rejected("这个 Excel 文件打不开或已损坏, 请另存为 .xlsx 后再试");
        }
    }

    private static Sheet readHssfSheet(org.apache.poi.ss.usermodel.Sheet sheet, String name, int index,
                                       Deadline deadline) {
        List<Row> rows = new ArrayList<>();
        int skippedHidden = 0;
        int maxColumn = -1;
        int cellCount = 0;
        boolean truncated = false;
        for (org.apache.poi.ss.usermodel.Row row : sheet) {
            if (rows.size() >= MAX_ROWS_PER_SHEET) {
                truncated = true;
                break;
            }
            if ((rows.size() & 63) == 0) {
                deadline.check();
            }
            if (row.getZeroHeight()) {
                skippedHidden++;
                continue;
            }
            List<Cell> cells = new ArrayList<>();
            for (org.apache.poi.ss.usermodel.Cell cell : row) {
                int col = cell.getColumnIndex();
                if (col > MAX_COLUMN_INDEX || sheet.isColumnHidden(col) || cellCount >= MAX_CELLS_PER_SHEET) {
                    continue;
                }
                Cell converted = convertHssfCell(cell, col);
                if (converted != null) {
                    cells.add(converted);
                    cellCount++;
                    maxColumn = Math.max(maxColumn, col);
                }
            }
            if (!cells.isEmpty()) {
                cells.sort((a, b) -> Integer.compare(a.col0(), b.col0()));
                rows.add(new Row(row.getRowNum(), cells));
            }
        }
        List<MergedRange> merges = new ArrayList<>();
        for (CellRangeAddress range : sheet.getMergedRegions()) {
            if (merges.size() >= MAX_MERGES_PER_SHEET) {
                break;
            }
            merges.add(new MergedRange(range.getFirstRow(), range.getLastRow(), range.getFirstColumn(),
                    range.getLastColumn()));
        }
        rows.sort((a, b) -> Integer.compare(a.index0(), b.index0()));
        return new Sheet(name, index, rows, merges, skippedHidden, maxColumn, truncated);
    }

    private static Cell convertHssfCell(org.apache.poi.ss.usermodel.Cell cell, int col) {
        CellType type = cell.getCellType();
        if (type == CellType.FORMULA) {
            type = cell.getCachedFormulaResultType();
        }
        switch (type) {
            case STRING -> {
                String text = cleanText(cell.getRichStringCellValue().getString());
                return text.isEmpty() ? null : Cell.text(col, text);
            }
            case NUMERIC -> {
                double d = cell.getNumericCellValue();
                if (DateUtil.isCellDateFormatted(cell)) {
                    LocalDateTime dt = cell.getLocalDateTimeCellValue();
                    if (dt != null) {
                        return new Cell(col, formatDateTime(dt), CellKind.DATE, null);
                    }
                }
                if (Double.isNaN(d) || Double.isInfinite(d)) {
                    return null;
                }
                BigDecimal rounded = excelNumber(BigDecimal.valueOf(d));
                return new Cell(col, plain(rounded), CellKind.NUMBER, rounded);
            }
            case BOOLEAN -> {
                return new Cell(col, cell.getBooleanCellValue() ? "TRUE" : "FALSE", CellKind.BOOLEAN, null);
            }
            default -> {
                return null;
            }
        }
    }

    // ------------------------------------------------------------------ helpers

    /** 与 Excel 显示一致: 最多 15 位有效数字, 去掉末尾 0。 */
    static BigDecimal excelNumber(BigDecimal raw) {
        BigDecimal r = raw.round(EXCEL_PRECISION).stripTrailingZeros();
        return r.scale() < 0 ? r.setScale(0) : r;
    }

    static String plain(BigDecimal number) {
        return number.toPlainString();
    }

    /** 去掉首尾空白, 统一换行, 截断到上限; 保留单元格内部的换行(中英分行判断要用)。 */
    static String cleanText(String text) {
        if (text == null) {
            return "";
        }
        String t = text.replace("\r\n", "\n").replace('\r', '\n').replace('\u00A0', ' ').strip();
        if (t.length() > MAX_CELL_CHARS) {
            t = t.substring(0, MAX_CELL_CHARS);
        }
        return t;
    }

    private static String formatDateTime(LocalDateTime dt) {
        if (dt.toLocalTime().toSecondOfDay() == 0) {
            return dt.toLocalDate().toString();
        }
        return dt.withNano(0).toString();
    }

    private static String isoDate(String v) {
        int t = v.indexOf('T');
        String date = t > 0 ? v.substring(0, t) : v;
        if (t > 0 && !v.substring(t + 1).startsWith("00:00:00")) {
            return v.length() > 19 ? v.substring(0, 19) : v;
        }
        return date;
    }

    private static boolean isTrue(String v) {
        return "1".equals(v) || "true".equalsIgnoreCase(v);
    }

    private static int parseInt(String v, int fallback) {
        if (v == null || v.isEmpty()) {
            return fallback;
        }
        try {
            return Integer.parseInt(v.strip());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    /** "E9" → 4; "AA10" → 26。 */
    static int columnOfRef(String ref) {
        int i = 0;
        while (i < ref.length() && Character.isLetter(ref.charAt(i))) {
            i++;
        }
        return DocumentGrid.columnIndex(ref.substring(0, i).toUpperCase(Locale.ROOT));
    }

    private static int rowOfRef(String ref) {
        int i = 0;
        while (i < ref.length() && Character.isLetter(ref.charAt(i))) {
            i++;
        }
        return parseInt(ref.substring(i), 0) - 1;
    }

    /** "A1:T1" → 合并区域; 不合法返回 null。 */
    static MergedRange parseRange(String ref) {
        if (ref == null || !ref.contains(":")) {
            return null;
        }
        String[] parts = ref.split(":", 2);
        int r1 = rowOfRef(parts[0]);
        int c1 = columnOfRef(parts[0]);
        int r2 = rowOfRef(parts[1]);
        int c2 = columnOfRef(parts[1]);
        if (r1 < 0 || c1 < 0 || r2 < r1 || c2 < c1) {
            return null;
        }
        return new MergedRange(r1, r2, c1, c2);
    }
}
