package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.MergedRange;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 按版式逐行抽取货品行(SPEC §5.2 第 3 步, 纯规则, 不用 AI)。
 *
 * <p>从表头下一行开始, 到「合计/订金/尾款/备注/付款/银行/收款人」这类行或连续 3 个空行为止。
 * 数量为正数且有型号或品名的行才算货品行。系列/颜色空白时沿用合并单元格或上一行的值(同一段内)。
 */
final class IntakeLineExtractor {

    static final int MAX_EMPTY_GAP = 3;
    private static final Pattern STOP_ROW = Pattern.compile(
            "(?i)^(?:\\d+\\s*[.)、]\\s*)?(total|合计|总计|小计|subtotal|sub-total|sub total|deposit|balance|remarks?|备注|"
                    + "payment|bank|beneficiary|付款|订金|定金|尾款|银行|收款)(?![a-z])");
    private static final Pattern ASSEMBLY_NOTE = Pattern.compile("[\uFF08(]\\s*组装成功能件\\s*[)\uFF09]");
    private static final Pattern PLUS_SPLIT = Pattern.compile("[+＋]");
    private static final Set<String> PIECE_UNITS = Set.of("pcs", "pc", "piece", "pieces", "个", "只", "件", "ea", "each");
    private static final Set<String> CARTON_UNITS = Set.of("ctn", "ctns", "carton", "cartons", "箱");

    private IntakeLineExtractor() {
    }

    /** 抽取结果: 货品行 + 从单价单元格里认出的币种(表头没写时)。 */
    record Extraction(List<ExtractedLine> lines, String currencyFromCells) {
    }

    static Extraction extract(Sheet sheet, IntakeLayout layout) {
        Map<ColumnRole, Integer> cols = layout.columnsByRole();
        boolean hasColorColumn = cols.containsKey(ColumnRole.COLOR) || cols.containsKey(ColumnRole.COLOR_ALT);
        List<ExtractedLine> lines = new ArrayList<>();
        String currencyFromCells = null;
        int lastIndex = layout.firstDataRow0() - 1;
        String carrySeries = null;
        String carryColor = null;
        String carryColorAlt = null;
        for (Row row : sheet.rows()) {
            if (row.index0() < layout.firstDataRow0()) {
                continue;
            }
            if (row.index0() - lastIndex - 1 >= MAX_EMPTY_GAP) {
                break;
            }
            lastIndex = row.index0();
            BigDecimal qty = IntakeNumbers.of(cell(row, cols, ColumnRole.QTY));
            String partNo = text(row, cols, ColumnRole.PART_NO);
            String descRaw = text(row, cols, ColumnRole.DESCRIPTION);
            String descAltRaw = text(row, cols, ColumnRole.DESCRIPTION_ALT);
            boolean isLine = IntakeNumbers.positive(qty)
                    && (!partNo.isBlank() || !descRaw.isBlank() || !descAltRaw.isBlank());
            if (!isLine) {
                if (STOP_ROW.matcher(row.firstText().strip()).find()) {
                    break;
                }
                if (!row.firstText().isBlank()) {
                    // 段落标题行(例如「Z9 系列」): 断开沿用。
                    carrySeries = null;
                    carryColor = null;
                    carryColorAlt = null;
                }
                continue;
            }
            String series = carried(sheet, row, cols, ColumnRole.SERIES, carrySeries);
            String color = carried(sheet, row, cols, ColumnRole.COLOR, carryColor);
            String colorAlt = carried(sheet, row, cols, ColumnRole.COLOR_ALT, carryColorAlt);
            carrySeries = series;
            carryColor = color;
            carryColorAlt = colorAlt;

            Cell priceCell = cell(row, cols, ColumnRole.UNIT_PRICE);
            if (currencyFromCells == null && priceCell != null) {
                currencyFromCells = IntakeLayoutDetector.currencyOf(priceCell.text());
            }
            String unit = text(row, cols, ColumnRole.UNIT);
            BigDecimal pcsPerCtn = IntakeNumbers.of(cell(row, cols, ColumnRole.PCS_PER_CTN));
            RawLine raw = new RawLine("S" + (sheet.index() + 1) + "R" + (row.index0() + 1), sheet.name(),
                    row.index0() + 1, text(row, cols, ColumnRole.LINE_NO), partNo, descRaw, descAltRaw, series, color,
                    colorAlt, qty, unit.isBlank() ? layout.headerUnit() : unit, pcsPerCtn, IntakeNumbers.of(priceCell),
                    IntakeNumbers.of(cell(row, cols, ColumnRole.AMOUNT)), hasColorColumn);
            lines.add(build(raw));
        }
        return new Extraction(lines, currencyFromCells);
    }

    /**
     * 一行的原始字段(表格一行, 或 AI 从 PDF/图片里抽出的一行), 交给 {@link #build} 做统一的后处理。
     */
    record RawLine(String key, String sourceSheet, int sourceRow, String lineNo, String partNo, String description,
                   String descriptionAlt, String series, String color, String colorAlt, BigDecimal qty, String unit,
                   BigDecimal pcsPerCtn, BigDecimal unitPrice, BigDecimal amount, boolean hasColorColumn) {
    }

    /** 统一后处理: 中英拆分、颜色、组合件、组装说明、单位、金额核对。 */
    static ExtractedLine build(RawLine raw) {
        StringBuilder latin = new StringBuilder();
        StringBuilder cjk = new StringBuilder();
        IntakeTextNormalizer.ScriptSplit alt = IntakeTextNormalizer.splitByScript(raw.descriptionAlt());
        IntakeTextNormalizer.ScriptSplit main = IntakeTextNormalizer.splitByScript(raw.description());
        appendPart(latin, main.latin());
        appendPart(cjk, alt.cjk());
        appendPart(cjk, main.cjk());
        appendPart(latin, alt.latin());
        String description = blankToNull(latin.toString());
        String descriptionAlt = blankToNull(cjk.toString());

        List<String> bundleParts = bundleParts(raw.partNo());
        boolean bundle = bundleParts.size() > 1;
        boolean assembled = descriptionAlt != null && ASSEMBLY_NOTE.matcher(descriptionAlt).find();
        String match = descriptionAlt;
        if (match != null) {
            if (bundle || assembled) {
                match = PLUS_SPLIT.split(match, 2)[0];
            }
            match = blankToNull(ASSEMBLY_NOTE.matcher(match).replaceAll("").strip());
        }

        IntakeColors.ColorSpec colors = IntakeColors.parse(raw.color(), raw.colorAlt(), descriptionAlt, description,
                raw.hasColorColumn());
        String colorAlt = blankToNull(raw.colorAlt());
        String color = blankToNull(raw.color());
        if (colorAlt == null && color != null && IntakeTextNormalizer.hasCjk(color)) {
            colorAlt = color;
            color = null;
        }
        if (colorAlt == null && colors.colorAltFound() != null) {
            colorAlt = colors.colorAltFound();
        }

        List<IntakeWarning> warnings = new ArrayList<>();
        String unit = blankToNull(raw.unit());
        BigDecimal suggestedQty = null;
        if (unit != null) {
            String u = IntakeTextNormalizer.nfkc(unit).toLowerCase(Locale.ROOT).replace(".", "").strip();
            if (!PIECE_UNITS.contains(u)) {
                warnings.add(new IntakeWarning(IntakeWarning.UNIT_NOT_PCS,
                        "文件里的单位是「" + unit.strip() + "」, 不是「个」, 请核对数量"));
                if (CARTON_UNITS.contains(u) && IntakeNumbers.positive(raw.pcsPerCtn()) && raw.qty() != null) {
                    suggestedQty = raw.qty().multiply(raw.pcsPerCtn());
                }
            }
        }
        if (raw.qty() != null && raw.unitPrice() != null && raw.amount() != null && raw.amount().signum() != 0) {
            BigDecimal product = raw.qty().multiply(raw.unitPrice());
            BigDecimal tolerance = raw.amount().abs().multiply(new BigDecimal("0.005")).max(new BigDecimal("0.01"));
            if (product.subtract(raw.amount()).abs().compareTo(tolerance) > 0) {
                warnings.add(new IntakeWarning(IntakeWarning.AMOUNT_MISMATCH, "数量×单价和金额对不上, 请核对这一行"));
            }
        }
        if (bundle) {
            warnings.add(new IntakeWarning(IntakeWarning.BUNDLE_LINE,
                    "这一行是 " + bundleParts.size() + " 个配件的组合, 请选对应的货品或拆成几行"));
        }
        return new ExtractedLine(raw.key(), raw.sourceSheet(), raw.sourceRow(), blankToNull(raw.lineNo()),
                blankToNull(raw.partNo()), description, descriptionAlt, match, blankToNull(raw.series()), color, colorAlt,
                colors, raw.qty(), unit, suggestedQty, raw.unitPrice(), raw.amount(), bundle ? bundleParts : List.of(),
                assembled, warnings);
    }

    static List<String> bundleParts(String partNo) {
        if (partNo == null || !partNo.contains("+")) {
            return List.of();
        }
        List<String> parts = new ArrayList<>();
        for (String p : partNo.split("\\+")) {
            String t = p.strip();
            if (!t.isEmpty()) {
                parts.add(t);
            }
        }
        return parts;
    }

    private static void appendPart(StringBuilder sb, String part) {
        if (part == null || part.isBlank()) {
            return;
        }
        if (!sb.isEmpty()) {
            sb.append(' ');
        }
        sb.append(part.strip());
    }

    private static String carried(Sheet sheet, Row row, Map<ColumnRole, Integer> cols, ColumnRole role, String carry) {
        Integer col = cols.get(role);
        if (col == null) {
            return null;
        }
        Cell c = row.cell(col);
        if (c != null && !c.text().isBlank()) {
            return c.text().strip();
        }
        MergedRange merge = sheet.mergeAt(row.index0(), col);
        if (merge != null && (merge.firstRow() != row.index0() || merge.firstCol() != col)) {
            String top = sheet.text(merge.firstRow(), merge.firstCol());
            if (!top.isBlank()) {
                return top.strip();
            }
        }
        return carry;
    }

    private static Cell cell(Row row, Map<ColumnRole, Integer> cols, ColumnRole role) {
        Integer col = cols.get(role);
        return col == null ? null : row.cell(col);
    }

    private static String text(Row row, Map<ColumnRole, Integer> cols, ColumnRole role) {
        Cell c = cell(row, cols, role);
        return c == null ? "" : c.text().strip();
    }

    static String blankToNull(String s) {
        return s == null || s.isBlank() ? null : s.strip();
    }
}
