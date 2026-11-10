package com.uten.imp.common.importing;

import com.uten.imp.common.files.document.DocumentGrid;
import org.apache.poi.ss.usermodel.*;
import java.util.*;
import java.util.function.Function;

/** File-side column loss protection. Display names never authorize a business field. */
public final class ImportColumnGuard {
    public static final int VERSION = 1;
    private ImportColumnGuard() { }
    public record Header(int index, String label, String key) { }
    public record Issue(int rowNum, String column, String message) { }
    public static void requireValidated(int version) {
        if (version != VERSION) throw new com.uten.imp.common.web.ApiException(
                com.uten.imp.common.web.ErrorCode.CONFLICT,retiredPreviewMessage());
    }
    public static String retiredPreviewMessage() {
        return "旧检测缺少当前列映射安全校验。请保留旧批次，重新生成文件并重新检测通过后再导入；仅改文件名不会改变内容标识。原来源和回执保留";
    }

    public static List<Issue> inspect(List<Header> headers, Set<Integer> populated, int headerRow) {
        var issues = new ArrayList<Issue>();
        var first = new HashMap<String, Header>();
        var declared = new HashSet<Integer>();
        for (var header : headers) {
            declared.add(header.index());
            String label = label(header.label(), header.index());
            if (header.key() != null) {
                if (first.putIfAbsent(header.key(), header) != null)
                    issues.add(new Issue(headerRow + 1, label, "列「" + label + "」重复或与其他列同义，请只保留一列，不能按列顺序选择"));
            } else if (populated.contains(header.index())) {
                issues.add(unsupported(headerRow, label));
            }
        }
        for (int index : new TreeSet<>(populated))
            if (!declared.contains(index)) issues.add(unsupported(headerRow, label(null, index)));
        return List.copyOf(issues);
    }

    public static List<Issue> inspect(Sheet sheet, int headerRow, Function<String,String> resolver) {
        var headers = new ArrayList<Header>();
        Row header = sheet.getRow(headerRow);
        var formatter = new DataFormatter();
        if (header != null) for (Cell cell : header) {
            String raw = formatter.formatCellValue(cell);
            headers.add(new Header(cell.getColumnIndex(), raw, resolver.apply(raw)));
        }
        var populated = new HashSet<Integer>();
        for (Row row : sheet) if (row.getRowNum() > headerRow)
            for (Cell cell : row) if (hasContent(cell)) populated.add(cell.getColumnIndex());
        return inspect(headers, populated, headerRow);
    }

    /** Fixed financial templates already validate each known position; check the remainder. */
    public static List<Issue> inspectExtraColumns(DocumentGrid.Sheet sheet, int headerRow, int knownWidth) {
        var headers = new ArrayList<Header>();
        var header = sheet.row(headerRow);
        if (header != null) for (var cell : header.cells())
            headers.add(new Header(cell.col0(), cell.text(), cell.col0() < knownWidth ? "position:" + cell.col0() : null));
        var populated = new HashSet<Integer>();
        for (var row : sheet.rows()) if (row.index0() > headerRow)
            for (var cell : row.cells()) if (!cell.text().isBlank()) populated.add(cell.col0());
        return inspect(headers, populated, headerRow);
    }

    /** The value grid intentionally omits empty formula caches; imports must inspect the original cells. */
    public static List<Issue> inspectExtraColumns(byte[] bytes,DocumentGrid.Sheet source,int headerRow,int knownWidth) {
        if(com.uten.imp.common.files.document.LegacyBiffGridReader.isRaw(bytes))
            return inspectExtraColumns(source,headerRow,knownWidth); // This legacy format has no formula support.
        return com.uten.imp.common.files.document.DocumentParseGate.run(deadline->{
            try(var workbook=WorkbookFactory.create(new java.io.ByteArrayInputStream(bytes))) {
                var sheet=workbook.getSheetAt(source.index());
                var headers=new ArrayList<Header>();var header=sheet.getRow(headerRow);var formatter=new DataFormatter();
                if(header!=null)for(Cell cell:header)headers.add(new Header(cell.getColumnIndex(),formatter.formatCellValue(cell),
                        cell.getColumnIndex()<knownWidth?"position:"+cell.getColumnIndex():null));
                var populated=new HashSet<Integer>();
                for(Row row:sheet)if(row.getRowNum()>headerRow){deadline.check();for(Cell cell:row)if(hasContent(cell))populated.add(cell.getColumnIndex());}
                return inspect(headers,populated,headerRow);
            }catch(com.uten.imp.common.web.ApiException error){throw error;}
            catch(Exception error){throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"无法完整核对导入列，请重新检测原文件");}
        });
    }

    private static boolean hasContent(Cell cell) {
        return switch (cell.getCellType()) {
            case BLANK, _NONE -> false;
            case STRING -> !cell.getStringCellValue().isBlank();
            default -> true; // A formula remains content even when its cached display is blank.
        };
    }
    private static String label(String raw, int index) {
        String value = raw == null ? "" : raw.strip();
        return value.isEmpty() ? "第" + (index + 1) + "列（未命名）" : value.substring(0, Math.min(value.length(), 200));
    }
    private static Issue unsupported(int row, String label) {
        return new Issue(row + 1, label, "列「" + label + "」含数据，当前导入不支持该列（含自定义列）；请删除该列或明确映射后重新检测，不能直接忽略");
    }
}
