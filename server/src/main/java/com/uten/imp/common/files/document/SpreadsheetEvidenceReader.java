package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.List;

/** Bounded cached-value/formula evidence. No formula evaluator, external I/O, macros or hidden inputs. */
public final class SpreadsheetEvidenceReader {
    private SpreadsheetEvidenceReader() {}
    public record Value(String address, String text, String formula, boolean externalReference) {}
    public record Row(int number, List<Value> cells) {}
    public record Sheet(String name, List<Row> rows) {}
    public record Workbook(List<Sheet> sheets, int externalReferenceCount) {}

    public static Workbook read(byte[] bytes) {
        return DocumentParseGate.run(deadline -> {
            ZipSafety.inspectSpreadsheetEvidence(bytes);
            try (var workbook = new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
                if (workbook.getNumberOfSheets() > 16) throw ZipSafety.rejected("成本表最多包含 16 个工作表");
                List<Sheet> sheets = new ArrayList<>();
                int totalCells = 0, external = 0;
                for (int s = 0; s < workbook.getNumberOfSheets(); s++) {
                    if (workbook.isSheetHidden(s) || workbook.isSheetVeryHidden(s)) continue;
                    var source = workbook.getSheetAt(s);
                    if (source.getLastRowNum() >= 5000) throw ZipSafety.rejected("单个成本工作表最多 5000 行");
                    List<Row> rows = new ArrayList<>();
                    for (var row : source) {
                        deadline.check();
                        if (row.getZeroHeight()) continue;
                        if (row.getLastCellNum() > 128) throw ZipSafety.rejected("成本表最多 128 列");
                        List<Value> values = new ArrayList<>();
                        for (Cell cell : row) {
                            if (source.isColumnHidden(cell.getColumnIndex())) continue;
                            if (++totalCells > 250_000) throw ZipSafety.rejected("成本表单元格过多，请按产品拆分");
                            String formula = cell.getCellType() == CellType.FORMULA ? cell.getCellFormula() : null;
                            String value = cached(cell);
                            if (value.length() > 4096 || formula != null && formula.length() > 4096)
                                throw ZipSafety.rejected("成本表单元格内容过长");
                            if (value.isBlank() && formula == null) continue;
                            boolean linked = formula != null && (formula.contains("[") || formula.matches("(?i).*(WEBSERVICE|HYPERLINK|RTD|DDE).*"));
                            if (linked) external++;
                            values.add(new Value(cell.getAddress().formatAsString(), value, formula, linked));
                        }
                        if (!values.isEmpty()) rows.add(new Row(row.getRowNum() + 1, List.copyOf(values)));
                    }
                    if (!rows.isEmpty()) sheets.add(new Sheet(source.getSheetName(), List.copyOf(rows)));
                }
                return new Workbook(List.copyOf(sheets), external);
            } catch (ApiException error) { throw error; }
            catch (Exception error) { throw ZipSafety.rejected("无法读取成本表，请使用未加密的 .xlsx 文件"); }
        });
    }

    private static String cached(Cell cell) {
        CellType type = cell.getCellType() == CellType.FORMULA ? cell.getCachedFormulaResultType() : cell.getCellType();
        return switch (type) {
            case STRING -> cell.getStringCellValue().strip();
            case NUMERIC -> cell instanceof org.apache.poi.xssf.usermodel.XSSFCell x ? x.getRawValue()
                    : java.math.BigDecimal.valueOf(cell.getNumericCellValue()).toPlainString();
            case BOOLEAN -> Boolean.toString(cell.getBooleanCellValue());
            case ERROR -> "#ERROR";
            default -> "";
        };
    }
}
