package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.FillPatternType;
import org.apache.poi.ss.usermodel.Font;
import org.apache.poi.ss.usermodel.HorizontalAlignment;
import org.apache.poi.ss.usermodel.IndexedColors;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.xssf.streaming.SXSSFWorkbook;
import org.springframework.stereotype.Service;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * 把「列定义 + 行」导出为 .xlsx 字节（SXSSF 流式，防几万行 OOM）。
 *
 * <p>格式约定(对齐前端 formatReportCell)：金额/数量 = 2 位小数、用量 (qty) = 常规格式按存储值全精度、
 * 日期 = yyyy-MM-dd、布尔 = 是/否、其余文本。
 * 表头加粗灰底居中、冻结首行、列宽按表头长度估。数值右对齐 + 千分位。
 *
 * <p>输入约定：报表行由 {@code execute().norm()} 归一化——日期已转 yyyy-MM-dd 字符串、金额为 BigDecimal/Number。
 */
@Service
public class XlsxExportService {

    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<ExportTableProjectionService> projections;

    public byte[] build(List<ExportColumn> columns, List<Map<String,Object>> rows,
                        TableColumnProjection projection, String allowedScope) {
        if(projection==null)return build(columns,rows);
        ExportPayload projected=projections.getObject().project(columns,rows,projection,allowedScope);
        return build(projected.columns(),projected.rows());
    }

    /** SXSSF 滚动窗口（同时在内存的行数；超出写临时文件）。 */
    private static final int ROW_ACCESS_WINDOW = 200;

    /** Multi-sheet snapshot export; this never rereads mutable platform values. */
    public byte[] buildDocument(ExportDocument document) {
        try (SXSSFWorkbook wb = new SXSSFWorkbook(ROW_ACCESS_WINDOW);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            CellStyle header = wb.createCellStyle();
            Font font = wb.createFont();
            font.setBold(true);
            header.setFont(font);
            header.setFillForegroundColor(IndexedColors.GREY_25_PERCENT.getIndex());
            header.setFillPattern(FillPatternType.SOLID_FOREGROUND);
            header.setDataFormat(wb.createDataFormat().getFormat("@"));
            CellStyle number = wb.createCellStyle();
            number.setDataFormat(wb.createDataFormat().getFormat("#,##0.00"));
            number.setAlignment(HorizontalAlignment.RIGHT);
            CellStyle exact = wb.createCellStyle();
            exact.setDataFormat(wb.createDataFormat().getFormat("General"));
            exact.setAlignment(HorizontalAlignment.RIGHT);
            CellStyle text = wb.createCellStyle();
            text.setDataFormat(wb.createDataFormat().getFormat("@"));
            var info = wb.createSheet("说明");
            int infoRow = 0;
            for (String value : java.util.stream.Stream.concat(java.util.stream.Stream.of(document.title()),
                    document.metadata().stream()).toList()) {
                Cell cell = info.createRow(infoRow++).createCell(0);
                cell.setCellValue(value);
                cell.setCellStyle(text);
            }
            info.setColumnWidth(0, 100 * 256);
            int sheetIndex = 1;
            for (ExportDocument.Section section : document.sections()) {
                String name = org.apache.poi.ss.util.WorkbookUtil.createSafeSheetName(section.name());
                if (wb.getSheet(name) != null) name = "表" + sheetIndex;
                Sheet sheet = wb.createSheet(name);
                Row labels = sheet.createRow(0);
                for (int c = 0; c < section.columns().size(); c++) {
                    ExportColumn column = section.columns().get(c);
                    Cell label = labels.createCell(c);
                    label.setCellValue(column.label());
                    label.setCellStyle(header);
                    int width = column.width() == null ? Math.max(12, Math.min(42, column.label().length() * 2 + 4))
                            : Math.max(8, Math.min(100, (int) Math.round(column.width() / 7)));
                    sheet.setColumnWidth(c, width * 256);
                }
                int rowIndex = 1;
                for (Map<String, Object> values : section.rows()) {
                    Row row = sheet.createRow(rowIndex++);
                    for (int c = 0; c < section.columns().size(); c++) {
                        ExportColumn column = section.columns().get(c);
                        writeCell(row.createCell(c), column.type(), values.get(column.key()), number, exact, text);
                    }
                }
                sheet.createFreezePane(0, 1);
                sheet.setRepeatingRows(new org.apache.poi.ss.util.CellRangeAddress(0, 0, -1, -1));
                sheet.getPrintSetup().setLandscape(true);
                sheet.setFitToPage(true);
                sheet.getPrintSetup().setFitWidth((short) 1);
                sheet.getPrintSetup().setFitHeight((short) 0);
                sheetIndex++;
            }
            wb.write(out);
            return out.toByteArray();
        } catch (IOException error) {
            throw new IllegalStateException("生成 Excel 失败", error);
        }
    }

    public byte[] build(List<ExportColumn> columns, List<Map<String, Object>> rows) {
        try (SXSSFWorkbook wb = new SXSSFWorkbook(ROW_ACCESS_WINDOW);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            // 样式：表头（加粗灰底居中）+ 数值（千分位 2 位小数）
            CellStyle headerStyle = wb.createCellStyle();
            Font headerFont = wb.createFont();
            headerFont.setBold(true);
            headerStyle.setFont(headerFont);
            headerStyle.setFillForegroundColor(IndexedColors.GREY_25_PERCENT.getIndex());
            headerStyle.setFillPattern(FillPatternType.SOLID_FOREGROUND);
            headerStyle.setAlignment(HorizontalAlignment.CENTER);
            headerStyle.setDataFormat(wb.createDataFormat().getFormat("@"));
            CellStyle numStyle = wb.createCellStyle();
            numStyle.setDataFormat(wb.createDataFormat().getFormat("#,##0.00"));
            // 用量：常规格式，整数不带小数点、小数不补零也不截断(与 BOM 导入按值读取互为往返)
            CellStyle qtyStyle = wb.createCellStyle();
            qtyStyle.setDataFormat(wb.createDataFormat().getFormat("General"));
            // 文本格式（DataFormat "@"）：强制 Excel/WPS 把字符串当字面文本，防 =cmd|'/c calc'!A1 / =HYPERLINK()
            // 公式注入（安全策略 §10.1「单元格按文本写防 =CMD() 公式注入」）。POI setCellValue(String) 虽写为
            // STRING 类型，但部分表格（WPS/旧 Excel）仍可能对前导 = + - @ \t \r 自动公式化；显式文本格式是权威防御，
            // 且不改变显示内容（区别于加单引号前缀）。AES-256 不防此——文件被合法查看者解密后才被解释。
            CellStyle textStyle = wb.createCellStyle();
            textStyle.setDataFormat(wb.createDataFormat().getFormat("@"));

            Sheet sheet = wb.createSheet("data");
            // 表头
            Row header = sheet.createRow(0);
            for (int i = 0; i < columns.size(); i++) {
                Cell c = header.createCell(i);
                c.setCellValue(columns.get(i).label());
                c.setCellStyle(headerStyle);
                // 列宽：按表头长度估，限 [10,50] 字符宽
                int w = columns.get(i).width()==null ? Math.min(50, Math.max(10, columns.get(i).label().length() + 4))
                        : Math.min(100, Math.max(6, (int)Math.round(columns.get(i).width()/7)));
                sheet.setColumnWidth(i, w * 256);
            }
            // 数据
            int r = 1;
            for (Map<String, Object> row : rows) {
                Row R = sheet.createRow(r++);
                for (int i = 0; i < columns.size(); i++) {
                    ExportColumn col = columns.get(i);
                    Object v = row == null ? null : row.get(col.key());
                    writeCell(R.createCell(i), col.type(), v, numStyle, qtyStyle, textStyle);
                }
            }
            sheet.createFreezePane(0, 1); // 冻结首行
            wb.write(out);
            return out.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("生成 Excel 失败", e);
        }
    }

    private static void writeCell(Cell cell, String type, Object v, CellStyle numStyle, CellStyle qtyStyle,
                                  CellStyle textStyle) {
        if (v == null) return;
        switch (type == null ? ExportColumn.TEXT : type) {
            case ExportColumn.MONEY, ExportColumn.NUMBER, ExportColumn.QTY -> {
                BigDecimal d = toBigDecimal(v);
                if (d != null) {
                    if(d.stripTrailingZeros().precision()>15) {
                        cell.setCellValue(d.toPlainString()); cell.setCellStyle(textStyle);
                    } else {
                        cell.setCellValue(d.doubleValue());
                        cell.setCellStyle(ExportColumn.MONEY.equals(type) ? numStyle : qtyStyle);
                    }
                } else {
                    // 非数值回退：按文本写，防公式注入
                    cell.setCellValue(Objects.toString(v));
                    cell.setCellStyle(textStyle);
                }
            }
            case ExportColumn.BOOL -> { cell.setCellValue(toBool(v) ? "是" : "否"); cell.setCellStyle(textStyle); }
            case ExportColumn.DATE -> { cell.setCellValue(toDateStr(v)); cell.setCellStyle(textStyle); }
            default -> { cell.setCellValue(Objects.toString(v)); cell.setCellStyle(textStyle); }
        }
    }

    private static BigDecimal toBigDecimal(Object v) {
        if (v instanceof BigDecimal b) return b;
        if (v instanceof Number n) return new BigDecimal(n.toString());
        if (v instanceof String s && !s.isBlank()) {
            try { return new BigDecimal(s.trim()); } catch (NumberFormatException ignored) {}
        }
        return null;
    }

    private static boolean toBool(Object v) {
        if (v instanceof Boolean b) return b;
        if (v instanceof Number n) return n.intValue() != 0;
        return "true".equalsIgnoreCase(Objects.toString(v)) || "1".equals(Objects.toString(v));
    }

    /** 报表 norm() 已把日期转成 yyyy-MM-dd 字符串；兼容 LocalDate/Date 直接 toString。 */
    private static String toDateStr(Object v) {
        if (v instanceof java.time.LocalDate d) return d.toString();
        if (v instanceof java.util.Date d) return new java.sql.Date(d.getTime()).toLocalDate().toString();
        return Objects.toString(v);
    }
}
