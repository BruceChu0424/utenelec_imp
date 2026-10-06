package com.uten.imp.features.ai.chat;

import com.uten.imp.common.files.document.DocumentGrid;

import java.math.BigDecimal;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.EnumMap;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Pattern;

/**
 * Structure of an uploaded table (pure): which row is the header, what each column means and what its
 * values look like. It never returns a cell value; labels are header words with digit runs masked, so the
 * profile can be stored in the job result and, for an unrecognized file, described to the AI model.
 */
final class AiDocumentProfiler {
    static final int MAX_SHEETS = 8;
    static final int MAX_COLUMNS = 40;
    static final int HEADER_SCAN_ROWS = 15;
    static final int SHAPE_SAMPLES = 30;
    static final int LABEL_MAX = 24;

    /** What a column means. SEQ and the two GENERIC keys only count as header evidence. */
    enum Semantic {
        PERSON_NAME, EMPLOYEE_CODE, GENDER, DEPARTMENT, POSITION, HIRE_DATE, ID_NUMBER, PHONE, BIRTH_DATE,
        EDUCATION, ADDRESS, PAY, ATTENDANCE, GOODS_CODE, GOODS_NAME, SPEC_MODEL, COLOR, UNIT, CATEGORY, QTY,
        PRICE, AMOUNT, CURRENCY, CUSTOMER, SUPPLIER, CONTACT, WAREHOUSE, STOCK_QTY, BOM_PARENT, BOM_CHILD,
        BOM_USAGE, TXN_DATE, INCOME, EXPENSE, BALANCE, COUNTERPARTY, DATE, REMARK, SEQ, GENERIC_CODE, GENERIC_NAME
    }

    /** What the values of a column look like (sampled, never the values themselves). */
    enum Shape { DATE, ID18, PHONE11, AMOUNT, INTEGER, CODE, SHORT_TEXT, TEXT, EMPTY }

    record Column(int col0, String label, Semantic semantic, Shape shape) {}

    /** One visible sheet: headerRow is -1 when no header was found; dataRows then counts the non-empty rows. */
    record SheetProfile(String name, int headerRow, int dataRows, List<Column> columns) {
        SheetProfile { columns = List.copyOf(columns); }

        Set<Semantic> semantics() {
            EnumSet<Semantic> result = EnumSet.noneOf(Semantic.class);
            for (Column column : columns) if (column.semantic() != null) result.add(column.semantic());
            result.removeAll(EVIDENCE_ONLY);
            return result;
        }

        Map<String, Object> toJson() {
            Map<String, Object> json = new LinkedHashMap<>();
            json.put("name", name);
            json.put("dataRows", dataRows);
            json.put("columns", columns.stream().map(Column::label).toList());
            return json;
        }
    }

    record Profile(List<SheetProfile> sheets) {
        Profile { sheets = List.copyOf(sheets); }

        static Profile empty() { return new Profile(List.of()); }

        Map<String, Object> toJson() { return Map.of("sheets", sheets.stream().map(SheetProfile::toJson).toList()); }
    }

    private static final Set<Semantic> EVIDENCE_ONLY = EnumSet.of(Semantic.SEQ, Semantic.GENERIC_CODE, Semantic.GENERIC_NAME);
    private static final Pattern DIGIT_RUN = Pattern.compile("\\p{Nd}(?:[ \\t\\-_./]?\\p{Nd}){2,}");
    private static final Pattern EMAIL = Pattern.compile("[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+");
    private static final Pattern BRACKETS = Pattern.compile("\\([^)]*\\)|\\[[^]]*]|【[^】]*】|<[^>]*>");
    private static final Pattern TOTAL = Pattern.compile("^(?:合\\s*计|小\\s*计|总\\s*计|总合计|共\\s*计|累\\s*计|total|sub ?total|grand ?total)");
    private static final Pattern ID18 = Pattern.compile("\\d{17}[\\dx]");
    private static final Pattern PHONE11 = Pattern.compile("(?:\\+?86[- ]?)?1[3-9]\\d(?:[- ]?\\d{4}){2}");
    private static final Pattern DATE_TEXT = Pattern.compile("\\d{4}\\s*[-/.年]\\s*\\d{1,2}(?:\\s*[-/.月]\\s*\\d{1,2}\\s*日?|\\s*月)?"
            + "(?:[ t]\\d{1,2}:\\d{2}(?::\\d{2})?)?");
    private static final Pattern AMOUNT_TEXT = Pattern.compile("[-+]?[¥$€]?(?:\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|\\d+\\.\\d+)元?");
    private static final Pattern INTEGER_TEXT = Pattern.compile("[-+]?\\d+");
    private static final Pattern CODE_TEXT = Pattern.compile("(?=.*\\d)[a-z0-9][a-z0-9._/#-]{1,31}");
    private static final Pattern TOKEN_SPLIT = Pattern.compile("[\\s,，|;；]+");
    private static final Set<Shape> VALUE_SHAPES = EnumSet.of(Shape.DATE, Shape.ID18, Shape.PHONE11, Shape.AMOUNT, Shape.INTEGER);
    private static final Set<Semantic> GOODS_CONTEXT = EnumSet.of(Semantic.GOODS_CODE, Semantic.GOODS_NAME, Semantic.SPEC_MODEL,
            Semantic.UNIT, Semantic.COLOR, Semantic.QTY, Semantic.PRICE, Semantic.STOCK_QTY, Semantic.BOM_USAGE, Semantic.CATEGORY);
    private static final Set<Semantic> PERSON_CONTEXT = EnumSet.of(Semantic.GENDER, Semantic.DEPARTMENT, Semantic.POSITION,
            Semantic.HIRE_DATE, Semantic.ID_NUMBER, Semantic.BIRTH_DATE, Semantic.EMPLOYEE_CODE);
    private static final Map<String, Semantic> SYNONYMS = new HashMap<>();
    /** A label ending in one of these words takes its meaning (e.g. 家庭地址, 交货日期). */
    private static final Map<String, Semantic> SUFFIXES = new LinkedHashMap<>();
    private static final List<String> CONTAINED;

    static {
        put(Semantic.PERSON_NAME, "姓名", "员工姓名", "名字", "职员姓名", "人员姓名", "员工名称", "employee name", "staff name", "full name");
        put(Semantic.EMPLOYEE_CODE, "工号", "员工编号", "员工号", "员工工号", "职员编号", "人员编号", "工卡号", "employee id", "employee no",
                "employee no.", "staff id", "staff no");
        put(Semantic.GENDER, "性别", "gender", "sex");
        put(Semantic.DEPARTMENT, "部门", "所属部门", "一级部门", "二级部门", "三级部门", "部门名称", "所在部门", "科室", "车间", "班组",
                "department", "dept");
        put(Semantic.POSITION, "岗位", "职位", "职务", "岗位名称", "职称", "工种", "职级", "position", "job title");
        put(Semantic.HIRE_DATE, "入职日期", "入职时间", "到岗日期", "入厂日期", "进厂日期", "进厂时间", "报到日期", "入司日期", "入司时间",
                "hire date", "entry date", "date of joining", "joining date");
        put(Semantic.ID_NUMBER, "身份证", "身份证号", "身份证号码", "证件号码", "证件号", "身份证件号码", "公民身份号码", "身份证编号",
                "id number", "id card", "id no", "id card no");
        put(Semantic.PHONE, "手机", "手机号", "手机号码", "联系电话", "电话", "电话号码", "联系方式", "移动电话", "联系手机",
                "phone", "mobile", "tel", "telephone", "mobile phone", "phone number");
        put(Semantic.BIRTH_DATE, "出生日期", "出生年月", "生日", "出生年月日", "birth date", "date of birth", "birthday", "dob");
        put(Semantic.EDUCATION, "学历", "文化程度", "最高学历", "毕业院校", "毕业学校", "专业", "education", "degree");
        put(Semantic.ADDRESS, "地址", "住址", "家庭住址", "家庭地址", "现住址", "现居住地址", "户籍地址", "户籍所在地", "籍贯", "联系地址",
                "通讯地址", "送货地址", "收货地址", "公司地址", "address");
        put(Semantic.PAY, "工资", "工资金额", "基本工资", "应发工资", "实发工资", "应发", "实发", "应发合计", "实发合计", "薪资", "薪酬", "月薪",
                "底薪", "岗位工资", "绩效工资", "计件工资", "加班费", "salary", "gross pay", "net pay", "wages", "basic salary");
        put(Semantic.ATTENDANCE, "考勤", "出勤", "出勤天数", "实际出勤", "实出勤", "应出勤", "应出勤天数", "缺勤", "迟到", "早退", "旷工",
                "请假", "事假", "病假", "加班", "加班时长", "加班小时", "打卡", "打卡时间", "上班时间", "下班时间", "签到", "签退",
                "attendance", "check in", "check out", "clock in", "clock out");
        put(Semantic.GOODS_CODE, "货品编码", "货品编号", "产品编号", "产品编码", "物料编码", "物料编号", "物料代码", "料号", "品号", "存货编码",
                "存货代码", "商品编码", "商品编号", "货号", "item no", "item code", "item number", "product code", "product no",
                "part no", "part number", "sku");
        put(Semantic.GOODS_NAME, "品名", "产品名称", "货品名称", "商品名称", "物料名称", "存货名称", "产品名", "货品名", "描述",
                "product name", "product", "item", "item name", "goods name", "description");
        put(Semantic.SPEC_MODEL, "规格", "型号", "规格型号", "尺寸", "规格尺寸", "spec", "specification", "model", "size");
        put(Semantic.COLOR, "颜色", "色号", "colour", "color");
        put(Semantic.UNIT, "单位", "计量单位", "基本单位", "unit", "uom");
        put(Semantic.CATEGORY, "分类", "类别", "物料分类", "货品分类", "产品类别", "产品分类", "大类", "小类", "category");
        put(Semantic.QTY, "数量", "订购数量", "订货数量", "采购数量", "出库数量", "入库数量", "发货数量", "qty", "quantity", "order qty", "pcs");
        put(Semantic.PRICE, "单价", "价格", "含税单价", "不含税单价", "售价", "进价", "报价", "销售价", "采购价", "price", "unit price");
        put(Semantic.AMOUNT, "金额", "总金额", "合计金额", "含税金额", "不含税金额", "价税合计", "总价", "amount", "total amount", "total price");
        put(Semantic.CURRENCY, "币种", "币别", "货币", "currency");
        put(Semantic.CUSTOMER, "客户", "客户名称", "客户名", "客户全称", "客户简称", "购货单位", "customer", "customer name", "buyer", "client");
        put(Semantic.SUPPLIER, "供应商", "供应商名称", "供货商", "供应商全称", "供应商简称", "厂商", "厂家", "supplier", "vendor", "supplier name");
        put(Semantic.CONTACT, "联系人", "联系人姓名", "对接人", "contact", "contact person", "attn");
        put(Semantic.WAREHOUSE, "仓库", "仓库名称", "库位", "货位", "储位", "库区", "warehouse", "location");
        put(Semantic.STOCK_QTY, "库存", "库存数量", "库存量", "结存", "结存数量", "现存量", "现存数量", "期末数量", "期末库存", "账面数量",
                "账存数量", "盘点数量", "实盘数量", "实存数量", "在库数量", "可用库存", "stock", "on hand", "stock qty", "inventory",
                "inventory qty", "qty on hand");
        put(Semantic.BOM_PARENT, "父件", "父项", "父件编码", "父件名称", "父项编码", "成品编码", "成品名称", "上级物料", "母件",
                "parent", "parent item", "assembly");
        put(Semantic.BOM_CHILD, "子件", "子项", "子件编码", "子件名称", "子项编码", "组件", "组件名称", "组件编码", "配件", "配件名称",
                "配件编码", "零件", "零件名称", "零件编号", "component", "child item");
        put(Semantic.BOM_USAGE, "用量", "单位用量", "单耗", "定额", "每台用量", "单机用量", "标准用量", "组成用量", "usage");
        put(Semantic.TXN_DATE, "交易日期", "交易时间", "记账日期", "入账日期", "记账时间", "交易日", "transaction date", "posting date",
                "value date");
        put(Semantic.INCOME, "收入", "收入金额", "贷方", "贷方金额", "贷方发生额", "存入", "存入金额", "收款金额", "credit", "deposit");
        put(Semantic.EXPENSE, "支出", "支出金额", "借方", "借方金额", "借方发生额", "支取", "支取金额", "付款金额", "debit", "withdrawal");
        put(Semantic.BALANCE, "余额", "账户余额", "结余", "当前余额", "balance");
        put(Semantic.COUNTERPARTY, "对方户名", "对方账户名", "对方账户名称", "对方名称", "对方单位", "交易对方", "对手方", "对方账户",
                "对方账号", "counterparty", "payee", "payer");
        put(Semantic.DATE, "日期", "时间", "单据日期", "发生日期", "date");
        put(Semantic.REMARK, "备注", "说明", "摘要", "附言", "用途", "remark", "remarks", "note", "notes", "memo");
        put(Semantic.SEQ, "序号", "行号", "no", "no.");
        put(Semantic.GENERIC_CODE, "编号", "编码", "代码", "code");
        put(Semantic.GENERIC_NAME, "名称", "name");
        for (String suffix : List.of("地址", "日期", "电话", "手机", "部门", "岗位", "金额", "数量", "单价", "编码", "编号", "名称",
                "颜色", "型号", "规格", "备注", "余额", "工资", "姓名", "库存"))
            SUFFIXES.put(suffix, SYNONYMS.get(suffix));
        // Only words long enough to be unambiguous inside a longer label (3+ Chinese or 5+ Latin characters).
        CONTAINED = SYNONYMS.keySet().stream().filter(word -> word.length() >= (word.matches("[\\x00-\\x7f]+") ? 5 : 3))
                .sorted().toList();
    }

    private AiDocumentProfiler() {}

    /** Profiles every visible sheet (at most 8, at most 40 labelled columns each). */
    static Profile profile(DocumentGrid grid) {
        if (grid == null) return Profile.empty();
        List<SheetProfile> sheets = new ArrayList<>();
        for (DocumentGrid.Sheet sheet : grid.sheets().stream().limit(MAX_SHEETS).toList()) sheets.add(sheet(sheet));
        return new Profile(sheets);
    }

    private static SheetProfile sheet(DocumentGrid.Sheet sheet) {
        String name = mask(sheet.name(), LABEL_MAX);
        List<DocumentGrid.Row> scan = sheet.rows().stream().limit(HEADER_SCAN_ROWS).toList();
        int best = -1, bestHits = 1;
        for (int i = 0; i < scan.size(); i++) {
            DocumentGrid.Row row = scan.get(i);
            Map<Integer, Semantic> hits = cellSemantics(row);
            if (hits.size() <= bestHits || !headerLike(row) || form(row, hits, i + 1 < scan.size() ? scan.get(i + 1) : null)) continue;
            best = i;
            bestHits = hits.size();
        }
        if (best < 0) {
            int nonEmpty = (int) sheet.rows().stream().filter(row -> !row.joinedText().isBlank()).count();
            return new SheetProfile(name, -1, nonEmpty, List.of());
        }
        List<DocumentGrid.Row> header = new ArrayList<>(List.of(scan.get(best)));
        DocumentGrid.Row above = best > 0 ? scan.get(best - 1) : null;
        DocumentGrid.Row below = best + 1 < scan.size() ? scan.get(best + 1) : null;
        if (above != null && above.index0() == header.getFirst().index0() - 1 && headerLike(above)
                && !cellSemantics(above).isEmpty() && startsMerge(sheet, above.index0())) header.addFirst(above);
        else if (below != null && below.index0() == header.getFirst().index0() + 1 && headerLike(below)
                && !cellSemantics(below).isEmpty() && subLabels(sheet, header.getFirst().index0(), below)) header.add(below);
        int lastHeader = header.getLast().index0();
        Map<Integer, String> chosen = new TreeMap<>();
        Map<Integer, Semantic> raw = new TreeMap<>();
        for (int col : headerColumns(sheet, header)) {
            if (chosen.size() >= MAX_COLUMNS) break;
            String upper = headerText(sheet, header.getFirst().index0(), col);
            String lower = header.size() > 1 ? headerText(sheet, lastHeader, col) : "";
            if (upper.isBlank() && lower.isBlank()) continue;
            Semantic upperMeaning = upper.isBlank() ? null : semantic(upper);
            Semantic lowerMeaning = lower.isBlank() ? null : semantic(lower);
            // A lower label without meaning only inherits a filled-down parent, never a group heading above it.
            Semantic meaning = lower.isBlank() ? upperMeaning
                    : lowerMeaning != null ? lowerMeaning : lower.equals(upper) ? upperMeaning : null;
            chosen.put(col, lower.isBlank() ? upper : lower);
            if (meaning != null) raw.put(col, meaning);
        }
        Map<Integer, Semantic> resolved = resolve(raw);
        List<DocumentGrid.Row> data = new ArrayList<>();
        for (DocumentGrid.Row row : sheet.rows()) {
            if (row.index0() <= lastHeader || total(row)) continue;
            long filled = row.cells().stream().filter(cell -> chosen.containsKey(cell.col0()) && !cell.text().isBlank()).count();
            if (filled < Math.min(2, chosen.size())) continue;
            if (repeatsHeader(row, chosen)) continue;  // the header printed again on a following page
            data.add(row);
        }
        List<Column> columns = new ArrayList<>();
        for (var entry : chosen.entrySet()) {
            List<Shape> samples = new ArrayList<>();
            for (DocumentGrid.Row row : data.subList(0, Math.min(SHAPE_SAMPLES, data.size()))) {
                DocumentGrid.Cell cell = row.cell(entry.getKey());
                if (cell != null && !cell.text().isBlank()) samples.add(shape(cell));
            }
            columns.add(new Column(entry.getKey(), mask(entry.getValue(), LABEL_MAX), resolved.get(entry.getKey()), dominant(samples)));
        }
        return new SheetProfile(name, header.getFirst().index0(), data.size(), columns);
    }

    /**
     * Semantics of the best header line of a text document (PDF/DOCX, or a header kept in one cell): within the
     * first 15 lines, at least two different meanings, no value-looking token and not a "key: value" form line.
     */
    static Set<Semantic> lineSemantics(List<String> lines) {
        if (lines == null) return Set.of();
        Map<Integer, Semantic> best = Map.of();
        int bestCount = 1, scanned = 0;
        for (String line : lines) {
            if (line == null || line.isBlank()) continue;
            if (++scanned > HEADER_SCAN_ROWS) break;
            if (line.length() > 300) continue;
            String[] tokens = TOKEN_SPLIT.split(normalize(line));
            Map<Integer, Semantic> hits = new TreeMap<>();
            int keyed = 0;
            boolean values = false;
            for (int i = 0; i < tokens.length; i++) {
                if (tokens[i].isBlank()) continue;
                if (VALUE_SHAPES.contains(textShape(tokens[i]))) values = true;
                Semantic meaning = semantic(tokens[i]);
                if (meaning == null) continue;
                hits.put(i, meaning);
                if (tokens[i].endsWith(":")) keyed++;
            }
            int distinct = (int) hits.values().stream().distinct().count();
            if (!values && keyed < 2 && distinct > bestCount) {
                best = hits;
                bestCount = distinct;
            }
        }
        EnumSet<Semantic> result = EnumSet.noneOf(Semantic.class);
        result.addAll(resolve(best).values());
        result.removeAll(EVIDENCE_ONLY);
        return result;
    }

    /** Meaning of one header label without context; null when it is not a known header word. */
    static Semantic semantic(String label) {
        String key = label(label);
        if (key.isEmpty() || key.length() > 40) return null;
        Semantic exact = SYNONYMS.get(key);
        if (exact != null) return exact;
        for (String part : key.split("[/、|&+]")) {
            Semantic found = SYNONYMS.get(part.strip());
            if (found != null) return found;
        }
        if (key.length() > 16) return null;
        String ending = null, longest = null;
        for (String synonym : CONTAINED) {
            if (!key.contains(synonym)) continue;
            if (key.endsWith(synonym) && (ending == null || synonym.length() > ending.length())) ending = synonym;
            if (longest == null || synonym.length() > longest.length()) longest = synonym;
        }
        // 员工身份证号码 ends with what it contains; 身份证地址 and 联系人电话 are named by their last word.
        if (ending != null) return SYNONYMS.get(ending);
        for (var suffix : SUFFIXES.entrySet()) if (key.endsWith(suffix.getKey())) return suffix.getValue();
        return longest == null ? null : SYNONYMS.get(longest);
    }

    /** Digit runs of three or more (also split by spaces or dashes) and e-mail addresses become '#', then trimmed. */
    static String mask(String text, int max) {
        if (text == null) return "";
        String value = Normalizer.normalize(text, Normalizer.Form.NFKC).replaceAll("[\\p{Cntrl}\\p{Zl}\\p{Zp}]+", " ")
                .replaceAll("\\s+", " ").strip();
        value = DIGIT_RUN.matcher(EMAIL.matcher(value).replaceAll("#")).replaceAll("#");
        return value.codePointCount(0, value.length()) <= max ? value : value.substring(0, value.offsetByCodePoints(0, max));
    }

    static Shape shape(DocumentGrid.Cell cell) {
        if (cell == null || cell.text().isBlank()) return Shape.EMPTY;
        return switch (cell.kind()) {
            case DATE -> Shape.DATE;
            case BOOLEAN -> Shape.SHORT_TEXT;
            case NUMBER -> numberShape(cell);
            case TEXT -> textShape(cell.text());
        };
    }

    private static Shape numberShape(DocumentGrid.Cell cell) {
        BigDecimal number = cell.number();
        if (number == null) return textShape(cell.text());
        BigDecimal plain = number.stripTrailingZeros();
        if (plain.scale() > 0) return Shape.AMOUNT;
        String digits = plain.abs().toBigInteger().toString();
        if (digits.length() == 11 && digits.startsWith("1")) return Shape.PHONE11;
        if (digits.length() >= 15 && digits.length() <= 18) return Shape.ID18;
        return Shape.INTEGER;
    }

    private static Shape textShape(String raw) {
        String text = Normalizer.normalize(raw, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).strip();
        if (text.isEmpty()) return Shape.EMPTY;
        if (ID18.matcher(text).matches()) return Shape.ID18;
        if (PHONE11.matcher(text).matches()) return Shape.PHONE11;
        if (DATE_TEXT.matcher(text).matches()) return Shape.DATE;
        if (AMOUNT_TEXT.matcher(text).matches()) return Shape.AMOUNT;
        if (INTEGER_TEXT.matcher(text).matches()) return Shape.INTEGER;
        if (CODE_TEXT.matcher(text).matches()) return Shape.CODE;
        return text.codePointCount(0, text.length()) <= 8 ? Shape.SHORT_TEXT : Shape.TEXT;
    }

    private static Shape dominant(List<Shape> samples) {
        if (samples.isEmpty()) return Shape.EMPTY;
        Map<Shape, Integer> counts = new EnumMap<>(Shape.class);
        samples.forEach(shape -> counts.merge(shape, 1, Integer::sum));
        return Collections.max(counts.entrySet(), Map.Entry.<Shape, Integer>comparingByValue()
                .thenComparing(entry -> -entry.getKey().ordinal())).getKey();
    }

    /** Generic words take their meaning from the rest of the header (编号 is a staff number only next to 姓名). */
    private static Map<Integer, Semantic> resolve(Map<Integer, Semantic> raw) {
        EnumSet<Semantic> present = EnumSet.noneOf(Semantic.class);
        present.addAll(raw.values());
        boolean goods = present.stream().anyMatch(GOODS_CONTEXT::contains);
        boolean person = present.contains(Semantic.PERSON_NAME) || present.stream().anyMatch(PERSON_CONTEXT::contains);
        Map<Integer, Semantic> resolved = new TreeMap<>();
        raw.forEach((col, meaning) -> resolved.put(col, switch (meaning) {
            case GENERIC_CODE -> present.contains(Semantic.PERSON_NAME) ? Semantic.EMPLOYEE_CODE : goods ? Semantic.GOODS_CODE : meaning;
            case GENERIC_NAME -> goods ? Semantic.GOODS_NAME : person ? Semantic.PERSON_NAME : meaning;
            default -> meaning;
        }));
        return resolved;
    }

    /** Distinct meanings of the text cells of a row, keyed by column (the first column of each meaning). */
    private static Map<Integer, Semantic> cellSemantics(DocumentGrid.Row row) {
        Map<Integer, Semantic> hits = new TreeMap<>();
        for (DocumentGrid.Cell cell : row.cells()) {
            if (cell.kind() != DocumentGrid.CellKind.TEXT) continue;
            Semantic meaning = semantic(cell.text());
            if (meaning != null && !hits.containsValue(meaning)) hits.put(cell.col0(), meaning);
        }
        return hits;
    }

    /** A header holds only words: no number, date, ID, phone or amount cell. */
    private static boolean headerLike(DocumentGrid.Row row) {
        for (DocumentGrid.Cell cell : row.cells())
            if (cell.kind() != DocumentGrid.CellKind.TEXT || VALUE_SHAPES.contains(textShape(cell.text()))) return false;
        return true;
    }

    /**
     * A "key value key value" form row (姓名 | 某某 | 部门 | 某部) is not a table header: at least two keys are
     * directly followed by a value cell and the next row repeats keys in the same columns (or there is none).
     * A value may itself read like its key (部门 | 销售部门), so a neighbour of the same meaning that is not a
     * header word of its own (基本工资 | 岗位工资 are two columns) is a value too.
     */
    private static boolean form(DocumentGrid.Row row, Map<Integer, Semantic> hits, DocumentGrid.Row next) {
        int keyed = 0;
        for (var key : hits.entrySet()) {
            DocumentGrid.Cell value = row.cell(key.getKey() + 1);
            if (value == null || value.text().isBlank()) continue;
            Semantic meaning = semantic(value.text());
            if (meaning == null || (meaning == key.getValue() && !SYNONYMS.containsKey(label(value.text())))) keyed++;
        }
        if (keyed < 2) return false;
        return next == null || cellSemantics(next).keySet().stream().anyMatch(hits::containsKey);
    }

    private static TreeSet<Integer> headerColumns(DocumentGrid.Sheet sheet, List<DocumentGrid.Row> header) {
        TreeSet<Integer> columns = new TreeSet<>();
        header.forEach(row -> row.cells().forEach(cell -> columns.add(cell.col0())));
        int first = header.getFirst().index0(), last = header.getLast().index0();
        for (DocumentGrid.MergedRange merge : sheet.merges())
            if (merge.firstRow() <= last && merge.lastRow() >= first)
                for (int col = merge.firstCol(); col <= Math.min(merge.lastCol(), merge.firstCol() + MAX_COLUMNS); col++) columns.add(col);
        return columns;
    }

    private static boolean repeatsHeader(DocumentGrid.Row row, Map<Integer, String> labels) {
        return row.cells().stream().filter(cell -> cell.text().strip().equals(labels.getOrDefault(cell.col0(), "").strip())).count() >= 2;
    }

    /**
     * A second header row holds only sub-labels under a group heading merged across columns in the row above
     * (联系方式 over 手机 | 邮箱). A first data row of words only (钱试一 | 销售部门) never qualifies, so its
     * values can never become labels.
     */
    private static boolean subLabels(DocumentGrid.Sheet sheet, int upper, DocumentGrid.Row below) {
        for (DocumentGrid.Cell cell : below.cells()) {
            if (cell.text().isBlank()) continue;
            DocumentGrid.MergedRange group = sheet.mergeAt(upper, cell.col0());
            if (group == null || group.firstRow() != upper || group.lastRow() != upper || group.lastCol() == group.firstCol()) return false;
        }
        return true;
    }

    private static boolean startsMerge(DocumentGrid.Sheet sheet, int row0) {
        return sheet.merges().stream().anyMatch(merge -> merge.firstRow() == row0);
    }

    /** Header text with merged cells filled down and across from their top-left cell. */
    private static String headerText(DocumentGrid.Sheet sheet, int row0, int col0) {
        String text = sheet.text(row0, col0);
        if (!text.isBlank()) return text;
        DocumentGrid.MergedRange merge = sheet.mergeAt(row0, col0);
        return merge == null ? "" : sheet.text(merge.firstRow(), merge.firstCol());
    }

    private static boolean total(DocumentGrid.Row row) {
        for (DocumentGrid.Cell cell : row.cells().stream().limit(3).toList())
            if (TOTAL.matcher(normalize(cell.text())).find()) return true;
        return false;
    }

    /** Header label as a dictionary key: case, width, brackets, markers and spaces next to Chinese removed. */
    private static String label(String text) {
        String value = BRACKETS.matcher(normalize(text)).replaceAll("");
        value = value.replaceAll("^[*※★#\\s]+|[*:\\s]+$", "");
        return value.replaceAll("\\s+(?=\\p{IsHan})|(?<=\\p{IsHan})\\s+", "").strip();
    }

    private static String normalize(String text) {
        return Normalizer.normalize(text == null ? "" : text, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
                .replace('\uFEFF', ' ').replaceAll("\\s+", " ").strip();
    }

    private static void put(Semantic meaning, String... words) {
        for (String word : words) SYNONYMS.put(label(word), meaning);
    }
}
