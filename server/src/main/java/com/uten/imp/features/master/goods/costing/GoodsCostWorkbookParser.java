package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.files.document.SpreadsheetEvidenceReader;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.apache.poi.ss.util.CellReference;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;
import static com.uten.imp.features.master.goods.costing.GoodsCostImportContracts.*;

/** Header-based cost block discovery, never an executable Excel formula importer. */
public final class GoodsCostWorkbookParser {
    private GoodsCostWorkbookParser() {}
    public static Preview parse(UUID id, String name, String sha, byte[] bytes) {
        var book = SpreadsheetEvidenceReader.read(bytes);
        List<Block> blocks = new ArrayList<>();
        for (var sheet : book.sheets()) {
            String label = sheet.name(), key = null;
            Map<String, Integer> fields = Map.of();
            List<ImportRow> rows = new ArrayList<>();
            for (var row : sheet.rows()) {
                Map<Integer, SpreadsheetEvidenceReader.Value> cells = new HashMap<>();
                row.cells().forEach(cell -> cells.put((int) new CellReference(cell.address()).getCol(), cell));
                Map<String, Integer> candidate = header(row.cells());
                if (candidate.containsKey("name") && (candidate.containsKey("qty") || candidate.containsKey("price"))) {
                    if (key != null && !rows.isEmpty()) blocks.add(new Block(key, label, sheet.name(), List.copyOf(rows)));
                    fields = candidate; rows = new ArrayList<>(); key = sheet.name() + "!" + row.number();
                    continue;
                }
                String title = row.cells().stream().map(SpreadsheetEvidenceReader.Value::text)
                        .filter(t -> t.matches(".*产品名称[：:].*")).findFirst().orElse(null);
                if (title != null) {
                    if (key != null && !rows.isEmpty()) blocks.add(new Block(key, label, sheet.name(), List.copyOf(rows)));
                    key = null; rows = new ArrayList<>();
                    label = title.replaceFirst(".*产品名称[：:]", "").strip();
                    continue;
                }
                if (key == null) continue;
                String rowName = value(cells, fields.get("name"));
                if (rowName.isBlank()) continue;
                if (rowName.matches(".*(合计|小计|总计).*")) {
                    if (!rows.isEmpty()) blocks.add(new Block(key, label, sheet.name(), List.copyOf(rows)));
                    key = null; rows = new ArrayList<>(); continue;
                }
                boolean external = row.cells().stream().anyMatch(SpreadsheetEvidenceReader.Value::externalReference);
                String formula = row.cells().stream().filter(c -> c.formula() != null)
                        .map(c -> c.address() + "=" + c.formula()).collect(Collectors.joining("; "));
                rows.add(new ImportRow(sheet.name() + "!" + row.number(), row.number(), rowName,
                        value(cells, fields.get("code")), value(cells, fields.get("unit")),
                        number(value(cells, fields.get("qty"))), number(value(cells, fields.get("price"))),
                        number(value(cells, fields.get("amount"))), formula, external, true));
            }
            if (key != null && !rows.isEmpty()) blocks.add(new Block(key, label, sheet.name(), List.copyOf(rows)));
        }
        if (blocks.isEmpty()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "未找到材料名称、用量或单价表头，请使用成本明细格式");
        List<String> warnings = new ArrayList<>();
        warnings.add("仅读取原文件缓存数值，公式不执行；应用前确认物料身份、计价单位和数量基准。");
        warnings.add("导入价格按当前成本单币种和税口径核定；不同币种请先完成换算，不自动猜测。");
        warnings.add("结构行、组合件、合计和加工费必须明确映射或跳过，不能把空价当零。");
        if (book.externalReferenceCount() > 0) warnings.add("包含 " + book.externalReferenceCount() + " 处外部引用；未读取外链，价格需要人工核定。");
        return new Preview(id, name, sha, List.copyOf(blocks), List.copyOf(warnings));
    }
    private static Map<String, Integer> header(List<SpreadsheetEvidenceReader.Value> cells) {
        Map<String, Integer> fields = new HashMap<>();
        for (var cell : cells) {
            String title = cell.text().replaceAll("\\s", "").replace('\uff08', '(').replace('\uff09', ')');
            String field = switch (title) {
                case "名称", "货品名称", "材料名称", "物料名称", "零件名称", "品名" -> "name";
                case "编号", "编码", "货品编号", "物料编码", "物料编号" -> "code";
                case "单位", "材料单位", "计价单位" -> "unit";
                case "数量", "用量", "单位用量", "设计使用数量", "采用量", "计价数量" -> "qty";
                case "单价", "材料单价(元)", "材料单价", "采用单价", "采购单价" -> "price";
                case "金额", "成本金额", "成本金额(元)", "批次材料金额", "材料金额" -> "amount";
                default -> null;
            };
            if (field != null) fields.putIfAbsent(field, (int) new CellReference(cell.address()).getCol());
        }
        return fields;
    }
    private static String value(Map<Integer, SpreadsheetEvidenceReader.Value> cells, Integer index) {
        if (index == null) return "";
        var cell = cells.get(index); return cell == null ? "" : cell.text();
    }
    private static String number(String value) {
        if (value == null || value.isBlank()) return null;
        try { return new BigDecimal(value.strip()).toPlainString(); }
        catch (NumberFormatException error) { return null; }
    }
}
