package com.uten.imp.features.ai.chat;

import com.uten.imp.common.files.document.InvoiceMultiplicity;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;

/** Classifies document evidence, not words incidentally mentioned in a product or a note. */
final class AiDocumentClassifier {
    record Classification(String type, boolean multipleInvoices) {}
    private enum Family { TRADE, TAX_INVOICE, HR, WAREHOUSE, PRODUCTION, PURCHASE, CONTRACT }

    private static final Pattern NOTE = Pattern.compile("^(?:\\d+[.)、]\\s*|(?:备注|说明|条款|附注|注意|参考|开票要求|发票要求|开票类型|发票类型|"
            + "notes?|remarks?|terms(?: and conditions)?|references?|invoice type|invoice requirements?)\\s*[:：\\s])");
    private static final Pattern CONTRACT_REFERENCE = Pattern.compile("^(?:(?:sales |purchase |employment )?(?:contract|agreement)|"
            + "(?:销售|采购|劳动|服务)?合同)\\s*(?:no\\.?|number|编号|号码|号)\\s*[:：#]?");
    private static final Pattern PERIOD = Pattern.compile("^(?:\\d{4}年\\d{1,2}月(?:份)?|\\d{4}[-/.]\\d{1,2}(?:[-/.]\\d{1,2})?)\\s*");
    private static final Pattern DATE_TAIL = Pattern.compile("(?:\\d{4}[-/.年]\\d{1,2}(?:[-/.月]\\d{1,2}日?|月)?|"
            + "(?:january|february|march|april|may|june|july|august|september|october|november|december) \\d{4})");
    private static final Pattern NUMBER_TAIL = Pattern.compile("(?:(?:no\\.?|number|编号|单号)\\s*[:：#]?\\s*)?[a-z]{1,12}[-/]?\\d[a-z0-9./-]{0,40}");
    private static final Pattern TAX_TITLE = title("(?:[\\p{IsHan}]{2,8})?增值税(?:专用|普通|电子普通|电子专用)发票|"
            + "(?:全电|电子)(?:普通|专用)?发票|(?:vat|tax) invoice");
    private static final Pattern COMMERCIAL_TITLE = title("commercial invoice|商业发票");
    private static final Pattern PROFORMA_TITLE = title("pro[ -]?forma invoice|形式发票");
    private static final Pattern QUOTE_TITLE = title("(?:客户|销售|产品)?报价单(?: quotation)?|报价|price quotation|sales quotation|quotation|quote");
    private static final Pattern ORDER_TITLE = title("客户订单|订货单|销售订单(?: sales order)?|sales order|purchase order|order confirmation");
    private static final Pattern PURCHASE_TITLE = title("采购(?:订单|订货单|单)(?: purchase order)?");
    private static final Pattern HR_TITLE = title("(?:员工|月度|年度)?工资(?:表|单|明细表|明细)|薪酬(?:表|明细表)|"
            + "员工档案|入职登记(?:表)?|离职申请(?:表)?|(?:monthly )?payroll(?: report| summary)?|payslip|employee (?:record|registration)");
    private static final Pattern WAREHOUSE_TITLE = title("库存盘点(?:表)?|盘点表|入库单|出库单|inventory count(?: sheet)?");
    private static final Pattern PRODUCTION_TITLE = title("生产任务单|生产日报|工序日报|生产计划(?:单)?");
    private static final Pattern CONTRACT_TITLE = title("(?:销售|采购|劳动|服务)?合同|(?:sales |purchase |employment )?(?:contract|agreement)");
    private static final List<Pattern> TITLES = List.of(PURCHASE_TITLE, HR_TITLE, WAREHOUSE_TITLE, PRODUCTION_TITLE,
            CONTRACT_TITLE, TAX_TITLE, COMMERCIAL_TITLE, PROFORMA_TITLE, QUOTE_TITLE, ORDER_TITLE);
    private static final Pattern INVOICE_NUMBER = field("发\\s*票\\s*(?:号\\s*码|号)|invoice\\s*(?:no\\.?|number|#)");
    private static final Pattern INVOICE_TOTAL = field("价\\s*税\\s*合\\s*计|grand total");
    private static final Pattern QUOTE_DATE = field("报价日期|quotation date|quote date");
    private static final Pattern GOODS = words("品名", "产品名称", "货品名称", "商品名称", "产品编号", "货品编码", "物料编码", "型号", "描述",
            "item", "item no", "item code", "product", "product code", "product name", "description", "model");
    private static final Pattern QUANTITY = words("数量", "订购数量", "订货数量", "qty", "quantity", "order qty");
    private static final Pattern PRICE = words("单价", "价格", "含税单价", "不含税单价", "price", "unit price");
    private static final Pattern PERSON = words("工号", "员工编号", "员工姓名", "姓名", "employee", "employee id", "employee name", "staff name");
    private static final Pattern PAY = words("工资", "工资金额", "基本工资", "应发工资", "实发工资", "应发", "实发", "薪资", "薪酬", "salary", "gross pay", "net pay", "wages");

    private AiDocumentClassifier() {}

    static Classification classify(List<String> rawLines) {
        List<String> lines = lines(rawLines);
        EnumSet<Family> families = EnumSet.noneOf(Family.class);
        boolean quotation = false, order = false, commercial = false;
        boolean number = false, total = false, domesticInvoiceField = false, quoteDate = false;
        for (String line : lines) {
            if (note(line)) continue;
            // Specific procurement titles are evaluated independently from the generic sales title.
            // "采购订货单" is one title, not an occurrence of a second "订货单" document.
            if (heading(line, PURCHASE_TITLE)) families.add(Family.PURCHASE);
            if (heading(line, HR_TITLE) || (headerLine(line) && matches(line, PERSON) && matches(line, PAY))) families.add(Family.HR);
            if (heading(line, WAREHOUSE_TITLE)) families.add(Family.WAREHOUSE);
            if (heading(line, PRODUCTION_TITLE)) families.add(Family.PRODUCTION);
            if (heading(line, CONTRACT_TITLE)) families.add(Family.CONTRACT);
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
        // Number/total fields can identify an otherwise untitled invoice. They cannot overrule a
        // quotation, warehouse slip, or other explicit document title merely referencing an invoice.
        if (families.isEmpty() && number && total) {
            if (domesticInvoiceField) families.add(Family.TAX_INVOICE);
            else { families.add(Family.TRADE); commercial = true; }
        }
        if (families.size() > 1) return result("MIXED_DOCUMENT");
        if (families.contains(Family.TAX_INVOICE)) return new Classification("INVOICE", InvoiceMultiplicity.multiple(invoiceLines(lines)));
        if (families.contains(Family.HR)) return result("HR_DOCUMENT");
        if (families.contains(Family.WAREHOUSE)) return result("WAREHOUSE_DOCUMENT");
        if (families.contains(Family.PRODUCTION)) return result("PRODUCTION_DOCUMENT");
        if (families.contains(Family.PURCHASE)) return result("PURCHASE_DOCUMENT");
        if (families.contains(Family.CONTRACT)) return result("CONTRACT");
        if (order) return result("SALES_ORDER");
        if (quotation) return result("SALES_QUOTATION");
        if (commercial) return new Classification("COMMERCIAL_INVOICE", InvoiceMultiplicity.multiple(invoiceLines(lines)));
        if (hasGoodsTable(lines)) return result(quoteDate ? "SALES_QUOTATION" : "SALES_TABLE");
        return result("UNKNOWN");
    }

    /** Sheet/page boundaries are kept; metadata in another section never supplies an invoice title. */
    static Classification classifySections(List<List<String>> sections) {
        if (sections == null || sections.isEmpty()) return result("UNKNOWN");
        Set<String> types = new java.util.LinkedHashSet<>();
        EnumSet<Family> families = EnumSet.noneOf(Family.class);
        List<String> invoiceEvidence = new ArrayList<>();
        boolean multiple = false;
        for (List<String> section : sections) {
            Classification part = classify(section);
            if (part.type().equals("MIXED_DOCUMENT")) return part;
            Family family = family(part.type());
            if (family == null) continue;
            types.add(part.type()); families.add(family); multiple |= part.multipleInvoices();
            if (part.type().equals("INVOICE") || part.type().equals("COMMERCIAL_INVOICE"))
                invoiceEvidence.addAll(invoiceLines(lines(section)));
        }
        if (families.size() > 1) return result("MIXED_DOCUMENT");
        if (types.isEmpty()) return result("UNKNOWN");
        multiple |= InvoiceMultiplicity.multiple(invoiceEvidence);
        String type;
        if (types.contains("SALES_ORDER")) type = "SALES_ORDER";
        else if (types.contains("SALES_QUOTATION")) type = "SALES_QUOTATION";
        else if (types.contains("COMMERCIAL_INVOICE")) type = "COMMERCIAL_INVOICE";
        else if (types.contains("SALES_TABLE")) type = "SALES_TABLE";
        else type = types.iterator().next();
        return new Classification(type, multiple);
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
            case "INVOICE" -> Family.TAX_INVOICE; case "HR_DOCUMENT" -> Family.HR;
            case "WAREHOUSE_DOCUMENT" -> Family.WAREHOUSE; case "PRODUCTION_DOCUMENT" -> Family.PRODUCTION;
            case "PURCHASE_DOCUMENT" -> Family.PURCHASE; case "CONTRACT" -> Family.CONTRACT; default -> null;
        };
    }
    private static Classification result(String type) { return new Classification(type, false); }
}
