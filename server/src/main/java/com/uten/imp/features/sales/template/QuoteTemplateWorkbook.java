package com.uten.imp.features.sales.template;

import com.uten.imp.common.files.document.DocumentGrid;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.xssf.usermodel.XSSFCellStyle;
import org.apache.poi.ss.util.CellReference;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Clean spreadsheet templates: copy presentation, never copy customer values or executable content. */
public final class QuoteTemplateWorkbook {
    public static final int MAX_ROWS = 2000;
    public static final int MAX_COLUMNS = 100;
    private static final Set<String> SAFE_LABELS = Set.of("quotation", "quote", "proforma invoice", "commercial invoice",
            "报价单", "形式发票", "商业发票", "total", "subtotal", "合计", "总计", "小计");
    private QuoteTemplateWorkbook() { }

    public record Candidate(byte[] xlsx, String fingerprint, Map<String, Object> mapping,
                            Set<String> features) { }
    public record ExportLine(Map<String, String> values) { }
    public record DisplayColumn(String key, String label, double width, String role, String sourceRole, String extraName) { }

    /** Retain template presentation, while current visible schema owns detail columns and their order. */
    @SuppressWarnings("unchecked")
    public static Candidate project(byte[] bytes, Map<String, Object> original, List<DisplayColumn> columns) {
        if (columns.isEmpty() || columns.size() > MAX_COLUMNS) throw new IllegalArgumentException("导出表头列数无效");
        try (XSSFWorkbook workbook = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            Sheet sheet = workbook.getSheetAt(0);
            int headerRow = ((Number) original.get("headerRow")).intValue();
            int headerSpan = ((Number) original.get("headerSpan")).intValue();
            Map<String, String> roles = (Map<String, String>) original.get("roles");
            Map<String, String> extras = (Map<String, String>) original.getOrDefault("extraHeaders", Map.of());
            int[] sourceColumns = new int[columns.size()]; Arrays.fill(sourceColumns, -1);
            for (int i = 0; i < columns.size(); i++) {
                DisplayColumn column = columns.get(i);
                for (var entry : roles.entrySet()) if (Objects.equals(entry.getValue(), column.sourceRole())) {
                    sourceColumns[i] = DocumentGrid.columnIndex(entry.getKey()); break;
                }
                if (sourceColumns[i] < 0 && column.extraName() != null)
                    for (var entry : extras.entrySet()) if (normalize(entry.getValue()).equals(normalize(column.extraName())))
                        sourceColumns[i] = DocumentGrid.columnIndex(entry.getKey());
            }
            List<CellRangeAddress> merges = sheet.getMergedRegions();
            for (int i = sheet.getNumMergedRegions() - 1; i >= 0; i--) sheet.removeMergedRegion(i);
            for (Row row : sheet) {
                if (row.getRowNum() < headerRow) continue;
                Map<Integer, CellSnapshot> saved = new HashMap<>();
                for (Cell cell : row) saved.put(cell.getColumnIndex(), new CellSnapshot(cell.getColumnIndex(), cell.getCellStyle(),
                        cell.getCellType() == CellType.STRING ? cell.getStringCellValue() : ""));
                List<Cell> remove = new ArrayList<>(); row.forEach(remove::add); remove.forEach(row::removeCell);
                for (int i = 0; i < columns.size(); i++) {
                    Cell target = row.createCell(i);
                    CellSnapshot previous = saved.get(sourceColumns[i]);
                    if (previous == null && !saved.isEmpty()) previous = saved.values().iterator().next();
                    if (previous != null) target.setCellStyle(previous.style());
                    if (row.getRowNum() == headerRow + headerSpan - 1) target.setCellValue(columns.get(i).label());
                    else if (row.getRowNum() >= headerRow + headerSpan && saved.containsKey(sourceColumns[i]))
                        target.setCellValue(saved.get(sourceColumns[i]).text());
                }
            }
            for (CellRangeAddress merge : merges) {
                if (merge.getLastRow() < headerRow) {
                    int last = Math.min(merge.getLastColumn(), columns.size() - 1);
                    if (merge.getFirstColumn() <= last && (merge.getFirstColumn() != last || merge.getFirstRow() != merge.getLastRow()))
                        sheet.addMergedRegion(new CellRangeAddress(merge.getFirstRow(), merge.getLastRow(), merge.getFirstColumn(), last));
                    continue;
                }
                if (merge.getFirstRow() < headerRow + headerSpan) continue; // Current header labels must each remain visible.
                List<Integer> destinations = new ArrayList<>();
                for (int i = 0; i < sourceColumns.length; i++)
                    if (sourceColumns[i] >= merge.getFirstColumn() && sourceColumns[i] <= merge.getLastColumn()) destinations.add(i);
                if (destinations.isEmpty()) continue;
                int first = destinations.getFirst(), last = destinations.getLast();
                if (last - first + 1 != destinations.size()) continue;
                Set<Integer> uniqueSources = new HashSet<>();
                for (int destination : destinations) uniqueSources.add(sourceColumns[destination]);
                if (uniqueSources.size() != destinations.size()) continue;
                if (first != last || merge.getFirstRow() != merge.getLastRow())
                    sheet.addMergedRegion(new CellRangeAddress(merge.getFirstRow(), merge.getLastRow(), first, last));
            }
            Map<String, String> projectedRoles = new LinkedHashMap<>();
            List<String> moneyRoles = new ArrayList<>();
            for (int i = 0; i < columns.size(); i++) {
                DisplayColumn column = columns.get(i);
                projectedRoles.put(DocumentGrid.columnLetter(i), column.role());
                if (Set.of("AMOUNT", "UNIT_PRICE").contains(column.role()) || column.role().startsWith("EXTRA_ID:") && "AMOUNT".equals(column.sourceRole())) moneyRoles.add(column.role());
                sheet.setColumnHidden(i, false);
                sheet.setColumnWidth(i, (int) Math.max(256, Math.min(255 * 256, (column.width() - 5) / 7 * 256)));
            }
            Map<String, Object> mapping = new LinkedHashMap<>(original);
            mapping.put("roles", projectedRoles); mapping.put("extraHeaders", Map.of()); mapping.put("roleHeaders", Map.of());
            mapping.put("maxColumn", columns.size()); mapping.put("projectionApplied", true); mapping.put("moneyRoles", moneyRoles);
            mapping.put("showTotal", columns.stream().anyMatch(c -> "AMOUNT".equals(c.role())));
            Map<String, String> projectedFields = new LinkedHashMap<>();
            List<String> inlineFields = new ArrayList<>();
            Map<String, String> oldFields = (Map<String, String>) original.getOrDefault("headerCells", Map.of());
            for (var field : oldFields.entrySet()) {
                CellReference ref = new CellReference(field.getValue());
                int col = Math.min(ref.getCol(), columns.size() - 1);
                int row = ref.getRow();
                CellRangeAddress containing = mergeAt(sheet, row, col);
                if (containing != null) { col = containing.getFirstColumn(); row = containing.getFirstRow(); }
                projectedFields.put(field.getKey(), new CellReference(row, col).formatAsString());
                if (col != ref.getCol() || row != ref.getRow()) inlineFields.add(field.getKey());
            }
            mapping.put("headerCells", projectedFields); mapping.put("inlineHeaderFields", inlineFields);
            return new Candidate(bytes(workbook), "", mapping, Set.of());
        } catch (Exception failure) { throw new IllegalArgumentException("无法按当前表头整理报价模板", failure); }
    }

    public static Candidate capture(byte[] source, int sheetIndex, int headerRow, int headerSpan,
                                    Map<String, String> roles, Map<String, String> extraHeaders) {
        return capture(source, sheetIndex, headerRow, headerSpan, roles, extraHeaders, List.of());
    }

    public static Candidate capture(byte[] source, int sheetIndex, int headerRow, int headerSpan,
                                    Map<String, String> roles, Map<String, String> extraHeaders,
                                    List<Integer> detailRows0) {
        if (source == null || source.length > 15 * 1024 * 1024) throw new IllegalArgumentException("表格超过大小上限");
        validateColumns(roles); validateColumns(extraHeaders);
        roles = new LinkedHashMap<>(roles);
        extraHeaders = new LinkedHashMap<>(extraHeaders);
        if (source.length >= 2 && source[0] == 'P' && source[1] == 'K')
            com.uten.imp.common.files.document.ZipSafety.inspectSpreadsheet(source);
        try (Workbook original = WorkbookFactory.create(new ByteArrayInputStream(source));
             XSSFWorkbook clean = new XSSFWorkbook()) {
            if (sheetIndex < 0 || sheetIndex >= original.getNumberOfSheets() || headerRow < 0
                    || headerSpan < 1 || headerRow + headerSpan >= MAX_ROWS) {
                throw new IllegalArgumentException("Invalid template layout");
            }
            Sheet src = original.getSheetAt(sheetIndex);
            if (original.isSheetHidden(sheetIndex) || original.isSheetVeryHidden(sheetIndex))
                throw new IllegalArgumentException("不能保存隐藏工作表");
            if (src.getLastRowNum() >= MAX_ROWS) throw new IllegalArgumentException("表格样式超过 2000 行");
            int dataStart = detailRows0.isEmpty() ? headerRow + headerSpan : Collections.min(detailRows0);
            if (dataStart < headerRow + headerSpan || dataStart >= MAX_ROWS) throw new IllegalArgumentException("Invalid data rows");
            int blockRows = detailBlockRows(src, dataStart, detailRows0);
            int dataEnd = detailRows0.isEmpty() ? inferDataEnd(src, dataStart)
                    : Collections.max(detailRows0) + blockRows - 1;
            if (dataEnd >= MAX_ROWS) throw new IllegalArgumentException("Invalid data rows");
            // Intake deliberately treats unknown financial headings as reference data. An export mapping is
            // different: exact discount headings must display this saved quotation's current discount.
            for (int row = headerRow; row < headerRow + headerSpan; row++) {
                Row heading = src.getRow(row); if (heading == null || heading.getZeroHeight()) continue;
                for (Cell cell : heading) {
                    if (cell.getCellType() != CellType.STRING || src.isColumnHidden(cell.getColumnIndex())) continue;
                    if (Set.of("discount", "discountrate", "折扣", "折扣率").contains(normalize(cell.getStringCellValue()))) {
                        String column = DocumentGrid.columnLetter(cell.getColumnIndex());
                        roles.put(column, "DISCOUNT"); extraHeaders.remove(column);
                    }
                }
            }
            Sheet out = clean.createSheet("报价单");
            Map<Integer, CellStyle> styles = new HashMap<>();
            Map<Integer, Font> fonts = new HashMap<>();
            DataFormatter formatter = new DataFormatter(Locale.ROOT);
            int maxRow = Math.min(src.getLastRowNum(), MAX_ROWS - 1);
            int maxColumn = 0;
            for (Row r : src) {
                if (r.getRowNum() > maxRow) break;
                if (r.getZeroHeight()) continue;
                if (r.getLastCellNum() > MAX_COLUMNS) throw new IllegalArgumentException("表格样式超过 100 列");
                maxColumn = Math.max(maxColumn, Math.min(Math.max(0, r.getLastCellNum()), MAX_COLUMNS));
                Row target = out.createRow(r.getRowNum());
                target.setHeight(r.getHeight());
                for (Cell c : r) {
                    if (c.getColumnIndex() >= MAX_COLUMNS || src.isColumnHidden(c.getColumnIndex())) continue;
                    Cell tc = target.createCell(c.getColumnIndex(), CellType.BLANK);
                    tc.setCellStyle(styles.computeIfAbsent((int) c.getCellStyle().getIndex(), ignored ->
                            copyStyle(original, clean, c.getCellStyle(), fonts)));
                    String text = c.getCellType() == CellType.STRING ? formatter.formatCellValue(c).strip() : "";
                    // Only column headings and exact structural labels survive. No formulas, cached numbers, images,
                    // comments, hyperlinks, names, hidden sheets, print headers, addresses or original metadata.
                    if (r.getRowNum() >= headerRow && r.getRowNum() < headerRow + headerSpan && text.length() <= 100
                            && !text.contains("@") && !text.matches(".*\\d{7,}.*")) {
                        tc.setCellValue(text);
                    } else if (SAFE_LABELS.contains(text.toLowerCase(Locale.ROOT))) {
                        tc.setCellValue(text);
                    }
                }
            }
            for (int col = 0; col < maxColumn; col++) {
                out.setColumnWidth(col, src.getColumnWidth(col));
                out.setColumnHidden(col, src.isColumnHidden(col));
            }
            Set<String> features = new TreeSet<>();
            for (int col = 0; col < maxColumn; col++) features.add("width:" + col + ":" + Math.round(src.getColumnWidth(col) / 256.0));
            for (int row = headerRow; row < headerRow + headerSpan; row++) {
                Row r = src.getRow(row); if (r == null) continue;
                for (Cell c : r) {
                    if (c.getColumnIndex() >= MAX_COLUMNS) continue;
                    CellStyle st = c.getCellStyle(); Font f = original.getFontAt(st.getFontIndex());
                    Cell cleanHeading = getCell(out, row, c.getColumnIndex());
                    if (cleanHeading.getCellType() == CellType.STRING)
                        features.add("label:" + (row - headerRow) + ":" + c.getColumnIndex() + ":" + normalize(cleanHeading.getStringCellValue()));
                    features.add("style:" + row + ":" + c.getColumnIndex() + ":" + st.getFillForegroundColor()
                            + ":" + st.getFillPattern() + ":" + f.getFontName() + ":" + f.getFontHeight() + ":" + f.getBold()
                            + ":" + styleIdentity(st));
                }
            }
            for (int row = dataStart; row < dataStart + blockRows; row++) {
                Row r = out.getRow(row); if (r == null) continue;
                features.add("detail-height:" + (row - dataStart) + ":" + r.getHeight());
                for (Cell c : r) features.add("detail-style:" + (row - dataStart) + ":" + c.getColumnIndex()
                        + ":" + styleIdentity(c.getCellStyle()));
            }
            for (var entry : roles.entrySet()) {
                features.add("role:" + entry.getKey() + ":" + entry.getValue());
            }
            for (var entry : extraHeaders.entrySet()) {
                features.add("extra:" + entry.getKey() + ":" + normalize(entry.getValue()));
            }
            for (int i = 0; i < src.getNumMergedRegions(); i++) {
                CellRangeAddress region = src.getMergedRegion(i);
                if (region.getLastRow() <= maxRow && region.getLastColumn() < MAX_COLUMNS) {
                    out.addMergedRegion(region.copy());
                    // Detail-row counts vary; only fixed header geometry defines template identity.
                    if (region.getLastRow() < headerRow + headerSpan) features.add("merge:" + region.formatAsString());
                }
            }
            out.getPrintSetup().setLandscape(src.getPrintSetup().getLandscape());
            out.getPrintSetup().setPaperSize(src.getPrintSetup().getPaperSize());
            out.getPrintSetup().setFitWidth(src.getPrintSetup().getFitWidth());
            out.getPrintSetup().setFitHeight(src.getPrintSetup().getFitHeight());
            out.setFitToPage(src.getFitToPage());
            out.setHorizontallyCenter(src.getHorizontallyCenter());
            for (PageMargin margin : PageMargin.values()) out.setMargin(margin, src.getMargin(margin));
            features.add("header:" + headerRow + ":" + headerSpan);
            features.add("columns:" + maxColumn);
            features.add("paper:" + src.getPrintSetup().getPaperSize() + ":" + src.getPrintSetup().getLandscape());
            Map<String, Object> mapping = new LinkedHashMap<>();
            mapping.put("headerRow", headerRow);
            mapping.put("headerSpan", headerSpan);
            mapping.put("dataRow", dataStart);
            mapping.put("dataEndRow", dataEnd);
            mapping.put("blockRows", blockRows);
            mapping.put("schemaVersion", 2);
            mapping.put("roles", roles);
            Map<String, String> roleHeaders = new LinkedHashMap<>();
            for (String column : roles.keySet()) {
                Cell cell = getCell(out, headerRow + headerSpan - 1, DocumentGrid.columnIndex(column));
                String label = cell.getCellType() == CellType.STRING ? cell.getStringCellValue() : "";
                if (!label.isBlank()) roleHeaders.put(column, label);
            }
            mapping.put("roleHeaders", roleHeaders);
            mapping.put("extraHeaders", extraHeaders);
            mapping.put("maxColumn", maxColumn);
            // Recognize labels before the table; keep only their field identity, never original values.
            Map<String, String> headerCells = new LinkedHashMap<>();
            boolean buyerSection = false;
            for (Row r : src) {
                if (r.getRowNum() >= headerRow) break;
                if (r.getZeroHeight()) continue;
                for (Cell c : r) {
                    if (src.isColumnHidden(c.getColumnIndex())) continue;
                    if (c.getCellType() != CellType.STRING || c.getColumnIndex() >= MAX_COLUMNS - 1) continue;
                    String sourceLabel = c.getStringCellValue();
                    String normalizedLabel = normalize(sourceLabel.split("[:：]", 2)[0]);
                    if (Set.of("seller", "supplier", "from", "卖方", "供方", "卖家").contains(normalizedLabel)) buyerSection = false;
                    String role = headerRole(sourceLabel);
                    if (role == null) continue;
                    if ("buyerName".equals(role)) buyerSection = true;
                    boolean explicitCustomerLabel = normalizedLabel.startsWith("customer") || normalizedLabel.startsWith("buyer")
                            || normalizedLabel.startsWith("客户") || normalizedLabel.startsWith("买方");
                    if (Set.of("buyerAddress", "contactName", "email", "phone").contains(role)
                            && !buyerSection && !explicitCustomerLabel) continue;
                    Cell targetLabel = getCell(out, r.getRowNum(), c.getColumnIndex());
                    targetLabel.setCellValue(labelFor(role));
                    CellRangeAddress labelMerge = mergeAt(src, r.getRowNum(), c.getColumnIndex());
                    int valueColumn = labelMerge == null ? c.getColumnIndex() + 1 : labelMerge.getLastColumn() + 1;
                    boolean inline = c.getStringCellValue().matches("(?s).*[:：].+".strip());
                    String address;
                    if (inline || valueColumn >= maxColumn) {
                        address = new CellReference(r.getRowNum(), c.getColumnIndex()).formatAsString();
                        targetLabel.setBlank();
                    } else {
                        CellRangeAddress valueMerge = mergeAt(src, r.getRowNum(), valueColumn);
                        address = valueMerge == null ? new CellReference(r.getRowNum(), valueColumn).formatAsString()
                                : new CellReference(valueMerge.getFirstRow(), valueMerge.getFirstColumn()).formatAsString();
                    }
                    headerCells.putIfAbsent(role, address);
                    features.add("field:" + role + ":" + address);
                }
            }
            mapping.put("headerCells", headerCells);
            if (src.getRepeatingRows() != null && src.getRepeatingRows().getLastRow() < dataStart)
                out.setRepeatingRows(src.getRepeatingRows().copy());
            else out.setRepeatingRows(new CellRangeAddress(headerRow, headerRow + headerSpan - 1, -1, -1));
            out.setDisplayGridlines(src.isDisplayGridlines());
            out.setPrintGridlines(src.isPrintGridlines());
            out.setVerticallyCenter(src.getVerticallyCenter());
            out.getPrintSetup().setScale(src.getPrintSetup().getScale());
            out.getPrintSetup().setNoColor(src.getPrintSetup().getNoColor());
            out.getPrintSetup().setLeftToRight(src.getPrintSetup().getLeftToRight());
            out.getPrintSetup().setUsePage(src.getPrintSetup().getUsePage());
            features.add("block:" + blockRows);
            for (CellRangeAddress merge : out.getMergedRegions()) {
                if (merge.getFirstRow() >= dataStart && merge.getLastRow() < dataStart + blockRows)
                    features.add("detail-merge:" + (merge.getFirstRow() - dataStart) + ":" + (merge.getLastRow() - dataStart)
                            + ":" + merge.getFirstColumn() + ":" + merge.getLastColumn());
                if (merge.getFirstRow() > dataEnd)
                    features.add("footer-merge:" + (merge.getFirstRow() - dataEnd) + ":" + (merge.getLastRow() - dataEnd)
                            + ":" + merge.getFirstColumn() + ":" + merge.getLastColumn());
            }
            return new Candidate(bytes(clean), hash(String.join("\n", features)), mapping, features);
        } catch (Exception e) {
            throw new IllegalArgumentException("无法保存此文件的表格样式", e);
        }
    }

    private static void validateColumns(Map<String, String> columns) {
        if (columns == null || columns.size() > MAX_COLUMNS) throw new IllegalArgumentException("Invalid columns");
        for (var entry : columns.entrySet()) {
            int col = DocumentGrid.columnIndex(entry.getKey());
            if (col < 0 || col >= MAX_COLUMNS || entry.getValue() == null) throw new IllegalArgumentException("Invalid column");
        }
    }
    private static int detailBlockRows(Sheet sheet, int first, List<Integer> rows) {
        int size = 1;
        for (CellRangeAddress merge : sheet.getMergedRegions())
            if (merge.getFirstRow() == first) size = Math.max(size, merge.getLastRow() - first + 1);
        if (size > 8) return 1;
        for (int row : rows) if (row != first && row < first + size) return 1;
        return size;
    }
    private static int inferDataEnd(Sheet sheet, int start) {
        for (Row row : sheet) {
            if (row.getRowNum() <= start) continue;
            for (Cell c : row) if (c.getCellType() == CellType.STRING && SAFE_LABELS.contains(c.getStringCellValue().strip().toLowerCase(Locale.ROOT)))
                return row.getRowNum() - 1;
        }
        return Math.max(start, sheet.getLastRowNum());
    }
    private static CellRangeAddress mergeAt(Sheet sheet, int row, int column) {
        for (CellRangeAddress m : sheet.getMergedRegions()) if (m.isInRange(row, column)) return m;
        return null;
    }
    private static String styleIdentity(CellStyle style) {
        String rgb = style instanceof XSSFCellStyle x && x.getFillForegroundXSSFColor() != null
                ? x.getFillForegroundXSSFColor().getARGBHex() : Integer.toString(style.getFillForegroundColor());
        return rgb + ":" + style.getFillPattern() + ":" + style.getAlignment() + ":" + style.getVerticalAlignment()
                + ":" + style.getBorderTop() + ":" + style.getBorderBottom() + ":" + style.getBorderLeft()
                + ":" + style.getBorderRight() + ":" + safeNumberFormat(style.getDataFormatString());
    }
    private static String safeNumberFormat(String format) {
        if (format == null) return "General";
        // Quoted custom-format text can contain a previous customer's name or identifier.
        // Built-in display symbols are safe; unknown literal text is not part of a reusable style.
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("\"([^\"]*)\"").matcher(format);
        while (m.find()) if (!m.group(1).matches("[ $€£¥%.,()+/−-]*|USD|EUR|CNY|RMB|HKD|GBP")) return "General";
        return format;
    }
    private record CellSnapshot(int column, CellStyle style, String text) { }
    private record RowSnapshot(short height, List<CellSnapshot> cells) { }
    private static List<RowSnapshot> snapshots(Sheet sheet, int first, int last, int columns) {
        List<RowSnapshot> out = new ArrayList<>();
        for (int index = first; index <= last; index++) {
            Row row = sheet.getRow(index); List<CellSnapshot> cells = new ArrayList<>();
            if (row != null) for (Cell c : row) if (c.getColumnIndex() < columns)
                cells.add(new CellSnapshot(c.getColumnIndex(), c.getCellStyle(),
                        c.getCellType() == CellType.STRING ? c.getStringCellValue() : ""));
            out.add(new RowSnapshot(row == null ? sheet.getDefaultRowHeight() : row.getHeight(), cells));
        }
        return out;
    }
    private static void restore(Sheet sheet, List<RowSnapshot> rows, int start) {
        for (int i = 0; i < rows.size(); i++) {
            Row row = sheet.createRow(start + i); RowSnapshot snapshot = rows.get(i); row.setHeight(snapshot.height());
            for (CellSnapshot c : snapshot.cells()) {
                Cell cell = row.createCell(c.column()); cell.setCellStyle(c.style());
                if (!c.text().isEmpty()) cell.setCellValue(c.text());
            }
        }
    }
    private static CellRangeAddress shift(CellRangeAddress original, int delta) {
        return new CellRangeAddress(original.getFirstRow() + delta, original.getLastRow() + delta,
                original.getFirstColumn(), original.getLastColumn());
    }

    private static CellStyle copyStyle(Workbook original, XSSFWorkbook clean, CellStyle source, Map<Integer, Font> fonts) {
        CellStyle target = clean.createCellStyle();
        if (original instanceof XSSFWorkbook && Objects.equals(source.getDataFormatString(), safeNumberFormat(source.getDataFormatString()))) {
            target.cloneStyleFrom(source);
            target.setDataFormat(clean.createDataFormat().getFormat(safeNumberFormat(source.getDataFormatString())));
            return target;
        }
        target.setAlignment(source.getAlignment()); target.setVerticalAlignment(source.getVerticalAlignment());
        target.setWrapText(source.getWrapText()); target.setRotation(source.getRotation());
        target.setIndention(source.getIndention()); target.setShrinkToFit(source.getShrinkToFit());
        target.setBorderBottom(source.getBorderBottom()); target.setBorderTop(source.getBorderTop());
        target.setBorderLeft(source.getBorderLeft()); target.setBorderRight(source.getBorderRight());
        target.setBottomBorderColor(source.getBottomBorderColor()); target.setTopBorderColor(source.getTopBorderColor());
        target.setLeftBorderColor(source.getLeftBorderColor()); target.setRightBorderColor(source.getRightBorderColor());
        target.setFillForegroundColor(source.getFillForegroundColor()); target.setFillBackgroundColor(source.getFillBackgroundColor());
        target.setFillPattern(source.getFillPattern());
        target.setDataFormat(clean.createDataFormat().getFormat(safeNumberFormat(source.getDataFormatString())));
        target.setFont(fonts.computeIfAbsent(source.getFontIndex(), index -> {
            Font f = original.getFontAt(index); Font tf = clean.createFont();
            tf.setFontName(f.getFontName()); tf.setFontHeight(f.getFontHeight()); tf.setBold(f.getBold());
            tf.setItalic(f.getItalic()); tf.setStrikeout(f.getStrikeout()); tf.setColor(f.getColor());
            tf.setUnderline(f.getUnderline()); tf.setTypeOffset(f.getTypeOffset()); return tf;
        }));
        return target;
    }

    @SuppressWarnings("unchecked")
    public static byte[] render(byte[] template, Map<String, Object> mapping, List<ExportLine> lines,
                                Map<String, String> header, String total) {
        if (lines.size() > 500) throw new IllegalArgumentException("报价明细最多导出 500 行");
        try (XSSFWorkbook workbook = new XSSFWorkbook(new ByteArrayInputStream(template))) {
            Sheet sheet = workbook.getSheetAt(0);
            int start = ((Number) mapping.get("dataRow")).intValue();
            Map<String, String> roles = (Map<String, String>) mapping.get("roles");
            Map<String, String> extras = new LinkedHashMap<>((Map<String, String>) mapping.getOrDefault("extraHeaders", Map.of()));
            Map<String, String> roleHeaders = (Map<String, String>) mapping.getOrDefault("roleHeaders", Map.of());
            Map<String, String> fields = (Map<String, String>) mapping.getOrDefault("headerCells", Map.of());
            int columns = ((Number) mapping.getOrDefault("maxColumn", 20)).intValue();
            Set<String> included = new HashSet<>();
            for (String label : extras.values()) included.add(normalize(label));
            for (String label : roleHeaders.values()) included.add(normalize(label));
            int headerRow = ((Number) mapping.get("headerRow")).intValue();
            int headerSpan = ((Number) mapping.get("headerSpan")).intValue();
            for (ExportLine line : Boolean.TRUE.equals(mapping.get("projectionApplied")) ? List.<ExportLine>of() : lines) for (var value : line.values().entrySet()) {
                if (!value.getKey().startsWith("extra-label:") || !included.add(normalize(value.getValue()))) continue;
                if (columns >= MAX_COLUMNS) throw new IllegalArgumentException("额外列超过模板列数上限");
                String letter = DocumentGrid.columnLetter(columns);
                extras.put(letter, value.getValue());
                Cell heading = getCell(sheet, headerRow + headerSpan - 1, columns);
                heading.setCellValue(value.getValue());
                if (columns > 0) heading.setCellStyle(getCell(sheet, headerRow + headerSpan - 1, columns - 1).getCellStyle());
                sheet.setColumnWidth(columns, 18 * 256);
                columns++;
            }
            int blockRows = ((Number) mapping.getOrDefault("blockRows", 1)).intValue();
            int end = ((Number) mapping.getOrDefault("dataEndRow", sheet.getLastRowNum())).intValue();
            if (blockRows < 1 || blockRows > 8 || columns < 1 || columns > MAX_COLUMNS || start < 0 || end < start)
                throw new IllegalArgumentException("Invalid stored template layout");
            validateColumns(roles); validateColumns(extras);
            List<RowSnapshot> sample = snapshots(sheet, start, start + blockRows - 1, columns);
            List<RowSnapshot> footer = snapshots(sheet, end + 1, sheet.getLastRowNum(), columns);
            List<CellRangeAddress> detailMerges = new ArrayList<>(), footerMerges = new ArrayList<>();
            for (CellRangeAddress merge : sheet.getMergedRegions()) {
                if (merge.getFirstRow() >= start && merge.getLastRow() < start + blockRows) detailMerges.add(merge.copy());
                if (merge.getFirstRow() > end) footerMerges.add(merge.copy());
            }
            for (int i = sheet.getNumMergedRegions() - 1; i >= 0; i--)
                if (sheet.getMergedRegion(i).getLastRow() >= start) sheet.removeMergedRegion(i);
            for (int row = sheet.getLastRowNum(); row >= start; row--) {
                Row r = sheet.getRow(row); if (r != null) sheet.removeRow(r);
            }
            int newFooter = start + lines.size() * blockRows;
            if (newFooter + footer.size() > MAX_ROWS + 500 * 8) throw new IllegalArgumentException("导出行数超过上限");
            for (int i = 0; i < lines.size(); i++) {
                int target = start + i * blockRows;
                restore(sheet, sample, target);
                for (CellRangeAddress merge : detailMerges) sheet.addMergedRegion(shift(merge, target - start));
                for (var entry : roles.entrySet()) {
                    String role = entry.getValue();
                    String value = "LINE_NO".equals(role) ? Integer.toString(i + 1) : lines.get(i).values().get(role);
                    if ("UNIT_PRICE".equals(role) && !roles.containsValue("DISCOUNT") && !Boolean.TRUE.equals(mapping.get("projectionApplied")))
                        value = lines.get(i).values().getOrDefault("UNIT_PRICE_NET", value);
                    if (value == null && roleHeaders.containsKey(entry.getKey()))
                        value = lines.get(i).values().get("extra:" + normalize(roleHeaders.get(entry.getKey())));
                    setValue(getCell(sheet, target, DocumentGrid.columnIndex(entry.getKey())), value,
                            Set.of("QTY", "UNIT_PRICE", "AMOUNT", "DISCOUNT", "PCS_PER_CTN", "CTN").contains(role));
                }
                for (var entry : extras.entrySet()) {
                    String value = lines.get(i).values().get("extra:" + normalize(entry.getValue()));
                    setValue(getCell(sheet, target, DocumentGrid.columnIndex(entry.getKey())), value, false);
                }
            }
            restore(sheet, footer, newFooter);
            for (CellRangeAddress merge : footerMerges) sheet.addMergedRegion(shift(merge, newFooter - end - 1));
            List<String> inlineFields = (List<String>) mapping.getOrDefault("inlineHeaderFields", List.of());
            Map<String, List<Map.Entry<String, String>>> headerGroups = new LinkedHashMap<>();
            for (var entry : fields.entrySet()) headerGroups.computeIfAbsent(entry.getValue(), ignored -> new ArrayList<>()).add(entry);
            for (var group : headerGroups.entrySet()) {
                CellReference ref = new CellReference(group.getKey());
                if (ref.getRow() >= start) throw new IllegalArgumentException("Header field overlaps details");
                List<String> values = new ArrayList<>();
                for (var entry : group.getValue()) {
                    String value = header.get(entry.getKey());
                    if (value == null || value.isBlank()) continue;
                    values.add((group.getValue().size() > 1 || inlineFields.contains(entry.getKey()) ? labelFor(entry.getKey()) + ": " : "") + value);
                }
                setValue(getCell(sheet, ref.getRow(), ref.getCol()), String.join(" / ", values), false);
            }
            int amountCol = roles.entrySet().stream().filter(e -> "AMOUNT".equals(e.getValue()))
                    .mapToInt(e -> DocumentGrid.columnIndex(e.getKey())).findFirst().orElse(Math.max(1, columns - 1));
            int totalAt = -1;
            for (int row = newFooter; row <= sheet.getLastRowNum(); row++) {
                Row r = sheet.getRow(row); if (r == null) continue;
                for (Cell cell : r) if (cell.getCellType() == CellType.STRING && Set.of("total", "合计", "总计")
                        .contains(cell.getStringCellValue().strip().toLowerCase(Locale.ROOT))) totalAt = row;
            }
            if (totalAt < 0) {
                totalAt = Math.max(newFooter, sheet.getLastRowNum() + 1);
                getCell(sheet, totalAt, amountCol == 0 ? 1 : 0).setCellValue("Total / 合计");
            }
            CellRangeAddress totalMerge = mergeAt(sheet, totalAt, amountCol);
            if (totalMerge != null && totalMerge.getFirstColumn() < amountCol) {
                // A source total caption spanning the amount column cannot also hold the new numeric total.
                totalAt = sheet.getLastRowNum() + 1;
                getCell(sheet, totalAt, amountCol == 0 ? 1 : 0).setCellValue("Total / 合计");
            }
            if (!Boolean.FALSE.equals(mapping.get("showTotal"))) setValue(getCell(sheet, totalAt, amountCol), total, true);
            else {
                for (int row = newFooter; row <= sheet.getLastRowNum(); row++) {
                    Row footerRow = sheet.getRow(row); if (footerRow == null) continue;
                    for (Cell cell : footerRow) if (cell.getCellType() == CellType.STRING &&
                            (cell.getStringCellValue().contains("Total / 合计") || Set.of("total", "subtotal", "合计", "小计", "总计")
                                    .contains(cell.getStringCellValue().strip().toLowerCase(Locale.ROOT)))) cell.setBlank();
                }
            }
            Map<String, String> monetaryRoles = new LinkedHashMap<>(roles);
            for (var extra : extras.entrySet()) {
                String key = "extra-money:" + normalize(extra.getValue());
                if (lines.stream().anyMatch(line -> line.values().containsKey(key))) monetaryRoles.put(extra.getKey(), "AMOUNT");
            }
            List<String> projectedMoney = (List<String>) mapping.getOrDefault("moneyRoles", List.of());
            for (var entry : roles.entrySet()) if (projectedMoney.contains(entry.getValue())) monetaryRoles.put(entry.getKey(), "AMOUNT");
            applyCurrentCurrency(workbook, sheet, monetaryRoles, headerRow, headerSpan, header.get("currencyCode"));
            workbook.setPrintArea(0, 0, Math.max(0, columns - 1), 0, Math.max(totalAt, sheet.getLastRowNum()));
            return bytes(workbook);
        } catch (Exception e) { throw new IllegalArgumentException("报价模板生成失败", e); }
    }

    private static void applyCurrentCurrency(XSSFWorkbook workbook, Sheet sheet, Map<String, String> roles,
                                             int headerRow, int headerSpan, String currency) {
        String code = currency == null ? "" : currency.strip();
        java.util.regex.Pattern oldCurrency = java.util.regex.Pattern.compile(
                "(?i)(?<![A-Z])(?:USD|US\\$|CNY|RMB|EUR|GBP|HKD|JPY|KRW|AUD|CAD|CHF|SGD|INR|AED|SAR|THB|VND)(?![A-Z])|[$€£¥￥₩₹]");
        // Keep monetary values in the saved quotation's authoritative currency; no exchange conversion here.
        Map<Short, CellStyle> cleanStyles = new HashMap<>();
        for (var entry : roles.entrySet()) {
            if (!Set.of("UNIT_PRICE", "AMOUNT").contains(entry.getValue())) continue;
            int column = DocumentGrid.columnIndex(entry.getKey());
            for (int row = headerRow; row < headerRow + headerSpan; row++) {
                Cell heading = getCell(sheet, row, column);
                if (heading.getCellType() != CellType.STRING) continue;
                String label = oldCurrency.matcher(heading.getStringCellValue()).replaceAll("")
                        .replaceAll("\\(\\s*\\)|（\\s*）", "").strip();
                if (!code.isEmpty() && row == headerRow + headerSpan - 1) label += " (" + code + ")";
                heading.setCellValue(label);
            }
            for (Row row : sheet) {
                if (row.getRowNum() < headerRow + headerSpan) continue;
                Cell cell = row.getCell(column); if (cell == null) continue;
                short styleIndex = cell.getCellStyle().getIndex();
                CellStyle clean = cleanStyles.computeIfAbsent(styleIndex, ignored -> {
                    CellStyle style = workbook.createCellStyle(); style.cloneStyleFrom(cell.getCellStyle());
                    style.setDataFormat(workbook.createDataFormat().getFormat("#,##0.###############")); return style;
                });
                cell.setCellStyle(clean);
            }
        }
    }

    public static Candidate defaultTemplate() {
        try (XSSFWorkbook wb = new XSSFWorkbook()) {
            Sheet sheet = wb.createSheet("报价单");
            Row h = sheet.createRow(4);
            String[] labels = {"货品名称", "英文名称", "编号", "颜色", "数量", "单位", "单价", "折扣", "金额", "备注"};
            String[] roles = {"DESCRIPTION_ALT", "DESCRIPTION", "PART_NO", "COLOR", "QTY", "UNIT", "UNIT_PRICE", "DISCOUNT", "AMOUNT", "REMARK"};
            Map<String, String> map = new LinkedHashMap<>();
            CellStyle style = wb.createCellStyle(); Font font = wb.createFont(); font.setBold(true); style.setFont(font);
            for (int i = 0; i < labels.length; i++) {
                Cell c = h.createCell(i); c.setCellValue(labels[i]); c.setCellStyle(style);
                sheet.setColumnWidth(i, (i < 2 ? 28 : 16) * 256); map.put(DocumentGrid.columnLetter(i), roles[i]);
            }
            sheet.createRow(0).createCell(0).setCellValue("Quotation");
            sheet.createRow(1).createCell(0).setCellValue("Buyer");
            sheet.createRow(2).createCell(0).setCellValue("Quote No.");
            return capture(bytes(wb), 0, 4, 1, map, Map.of());
        } catch (Exception e) { throw new IllegalStateException(e); }
    }

    public static double similarity(Set<String> a, Set<String> b) {
        if (a.equals(b)) return 1;
        Set<String> union = new HashSet<>(a); union.addAll(b);
        Set<String> intersection = new HashSet<>(a); intersection.retainAll(b);
        return union.isEmpty() ? 0 : (double) intersection.size() / union.size();
    }
    public static String normalize(String value) {
        return value == null ? "" : java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFKC)
                .toLowerCase(Locale.ROOT).replaceAll("[\\s\\p{P}]+", "");
    }
    private static String headerRole(String value) {
        String text = value.strip().toLowerCase(Locale.ROOT).split("[:：]", 2)[0].strip();
        return switch (text) {
            case "buyer", "customer", "to", "bill to", "客户", "买方" -> "buyerName";
            case "address", "customer address", "buyer address", "客户地址", "地址" -> "buyerAddress";
            case "contact", "attention", "attn", "联系人" -> "contactName";
            case "email", "e-mail", "customer email", "buyer email", "客户邮箱", "邮箱" -> "email";
            case "tel", "telephone", "phone", "customer phone", "buyer phone", "客户电话", "电话" -> "phone";
            case "quote no.", "quote no", "quotation no", "invoice no", "invoice no.", "单号", "报价单号" -> "docNo";
            case "date", "日期" -> "docDate";
            default -> null;
        };
    }
    private static String labelFor(String role) {
        return switch (role) { case "buyerName" -> "Buyer"; case "buyerAddress" -> "Address";
            case "contactName" -> "Contact"; case "email" -> "Email"; case "phone" -> "Phone";
            case "docNo" -> "Quote No."; default -> "Date"; };
    }
    private static Cell getCell(Sheet sheet, int row, int col) {
        if (row < 0 || row >= MAX_ROWS + 500 * 8 || col < 0 || col >= MAX_COLUMNS) throw new IllegalArgumentException("Invalid cell");
        Row r = sheet.getRow(row); if (r == null) r = sheet.createRow(row);
        Cell c = r.getCell(col); return c == null ? r.createCell(col) : c;
    }
    private static void setValue(Cell cell, String text, boolean numeric) {
        if (text == null || text.isBlank()) return;
        // Excel supports 15 significant decimal digits; longer exact values stay textual, never rounded silently.
        if (numeric) {
            try { java.math.BigDecimal value = new java.math.BigDecimal(text);
                if (value.stripTrailingZeros().precision() <= 15) { cell.setCellValue(value.doubleValue()); return; }
            } catch (NumberFormatException ignored) { }
        }
        cell.setCellValue(text); // setCellValue never interprets leading =/+/-/@ as a formula.
    }
    private static byte[] bytes(Workbook workbook) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); workbook.write(out); return out.toByteArray();
    }
    private static String hash(String text) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
    }
}
