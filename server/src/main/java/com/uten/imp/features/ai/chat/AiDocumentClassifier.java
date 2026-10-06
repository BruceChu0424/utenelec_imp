package com.uten.imp.features.ai.chat;

import com.uten.imp.common.files.document.InvoiceMultiplicity;
import com.uten.imp.features.ai.chat.AiDocumentProfiler.Semantic;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Classifies document evidence, not words incidentally mentioned in a product or a note. Titles decide first;
 * the detected column header (see {@link AiDocumentProfiler}) only adds a type of the same business family,
 * so a column header can never turn a titled quotation into a mixed file.
 */
final class AiDocumentClassifier {
    /** evidence: TITLE, COLUMNS or FIELDS (invoice number and total); empty for UNKNOWN and MIXED_DOCUMENT. */
    record Classification(String type, boolean multipleInvoices, String evidence) {}
    private enum Family { TRADE, TAX_INVOICE, HR, WAREHOUSE, PRODUCTION, PURCHASE, CONTRACT, MASTER, FINANCE }

    private static final Pattern NOTE = Pattern.compile("^(?:\\d+[.)、]\\s*|(?:备注|说明|条款|附注|注意|参考|开票要求|发票要求|开票类型|发票类型|"
            + "notes?|remarks?|terms(?: and conditions)?|references?|invoice type|invoice requirements?)\\s*[:：\\s])");
    private static final Pattern CONTRACT_REFERENCE = Pattern.compile("^(?:(?:sales |purchase |employment )?(?:contract|agreement)|"
            + "(?:销售|采购|劳动|服务)?合同)\\s*(?:no\\.?|number|编号|号码|号)\\s*[:：#]?");
    private static final Pattern PERIOD = Pattern.compile("^(?:\\d{4}年\\d{1,2}月(?:份)?|\\d{4}[-/.]\\d{1,2}(?:[-/.]\\d{1,2})?)\\s*");
    private static final Pattern DATE_TAIL = Pattern.compile("(?:(?:截至|截止|统计(?:日期|时间)?|更新(?:日期|时间)?)\\s*[:：]?\\s*)?"
            + "(?:\\d{4}[-/.年]\\d{1,2}(?:[-/.月]\\d{1,2}日?|月)?|"
            + "(?:january|february|march|april|may|june|july|august|september|october|november|december) \\d{4})");
    private static final Pattern NUMBER_TAIL = Pattern.compile("(?:(?:no\\.?|number|编号|单号)\\s*[:：#]?\\s*)?[a-z]{1,12}[-/]?\\d[a-z0-9./-]{0,40}");
    /** Qualifiers a list title may carry: 员工花名册(在职), 客户名单汇总. */
    private static final Pattern LIST_TAIL = Pattern.compile("(?:在职|离职|全体|全员|汇总|明细|总表|一览表?|统计表?|最新|更新)+");
    /** A company, department or period in front of a list title: 某某有限公司2026年10月员工花名册. */
    private static final String OWNER = "(?:[\\p{IsHan}\\p{L}\\p{N}()&·.\\- ]{1,40}?(?:有限责任公司|有限公司|股份公司|公司|集团|工厂|厂"
            + "|人事部|行政部|部门|部|车间|中心))?\\s*(?:\\d{4}\\s*年(?:\\s*\\d{1,2}\\s*月(?:份)?)?|\\d{4}[-/.]\\d{1,2})?\\s*";
    private static final Pattern TAX_TITLE = title("(?:[\\p{IsHan}]{2,8})?增值税(?:专用|普通|电子普通|电子专用)发票|"
            + "(?:全电|电子)(?:普通|专用)?发票|(?:vat|tax) invoice");
    private static final Pattern COMMERCIAL_TITLE = title("commercial invoice|商业发票");
    private static final Pattern PROFORMA_TITLE = title("pro[ -]?forma invoice|形式发票");
    private static final Pattern QUOTE_TITLE = title("(?:客户|销售|产品)?报价单(?: quotation)?|报价|price quotation|sales quotation|quotation|quote");
    private static final Pattern ORDER_TITLE = title("客户订单|订货单|销售订单(?: sales order)?|sales order|purchase order|order confirmation");
    private static final Pattern PURCHASE_TITLE = title("采购(?:订单|订货单|单)(?: purchase order)?");
    private static final Pattern PAYROLL_TITLE = title("(?:员工|月度|年度)?工资(?:表|单|明细表|明细)|薪酬(?:表|明细表)|"
            + "(?:monthly )?payroll(?: report| summary)?|payslip");
    private static final Pattern HR_FORM_TITLE = title("员工档案|入职登记(?:表)?|离职申请(?:表)?|employee (?:record|registration)");
    private static final Pattern ROSTER_TITLE = listTitle("(?:员工|人员|职员)?花名册|员工信息表|人员信息表|员工名册|员工名单|人员名单"
            + "|在职(?:人员|员工)名单|employee roster|staff (?:list|roster)|employee list");
    private static final Pattern ATTENDANCE_TITLE = listTitle("(?:员工)?考勤(?:表|记录|汇总表?|明细表?)|打卡记录|出勤(?:表|记录|统计表?)"
            + "|attendance (?:sheet|record|report)");
    private static final Pattern GOODS_TITLE = listTitle("货品(?:资料|清单|档案)|产品(?:资料|清单|目录)|商品清单|物料(?:资料|档案)"
            + "|product (?:list|catalog(?:ue)?)");
    private static final Pattern BOM_TITLE = listTitle("(?:产品)?配件清单|物料清单|bom(?:清单|表)?|材料清单|组装明细|产品结构表"
            + "|bill of materials?");
    private static final Pattern CUSTOMER_TITLE = listTitle("客户(?:资料|名单|清单|信息表|档案|通讯录)|customer list");
    private static final Pattern SUPPLIER_TITLE = listTitle("供应商(?:资料|名单|清单|信息表|档案|通讯录)|(?:supplier|vendor) list");
    private static final Pattern STOCK_TITLE = listTitle("库存(?:表|清单|明细|报表)|盘点清单|inventory list|stock list");
    private static final Pattern COUNT_TITLE = title("库存盘点(?:表)?|盘点表|inventory count(?: sheet)?");
    private static final Pattern WAREHOUSE_TITLE = title("入库单|出库单");
    private static final Pattern BANK_TITLE = listTitle("银行(?:流水|对账单|账户明细)|对账单|账户明细|交易明细|(?:bank|account) statement");
    private static final Pattern PRODUCTION_TITLE = title("生产任务单|生产日报|工序日报|生产计划(?:单)?");
    private static final Pattern CONTRACT_TITLE = title("(?:销售|采购|劳动|服务)?合同|(?:sales |purchase |employment )?(?:contract|agreement)");
    /**
     * A non-trade title and the type it names. List titles (客户资料, 交易明细...) also appear as section headings
     * inside other documents, so they count only among the first lines of a sheet or page (top) and only when
     * no other document title is present.
     */
    private record TitleRule(Pattern title, String type, boolean top) {}
    private static final int TOP_LINES = 3;
    private static final List<TitleRule> TYPED_TITLES = List.of(
            new TitleRule(PURCHASE_TITLE, "PURCHASE_DOCUMENT", false), new TitleRule(PAYROLL_TITLE, "PAYROLL", false),
            new TitleRule(ROSTER_TITLE, "EMPLOYEE_ROSTER", true), new TitleRule(ATTENDANCE_TITLE, "ATTENDANCE", true),
            new TitleRule(HR_FORM_TITLE, "HR_DOCUMENT", false), new TitleRule(GOODS_TITLE, "GOODS_LIST", true),
            new TitleRule(BOM_TITLE, "BOM_LIST", true), new TitleRule(CUSTOMER_TITLE, "CUSTOMER_LIST", true),
            new TitleRule(SUPPLIER_TITLE, "SUPPLIER_LIST", true), new TitleRule(STOCK_TITLE, "STOCK_LIST", true),
            new TitleRule(COUNT_TITLE, "STOCK_LIST", false), new TitleRule(WAREHOUSE_TITLE, "WAREHOUSE_DOCUMENT", false),
            new TitleRule(BANK_TITLE, "BANK_STATEMENT", true), new TitleRule(PRODUCTION_TITLE, "PRODUCTION_DOCUMENT", false),
            new TitleRule(CONTRACT_TITLE, "CONTRACT", false));
    private static final List<Pattern> TITLES = List.of(PURCHASE_TITLE, PAYROLL_TITLE, HR_FORM_TITLE, ROSTER_TITLE, ATTENDANCE_TITLE,
            GOODS_TITLE, BOM_TITLE, CUSTOMER_TITLE, SUPPLIER_TITLE, STOCK_TITLE, COUNT_TITLE, WAREHOUSE_TITLE, BANK_TITLE,
            PRODUCTION_TITLE, CONTRACT_TITLE, TAX_TITLE, COMMERCIAL_TITLE, PROFORMA_TITLE, QUOTE_TITLE, ORDER_TITLE);
    private static final Pattern INVOICE_NUMBER = field("发\\s*票\\s*(?:号\\s*码|号)|invoice\\s*(?:no\\.?|number|#)");
    private static final Pattern INVOICE_TOTAL = field("价\\s*税\\s*合\\s*计|grand total");
    private static final Pattern QUOTE_DATE = field("报价日期|quotation date|quote date");
    private static final Pattern GOODS = words("品名", "产品名称", "货品名称", "商品名称", "产品编号", "货品编码", "物料编码", "型号", "描述",
            "item", "item no", "item code", "product", "product code", "product name", "description", "model");
    private static final Pattern QUANTITY = words("数量", "订购数量", "订货数量", "qty", "quantity", "order qty");
    private static final Pattern PRICE = words("单价", "价格", "含税单价", "不含税单价", "price", "unit price");
    private static final Pattern PERSON = words("工号", "员工编号", "员工姓名", "姓名", "employee", "employee id", "employee name", "staff name");
    private static final Pattern PAY = words("工资", "工资金额", "基本工资", "应发工资", "实发工资", "应发", "实发", "薪资", "薪酬", "salary", "gross pay", "net pay", "wages");
    private static final Set<Semantic> ROSTER_FACTS = EnumSet.of(Semantic.ID_NUMBER, Semantic.PHONE, Semantic.DEPARTMENT,
            Semantic.POSITION, Semantic.HIRE_DATE, Semantic.EMPLOYEE_CODE, Semantic.GENDER);
    private static final Set<Semantic> MONEY = EnumSet.of(Semantic.PAY, Semantic.AMOUNT, Semantic.PRICE, Semantic.QTY,
            Semantic.INCOME, Semantic.EXPENSE, Semantic.BALANCE);
    private static final Set<Semantic> GOODS_DETAIL = EnumSet.of(Semantic.SPEC_MODEL, Semantic.UNIT, Semantic.COLOR, Semantic.CATEGORY);
    private static final Set<Semantic> PARTY_DETAIL = EnumSet.of(Semantic.CONTACT, Semantic.PHONE, Semantic.ADDRESS);
    /** Generic titles a more specific column header of the same family may refine (员工档案 + roster columns). */
    private static final Set<String> GENERIC = Set.of("HR_DOCUMENT");

    private AiDocumentClassifier() {}

    static Classification classify(List<String> rawLines) {
        return classify(rawLines, Set.of());
    }

    /**
     * @param columns meanings of the detected column header of this sheet; empty means "find a header line in
     *                the text itself" (PDF, Word, or a header written in one cell)
     */
    static Classification classify(List<String> rawLines, Set<Semantic> columns) {
        List<String> lines = lines(rawLines);
        EnumSet<Family> families = EnumSet.noneOf(Family.class);
        Map<String, String> typed = new LinkedHashMap<>(), lists = new LinkedHashMap<>();
        boolean quotation = false, order = false, commercial = false;
        boolean number = false, total = false, domesticInvoiceField = false, quoteDate = false;
        int position = 0;
        for (String line : lines) {
            if (note(line)) continue;
            boolean top = position++ < TOP_LINES;
            // Specific procurement titles are evaluated independently from the generic sales title.
            // "采购订货单" is one title, not an occurrence of a second "订货单" document.
            for (TitleRule rule : TYPED_TITLES) {
                if ((rule.top() && !top) || !heading(line, rule.title())) continue;
                if (rule.top()) lists.putIfAbsent(rule.type(), "TITLE");
                else { typed.putIfAbsent(rule.type(), "TITLE"); families.add(family(rule.type())); }
            }
            if (headerLine(line) && matches(line, PERSON) && matches(line, PAY)) { typed.putIfAbsent("PAYROLL", "COLUMNS"); families.add(Family.HR); }
            if (heading(line, TAX_TITLE)) families.add(Family.TAX_INVOICE);
            if (heading(line, PROFORMA_TITLE) || heading(line, ORDER_TITLE)) { families.add(Family.TRADE); order = true; }
            if (heading(line, QUOTE_TITLE)) { families.add(Family.TRADE); quotation = true; }
            if (line.equals("invoice") || heading(line, COMMERCIAL_TITLE)) { families.add(Family.TRADE); commercial = true; }
            boolean numberField = INVOICE_NUMBER.matcher(line).find(), totalField = INVOICE_TOTAL.matcher(line).find();
            number |= numberField; total |= totalField;
            String compact = line.replace(" ", "");
            domesticInvoiceField |= (numberField && compact.startsWith("发票")) || (totalField && compact.startsWith("价税合计"));
            quoteDate |= QUOTE_DATE.matcher(line).find();
        }
        // A list heading never adds a second business to a titled document: a quotation with a 客户资料 block
        // stays a quotation, while 员工档案 above a 员工名单 is still one personnel file.
        if (families.isEmpty() || lists.keySet().stream().allMatch(type -> families.contains(family(type))))
            lists.forEach((type, evidence) -> { typed.putIfAbsent(type, evidence); families.add(family(type)); });
        boolean goodsTable = hasGoodsTable(lines);
        // A column header only refines its own family; it never adds a second business to a titled file,
        // and a goods table with quantity and price stays a sales source exactly as before.
        String header = goodsTable ? null : columnType(columns == null || columns.isEmpty() ? AiDocumentProfiler.lineSemantics(lines) : columns);
        if (header != null && (families.isEmpty() || families.equals(EnumSet.of(family(header))))) {
            typed.putIfAbsent(header, "COLUMNS"); families.add(family(header));
        }
        String fields = "";
        // Number/total fields can identify an otherwise untitled invoice. They cannot overrule a
        // quotation, warehouse slip, or other explicit document title merely referencing an invoice.
        if (families.isEmpty() && number && total) {
            fields = "FIELDS";
            if (domesticInvoiceField) families.add(Family.TAX_INVOICE);
            else { families.add(Family.TRADE); commercial = true; }
        }
        if (families.size() > 1) return result("MIXED_DOCUMENT", "");
        if (families.contains(Family.TAX_INVOICE))
            return new Classification("INVOICE", InvoiceMultiplicity.multiple(invoiceLines(lines)), fields.isEmpty() ? "TITLE" : fields);
        if (!typed.isEmpty() && !families.contains(Family.TRADE)) {
            String type = typed.keySet().stream().filter(value -> !GENERIC.contains(value)).findFirst().orElse(typed.keySet().iterator().next());
            return result(type, typed.get(type));
        }
        if (order) return result("SALES_ORDER", "TITLE");
        if (quotation) return result("SALES_QUOTATION", "TITLE");
        if (commercial) return new Classification("COMMERCIAL_INVOICE", InvoiceMultiplicity.multiple(invoiceLines(lines)), fields.isEmpty() ? "TITLE" : fields);
        if (goodsTable) return result(quoteDate ? "SALES_QUOTATION" : "SALES_TABLE", "COLUMNS");
        return result("UNKNOWN", "");
    }

    static Classification classifySections(List<List<String>> sections) {
        return classifySections(sections, List.of());
    }

    /** Sheet/page boundaries are kept; metadata in another section never supplies an invoice title. */
    static Classification classifySections(List<List<String>> sections, List<Set<Semantic>> columns) {
        if (sections == null || sections.isEmpty()) return result("UNKNOWN", "");
        Map<String, String> types = new LinkedHashMap<>();
        EnumSet<Family> families = EnumSet.noneOf(Family.class);
        List<String> invoiceEvidence = new ArrayList<>();
        boolean multiple = false;
        for (int i = 0; i < sections.size(); i++) {
            List<String> section = sections.get(i);
            Classification part = classify(section, columns != null && i < columns.size() ? columns.get(i) : Set.of());
            if (part.type().equals("MIXED_DOCUMENT")) return part;
            Family family = family(part.type());
            if (family == null) continue;
            types.putIfAbsent(part.type(), part.evidence()); families.add(family); multiple |= part.multipleInvoices();
            if (part.type().equals("INVOICE") || part.type().equals("COMMERCIAL_INVOICE"))
                invoiceEvidence.addAll(invoiceLines(lines(section)));
        }
        if (families.size() > 1) return result("MIXED_DOCUMENT", "");
        if (types.isEmpty()) return result("UNKNOWN", "");
        multiple |= InvoiceMultiplicity.multiple(invoiceEvidence);
        String type;
        if (types.containsKey("SALES_ORDER")) type = "SALES_ORDER";
        else if (types.containsKey("SALES_QUOTATION")) type = "SALES_QUOTATION";
        else if (types.containsKey("COMMERCIAL_INVOICE")) type = "COMMERCIAL_INVOICE";
        else if (types.containsKey("SALES_TABLE")) type = "SALES_TABLE";
        else type = types.keySet().stream().filter(value -> !GENERIC.contains(value)).findFirst().orElse(types.keySet().iterator().next());
        return new Classification(type, multiple, types.get(type));
    }

    /**
     * Type implied by a column header alone, or null. Person + pay is payroll, person + attendance is an
     * attendance sheet, a person with at least two identity facts and no money column is a roster.
     */
    static String columnType(Set<Semantic> s) {
        if (s == null || s.isEmpty()) return null;
        boolean person = s.contains(Semantic.PERSON_NAME);
        boolean goods = s.contains(Semantic.GOODS_CODE) || s.contains(Semantic.GOODS_NAME);
        if (person && s.contains(Semantic.PAY)) return "PAYROLL";
        if (person && s.contains(Semantic.ATTENDANCE)) return "ATTENDANCE";
        if (person && !goods && s.stream().filter(ROSTER_FACTS::contains).count() >= 2 && s.stream().noneMatch(MONEY::contains))
            return "EMPLOYEE_ROSTER";
        if ((s.contains(Semantic.BOM_PARENT) && s.contains(Semantic.BOM_CHILD)) || (s.contains(Semantic.BOM_CHILD) && s.contains(Semantic.BOM_USAGE))
                || (goods && s.contains(Semantic.BOM_USAGE))) return "BOM_LIST";
        if (goods && (s.contains(Semantic.STOCK_QTY) || (s.contains(Semantic.WAREHOUSE) && s.contains(Semantic.QTY)))) return "STOCK_LIST";
        boolean income = s.contains(Semantic.INCOME) || s.contains(Semantic.EXPENSE);
        if ((s.contains(Semantic.TXN_DATE) && income) || (s.contains(Semantic.DATE) && s.contains(Semantic.BALANCE) && income))
            return "BANK_STATEMENT";
        if (!goods && s.contains(Semantic.CUSTOMER) && s.stream().anyMatch(PARTY_DETAIL::contains)) return "CUSTOMER_LIST";
        if (!goods && s.contains(Semantic.SUPPLIER) && s.stream().anyMatch(PARTY_DETAIL::contains)) return "SUPPLIER_LIST";
        if (goods && s.stream().anyMatch(GOODS_DETAIL::contains) && !(s.contains(Semantic.QTY) && s.contains(Semantic.PRICE)))
            return "GOODS_LIST";
        return null;
    }

    /** Goods, quantity and price must be neighboring column headings, not three words anywhere in a file. */
    static boolean hasGoodsTable(List<String> rawLines) {
        List<String> lines = lines(rawLines);
        for (int start = 0; start < lines.size(); start++) {
            boolean goods = false, quantity = false, price = false;
            for (int row = start; row < Math.min(start + 3, lines.size()); row++) {
                String line = lines.get(row);
                if (!headerLine(line)) break;
                goods |= matches(line, GOODS); quantity |= matches(line, QUANTITY); price |= matches(line, PRICE);
                if (goods && quantity && price) return true;
            }
        }
        return false;
    }

    private static boolean heading(String line, Pattern title) {
        if (line.length() > 300) return false;
        String value = PERIOD.matcher(line).replaceFirst("");
        var match = title.matcher(value);
        if (!match.find()) return false;
        String tail = value.substring(match.end()).strip().replaceAll("^[:：\\-—(（]+|[)）]+$", "").strip();
        return tail.isEmpty() || DATE_TAIL.matcher(tail).matches() || NUMBER_TAIL.matcher(tail).matches()
                || (title.pattern().startsWith("^" + OWNER) && LIST_TAIL.matcher(tail).matches())
                || (headerLine(tail) && ((matches(tail, GOODS) && (matches(tail, QUANTITY) || matches(tail, PRICE)))
                    || (matches(tail, PERSON) && matches(tail, PAY))));
    }

    private static List<String> invoiceLines(List<String> lines) {
        return lines.stream().filter(line -> !note(line))
                .filter(line -> INVOICE_NUMBER.matcher(line).find() || INVOICE_TOTAL.matcher(line).find()).toList();
    }
    private static boolean headerLine(String line) { return !line.isBlank() && line.length() <= 300 && !note(line); }
    private static boolean note(String line) { return NOTE.matcher(line).find() || CONTRACT_REFERENCE.matcher(line).find(); }
    private static boolean matches(String line, Pattern pattern) { return pattern.matcher(line).find(); }
    private static Pattern title(String alternatives) { return Pattern.compile("^(?:" + alternatives + ")(?=$|[\\s:：(（\\-—|/、;+])"); }
    /** List titles may follow the owner's name or the period, and may carry a short qualifier after them. */
    private static Pattern listTitle(String alternatives) { return Pattern.compile("^" + OWNER + "(?:" + alternatives + ")(?=$|[\\s:：(\\-—|/、;+]|"
            + LIST_TAIL.pattern() + ")"); }
    private static Pattern field(String alternatives) { return Pattern.compile("^(?:" + alternatives + ")(?=$|[\\s:：(（#0-9])"); }
    private static Pattern words(String... values) {
        return Pattern.compile("(?<![\\p{L}\\p{N}])(?:" + java.util.Arrays.stream(values).map(Pattern::quote)
                .collect(java.util.stream.Collectors.joining("|")) + ")(?![\\p{L}\\p{N}])");
    }
    private static List<String> lines(List<String> raw) {
        if (raw == null) return List.of();
        List<String> result = new ArrayList<>();
        for (String value : raw) if (value != null) {
            String normalized = Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
            for (String line : normalized.split("\\R")) {
                String clean = line.replace('\uFEFF', ' ').replaceAll("[\\p{Zs}\\t]+", " ").strip();
                if (!clean.isEmpty()) result.addAll(titleFragments(clean));
            }
        }
        return result;
    }
    /** joinedText may place two title cells on one line. Split only a complete sequence of titles. */
    private static List<String> titleFragments(String line) {
        if (line.length() > 300 || note(line)) return List.of(line);
        List<String> fragments = new ArrayList<>();
        String remaining = line;
        while (!remaining.isEmpty()) {
            int longest = 0;
            for (Pattern title : TITLES) {
                var match = title.matcher(remaining);
                if (match.find()) longest = Math.max(longest, match.end());
            }
            if (longest == 0) return List.of(line);
            fragments.add(remaining.substring(0, longest));
            remaining = remaining.substring(longest).replaceFirst("^[\\s:：|/、;+]+", "").strip();
        }
        return fragments.size() > 1 ? fragments : List.of(line);
    }
    private static Family family(String type) {
        if (type.startsWith("SALES_") || type.equals("COMMERCIAL_INVOICE")) return Family.TRADE;
        return switch (type) {
            case "INVOICE" -> Family.TAX_INVOICE;
            case "HR_DOCUMENT", "EMPLOYEE_ROSTER", "PAYROLL", "ATTENDANCE" -> Family.HR;
            case "WAREHOUSE_DOCUMENT", "STOCK_LIST" -> Family.WAREHOUSE;
            case "PRODUCTION_DOCUMENT" -> Family.PRODUCTION;
            case "PURCHASE_DOCUMENT" -> Family.PURCHASE;
            case "CONTRACT" -> Family.CONTRACT;
            case "GOODS_LIST", "BOM_LIST", "CUSTOMER_LIST", "SUPPLIER_LIST" -> Family.MASTER;
            case "BANK_STATEMENT" -> Family.FINANCE;
            default -> null;
        };
    }
    private static Classification result(String type, String evidence) { return new Classification(type, false, evidence); }
}
