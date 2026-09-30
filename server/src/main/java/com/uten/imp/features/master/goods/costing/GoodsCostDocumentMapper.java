package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportDocument;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;

/** Converts only the frozen calculation to a shared document, never to live master data. */
public final class GoodsCostDocumentMapper {
    private GoodsCostDocumentMapper() {}

    public static ExportDocument map(Snapshot snapshot, String requestedSection, List<String> paths,
                                     TableColumnProjection projection) {
        String section = requestedSection == null ? "ALL" : requestedSection;
        if (!Set.of("ALL", "MATERIAL", "FEES").contains(section)) throw invalid("不支持的成本下载内容");
        var calc = snapshot.calculation();
        boolean partial = paths != null && !paths.isEmpty();
        Set<String> includedPaths = partial ? new HashSet<>(paths) : Set.of();
        if (partial && (includedPaths.size() != paths.size() || includedPaths.size() > 5000
                || !calc.lines().stream().map(CostLine::path).toList().containsAll(includedPaths)))
            throw invalid("选中物料已经变化，请重新选择");
        List<String> metadata = new ArrayList<>(List.of(
                "成本单: " + snapshot.sheetNo(), "版本: " + snapshot.sheetVersion() + " / " + kind(snapshot.kind()),
                "货品: " + calc.goodsCode() + " " + calc.goodsName(),
                "测算数量: " + calc.batchQty() + " " + calc.unitName(),
                "币种: " + text(calc.currencyName()) + " / 本币换算率: " + text(calc.exchangeRateToLocal()),
                "计算时间: " + calc.calculatedAt(), "快照: " + snapshot.id(),
                "计算摘要: " + snapshot.contentDigest(), "算法: " + calc.algorithmVersion(),
                "完整性: " + stateLabel(calc.totals().valueState()),
                "范围: " + (partial ? "选中物料(部分明细，不代表整单)" : "整张成本单"),
                "本文件是内部成本快照，不改变库存、总账或销售价格。",
                "物料行成本包含本行费用；工序与费用表是同一份费用的展开，不要再次叠加。结构父项不参与合计。",
                "金额超过 Excel 15 位有效数字时以精确十进制文本保存。空金额表示待核定，不表示零。"));
        List<ExportDocument.Section> sections = new ArrayList<>();
        boolean feeProjection = projection != null && projection.tableKey() != null && projection.tableKey().endsWith(".fees");
        if (!partial && "ALL".equals(section)) sections.add(summary(calc));
        if (!"FEES".equals(section)) sections.add(materials(snapshot, includedPaths, partial, feeProjection ? null : projection));
        if (!"MATERIAL".equals(section)) sections.add(fees(calc, includedPaths, partial, feeProjection ? projection : null));
        if ("ALL".equals(section)) {
            sections.add(prices(calc, includedPaths, partial));
            var issueRows = calc.issues().stream().filter(i -> !partial || i.path() == null || includedPaths.contains(i.path()))
                    .map(i -> row("code", i.code(), "path", i.path(), "message", i.message(),
                            "blocks", i.blocksConfirmation() ? "需要处理" : "提示")).toList();
            sections.add(new ExportDocument.Section("校验说明", List.of(textCol("code", "问题类型"),
                    textCol("path", "物料路径"), textCol("message", "说明"), textCol("blocks", "状态")), issueRows));
            var sourceRows = calc.sourceRevisions().entrySet().stream().map(e -> row("source", e.getKey(), "revision", e.getValue())).toList();
            sections.add(new ExportDocument.Section("来源版本", List.of(textCol("source", "来源"), textCol("revision", "冻结版本")), sourceRows));
        }
        return new ExportDocument(partial ? "货品成本单 - 部分明细" : "货品成本单", metadata, sections);
    }

    private static ExportDocument.Section summary(Calculation calc) {
        Totals t = calc.totals();
        return new ExportDocument.Section("成本汇总", List.of(textCol("name", "项目"), numberCol("amount", "测算金额"),
                textCol("state", "口径")), List.of(
                row("name", "材料", "amount", decimal(t.material())), row("name", "加工", "amount", decimal(t.process())),
                row("name", "管理分摊", "amount", decimal(t.management())), row("name", "其他", "amount", decimal(t.other())),
                row("name", "已知成本合计", "amount", decimal(t.knownTotal()), "state", stateLabel(t.valueState())),
                row("name", "单位成本", "amount", decimal(t.unitCost()), "state", "按测算数量折算"),
                row("name", "缺价物料数", "amount", t.missingPriceCount()),
                row("name", "采用真实量物料数", "amount", t.actualUsageCount()),
                row("name", "采用设计量物料数", "amount", t.designUsageCount())));
    }

    private static ExportDocument.Section materials(Snapshot snapshot, Set<String> paths, boolean partial,
                                                    TableColumnProjection projection) {
        List<ExportColumn> columns = new ArrayList<>(List.of(textCol("goodsCode", "货品编号"), textCol("goodsName", "货品名称"),
                textCol("colorName", "颜色"), textCol("unitName", "单位"), numberCol("designQty", "设计使用数量"),
                numberCol("actualQty", "真实使用数量"), numberCol("adoptedQty", "采用量"), textCol("usageBasis", "用量来源"),
                numberCol("batchQty", "计价用量"), numberCol("perProductQty", "每产品用量"), numberCol("unitPrice", "采用单价"),
                textCol("priceSource", "价格来源"),
                numberCol("unitContribution", unitContributionLabel(snapshot.calculation().unitName())), numberCol("amount", "测算金额"),
                numberCol("materialAmount", "纯材料金额"), numberCol("feeAmount", "本行费用金额"),
                textCol("valueState", "成本状态"), textCol("route", "计价方式"), textCol("included", "参与合计"),
                textCol("path", "BOM路径"), textCol("usageReason", "用量依据")));
        if (snapshot.input().priceColumns() != null) for (PriceColumn column : snapshot.input().priceColumns()) {
            columns.add(numberCol("fee:" + column.key(), column.name() + "单价或费率"));
            columns.add(numberCol("feeQty:" + column.key(), column.name() + "计价数量"));
            columns.add(numberCol("feeAmount:" + column.key(), column.name() + " · 测算金额"));
        }
        List<Map<String, Object>> rows = new ArrayList<>();
        for (CostLine line : snapshot.calculation().lines()) {
            if (partial && !paths.contains(line.path())) continue;
            Map<String, Object> row = row("goodsCode", line.goodsCode(), "goodsName", line.goodsName(),
                    "colorName", line.colorName(), "unitName", line.unitName(), "designQty", decimal(line.designQty()),
                    "actualQty", decimal(line.actualQty()), "adoptedQty", decimal(line.adoptedQty()),
                    "usageBasis", "ACTUAL".equals(line.usageBasis()) ? "真实使用量" : "MANUAL".equals(line.usageBasis()) ? "本单覆盖" : "设计使用量",
                    "batchQty", decimal(line.batchQty()), "perProductQty", decimal(line.perProductQty()), "unitPrice", decimal(line.unitPrice()),
                    "priceSource", priceSourceLabel(line.priceEvidence()),
                    "unitContribution", decimal(line.unitContribution()), "amount", decimal(line.amount()),
                    "materialAmount", decimal(line.materialAmount()), "feeAmount", decimal(line.feeAmount()),
                    "valueState", stateLabel(line.valueState()), "route", routeLabel(line.route()), "included", line.included() ? "是" : "否(结构小计)",
                    "path", line.path(), "usageReason", line.usageReason());
            if (snapshot.input().priceCells() != null) snapshot.input().priceCells().stream()
                    .filter(cell -> line.path().equals(cell.path())).forEach(cell -> {
                        row.put("fee:" + cell.columnKey(), decimal(cell.value()));
                        row.put("feeQty:" + cell.columnKey(), decimal(cell.quantity()));
                    });
            if (line.extraCosts() != null) line.extraCosts().forEach((key, amount) -> row.put("feeAmount:" + key, decimal(amount)));
            rows.add(row);
        }
        return new ExportDocument.Section(partial ? "选中物料" : "物料明细", frozenColumns(columns, projection), rows);
    }

    private static List<ExportColumn> frozenColumns(List<ExportColumn> available, TableColumnProjection projection) {
        if (projection == null) return available;
        Map<String, ExportColumn> allowed = new LinkedHashMap<>();
        available.forEach(c -> allowed.put(c.key(), c));
        List<ExportColumn> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (var column : projection.columns()) {
            if (!seen.add(column.key())) throw invalid("下载表头存在重复列");
            ExportColumn frozen = allowed.get(column.key());
            if (frozen == null) continue; // Selection/expand widgets are presentation-only.
            result.add(new ExportColumn(frozen.key(), frozen.label(), frozen.type(), column.width()));
        }
        if (result.isEmpty()) throw invalid("下载表头与成本快照不匹配");
        return result;
    }

    private static ExportDocument.Section fees(Calculation calc, Set<String> paths, boolean partial, TableColumnProjection projection) {
        Map<String, CostLine> materials = new LinkedHashMap<>();
        calc.lines().forEach(line -> materials.put(line.path(), line));
        var rows = calc.fees().stream().filter(f -> !partial || f.targetPath() != null && paths.contains(f.targetPath()))
                .map(f -> {
                    CostLine material = f.targetPath() == null ? null : materials.get(f.targetPath());
                    return row("name", f.name(), "type", feeTypeLabel(f.type()), "category", categoryLabel(f.category()), "target", f.targetPath(),
                        "goodsName", material == null ? "整单费用" : material.goodsName(),
                        "goodsCode", material == null ? null : material.goodsCode(), "unitName", material == null ? calc.unitName() : material.unitName(),
                        "value", decimal(f.value()), "quantity", decimal(f.quantity()), "baseAmount", decimal(f.baseAmount()),
                        "baseKeys", f.baseKeys() == null ? null : String.join(" + ", f.baseKeys()),
                        "amount", decimal(f.amount()), "unitAmount", decimal(f.unitAmount()), "state", stateLabel(f.valueState()),
                        "source", f.source(), "reason", f.reason());
                }).toList();
        var columns = List.of(textCol("name", "费用名称"),
                textCol("goodsCode", "货品编号"), textCol("goodsName", "对应物料"), textCol("unitName", "单位"),
                textCol("type", "计费方式"), textCol("category", "归集分类"), textCol("target", "归属物料路径"),
                numberCol("value", "单价或费率"), numberCol("quantity", "计价数量"), textCol("baseKeys", "基数项目"), numberCol("baseAmount", "计费基数"),
                numberCol("unitAmount", "单位分摊"), numberCol("amount", "测算金额"), textCol("state", "状态"),
                textCol("source", "来源"), textCol("reason", "说明"));
        return new ExportDocument.Section(partial ? "选中物料费用" : "工序与费用", frozenColumns(columns, projection), rows);
    }

    private static ExportDocument.Section prices(Calculation calc, Set<String> paths, boolean partial) {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (CostLine line : calc.lines()) {
            if (partial && !paths.contains(line.path())) continue;
            PriceEvidence p = line.priceEvidence();
            if (p == null) continue;
            rows.add(row("goodsCode", line.goodsCode(), "goodsName", line.goodsName(), "sourceType", p.sourceType(),
                    "sourceNumber", p.sourceNumber(), "sourceItemId", p.sourceItemId(), "version", p.sourceVersion(),
                    "approval", p.approvalState(), "date", p.sourceDate(), "unit", p.unitName(),
                    "rate", decimal(p.unitRate()), "originalPrice", decimal(p.originalUnitPrice()), "currency", p.currencyName(),
                    "exchange", decimal(p.exchangeRateToLocal()), "tax", decimal(p.taxRate()), "taxMode", p.taxMode(), "reason", p.reason()));
        }
        return new ExportDocument.Section("价格依据", List.of(textCol("goodsCode", "货品编号"), textCol("goodsName", "货品名称"),
                textCol("sourceType", "来源类型"), textCol("sourceNumber", "来源单号"), textCol("sourceItemId", "来源行"),
                textCol("version", "来源版本"), textCol("approval", "批准状态"), textCol("date", "来源日期"),
                textCol("unit", "计价单位"), numberCol("rate", "单位换算率"), numberCol("originalPrice", "原单价"),
                textCol("currency", "原币"), numberCol("exchange", "本币汇率"), numberCol("tax", "税率"),
                textCol("taxMode", "税口径"), textCol("reason", "说明")), rows);
    }

    public static Map<String, Object> row(Object... entries) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int i = 0; i < entries.length; i += 2) result.put((String) entries[i], entries[i + 1]);
        return result;
    }
    public static ExportColumn textCol(String key, String label) { return new ExportColumn(key, label, ExportColumn.TEXT); }
    public static ExportColumn numberCol(String key, String label) { return new ExportColumn(key, label, ExportColumn.QTY); }
    public static BigDecimal decimal(String value) { return value == null || value.isBlank() ? null : new BigDecimal(value); }
    private static String unitContributionLabel(String unitName) {return unitName==null||unitName.isBlank()?"单位成本":"每"+unitName.strip()+"成本";}
    private static String text(String value) { return Objects.toString(value, "待核定"); }
    private static String kind(String kind) { return "CONFIRMED".equals(kind) ? "已确认" : "草稿快照"; }
    public static String stateLabel(String value) {
        if(value==null)return "—";
        return switch(value) {
            case "COMPLETE" -> "完整";
            case "INCOMPLETE" -> "待核定";
            case "MISSING_PRICE" -> "缺少价格";
            case "FINAL" -> "价值来源已结算";
            case "APPLYING" -> "正在分配成本";
            case "PENDING_BASIS" -> "待核计价依据";
            case "PENDING_CLASSIFICATION" -> "待分类";
            case "PROVISIONAL" -> "暂估";
            default -> value;
        };
    }
    private static String routeLabel(String value) {
        if(value==null)return "—";
        return switch(value) {case "BUY" -> "采购";case "MAKE" -> "自制展开";case "SUBCONTRACT" -> "委外加工";
            case "CUSTOMER_SUPPLIED" -> "客供材料";default -> value;};
    }
    private static String priceSourceLabel(PriceEvidence evidence) {
        if(evidence==null)return "—";
        if(evidence.sourceNumber()!=null&&!evidence.sourceNumber().isBlank())return evidence.sourceNumber().strip();
        if(evidence.sourceType()==null)return "—";
        return switch(evidence.sourceType()) {
            case "MANUAL" -> "本单覆盖";
            case "APPROVED_PURCHASE","PURCHASE_ORDER","PURCHASE_RECEIPT" -> "已批准来源价格";
            case "APPROVED_SUBCONTRACT","SUBCONTRACT_ORDER","SUBCONTRACT_RECEIPT" -> "已批准委外价格";
            case "INVENTORY_REFERENCE" -> "库存参考价格";
            case "CUSTOMER_SUPPLIED" -> "客供料";
            default -> "待核定来源";
        };
    }
    private static String feeTypeLabel(String value) {
        if(value==null)return "—";
        return switch(value) {case "PER_UNIT" -> "每产品";case "PER_QUANTITY" -> "按计价数量";
            case "FIXED_BATCH" -> "本批固定";case "PERCENT" -> "按基数比例";case "PER_CYCLE" -> "按周期";default -> value;};
    }
    private static String categoryLabel(String value) {
        if(value==null)return "—";
        return switch(value) {case "MATERIAL" -> "材料";case "PROCESS" -> "加工";case "MANAGEMENT" -> "管理分摊";
            case "OTHER" -> "其他";default -> value;};
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
