package com.uten.imp.common.importing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.web.*;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import java.util.*;

/** Stable export provenance only; this marker is never a write authorization. */
public final class PlatformWorkbookSchema {
    public static final String PROPERTY = "UTEN_PLATFORM_COLUMN_SCHEMA";
    private static final int MAX_CHARS = 262_144;
    private static final ObjectMapper JSON = new ObjectMapper();
    private PlatformWorkbookSchema() { }
    public record Column(int index, String definitionId, String label) { }
    public record Sheet(String name, int headerRow, List<Column> columns) { }

    public static Sheet sheet(String name, int headerRow, List<ExportColumn> columns) {
        var values = new ArrayList<Column>();
        for (int index = 0; index < columns.size(); index++) {
            var column = columns.get(index);
            if (column.key().startsWith("platform:")) {
                String identity = column.key().substring(9);
                try { UUID.fromString(identity); } catch (IllegalArgumentException error) { throw invalid("导出自定义列缺少有效UUID"); }
                values.add(new Column(index, identity, column.label()));
            }
        }
        return values.isEmpty() ? null : new Sheet(name, headerRow, List.copyOf(values));
    }

    public static void write(XSSFWorkbook workbook, String scope, List<Sheet> sheets) {
        if (sheets.isEmpty()) return;
        try {
            var indexes=new LinkedHashMap<List<Column>,Integer>();
            var columnSets=new ArrayList<List<Column>>();
            var references=new ArrayList<Map<String,Object>>();
            for(var sheet:sheets) {
                int index=indexes.computeIfAbsent(sheet.columns(),columns->{columnSets.add(columns);return columnSets.size()-1;});
                references.add(Map.of("name",sheet.name(),"headerRow",sheet.headerRow(),"columnSet",index));
            }
            String value = JSON.writeValueAsString(Map.of("schemaVersion", 1, "scope", scope == null ? "UNSPECIFIED" : scope,
                    "columnSets",columnSets,"sheets", references));
            if (value.length() > MAX_CHARS) throw invalid("导出自定义列来源标记过大，请减少导出列后重试");
            workbook.getProperties().getCustomProperties().addProperty(PROPERTY, value);
        } catch (ApiException error) { throw error; }
        catch (Exception error) { throw invalid("无法保存自定义列来源标记，导出未完成"); }
    }

    /** Presence, malformed contents and future versions all fail closed until mapping is supported. */
    public static String importRejection(Workbook workbook) {
        if (!(workbook instanceof XSSFWorkbook xlsx)) return null;
        var property = xlsx.getProperties().getCustomProperties().getProperty(PROPERTY);
        if (property == null) return null;
        String value = property.getLpwstr();
        try {
            if (value == null || value.length() > MAX_CHARS) throw new IllegalArgumentException();
            var root = JSON.readTree(value);
            if (!root.isObject() || !root.path("schemaVersion").isIntegralNumber() || !root.path("schemaVersion").canConvertToInt() || root.path("schemaVersion").intValue() != 1
                    || !root.path("scope").isTextual() || root.path("scope").asText().isBlank() || root.path("scope").asText().length() > 120
                    || !root.path("sheets").isArray() || root.path("sheets").isEmpty() || root.path("sheets").size() > MAX_CHARS/16
                    || !root.path("columnSets").isArray() || root.path("columnSets").isEmpty() || root.path("columnSets").size() > MAX_CHARS/16) throw new IllegalArgumentException();
            for(var columns:root.path("columnSets")) {
                if(!columns.isArray()||columns.isEmpty()||columns.size()>160)throw new IllegalArgumentException();
                var positions=new HashSet<Integer>();var identities=new HashSet<UUID>();
                for(var column:columns) {
                    if (!column.path("index").isIntegralNumber() || !column.path("index").canConvertToInt() || column.path("index").intValue() < 0 || column.path("index").intValue() >= 16384
                            || !column.path("label").isTextual() || column.path("label").asText().isBlank() || column.path("label").asText().length() > 200
                            || !column.path("definitionId").isTextual()) throw new IllegalArgumentException();
                    if(!positions.add(column.path("index").intValue())||!identities.add(UUID.fromString(column.path("definitionId").asText())))throw new IllegalArgumentException();
                }
            }
            var names=new HashSet<String>();var formatter=new org.apache.poi.ss.usermodel.DataFormatter();
            for (var sheet : root.path("sheets")) {
                if (!sheet.path("name").isTextual() || sheet.path("name").asText().length() > 31
                        || !sheet.path("headerRow").isIntegralNumber() || !sheet.path("headerRow").canConvertToInt() || sheet.path("headerRow").intValue() < 0
                        || sheet.path("headerRow").intValue()>=1_048_576 || !sheet.path("columnSet").isIntegralNumber()
                        || !sheet.path("columnSet").canConvertToInt() || sheet.path("columnSet").intValue()<0
                        || sheet.path("columnSet").intValue()>=root.path("columnSets").size()) throw new IllegalArgumentException();
                String name=sheet.path("name").asText();var actual=workbook.getSheet(name);
                if(!names.add(name)||actual==null)throw new IllegalArgumentException();
                var header=actual.getRow(sheet.path("headerRow").intValue());if(header==null)throw new IllegalArgumentException();
                for(var column:root.path("columnSets").get(sheet.path("columnSet").intValue())) {
                    var cell=header.getCell(column.path("index").intValue());
                    if(cell==null||!formatter.formatCellValue(cell).equals(column.path("label").asText()))throw new IllegalArgumentException();
                }
            }
            return "文件含有导出的自定义列，当前导入尚不支持自定义列写回；请重新导出仅含系统列的文件后导入，不能按显示名称改写系统字段";
        } catch (Exception error) {
            return "文件的自定义列来源标记缺损、过大或版本不支持，无法安全映射；请重新导出仅含系统列的文件后导入";
        }
    }

    public static void requireImportable(Workbook workbook) {
        String reason = importRejection(workbook);
        if (reason != null) throw invalid(reason);
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
