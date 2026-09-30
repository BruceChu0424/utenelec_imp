package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.CellKind;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.files.document.PromptTable;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 表头规则抽取与发给 AI 前的信息最小化(SPEC §5.2 第 4 步)。纯函数。
 *
 * <p>只看明细表<b>上方</b>的行抽买方信息, 并排除卖方(我司)区块: 含 UTEN/优腾 的单元格、「Seller/卖方」标签下的单元格,
 * 以及紧跟在我司名称下方的抬头行。付款方式与贸易条款可以从任何非银行行里取。
 * 发给 AI 的表头文本先去掉银行/账号行与卖方单元格, 邮箱/电话/税号换成占位符(服务端再换回), 从不包含单价金额。
 */
final class IntakeHeaderRules {

    static final Pattern BANK_ROW = Pattern.compile(
            "(?i)bank|account|a/c|acct|iban|swift|routing|beneficiary|sort\\s*code"
                    + "|(?<![a-z])acc(?:ount)?\\.?\\s*(?:no|number|#)(?![a-z])|(?<![a-z])bic(?![a-z])"
                    + "|银行|账号|帐号|开户|收款行|收款人");
    /** 银行信息块: 银行关键字行之后, 紧接着的这么多行(不像货品行、也不是新段落标题)一并视为银行信息。 */
    static final int BANK_BLOCK_MAX_LINES = 6;
    /** 发给 AI 时代替我司名称的占位符前缀(⟨SELLER_1⟩), 服务端再换回。 */
    static final String SELLER_PLACEHOLDER = "SELLER";
    static final Pattern SELLER_NAME = Pattern.compile("(?i)(?<![A-Z])UTEN(?![A-Z])|优腾|ZHONGSHAN\\s+SHI\\s+UTEN");
    private static final Pattern SELLER_LABEL = Pattern.compile(
            "(?i)^\\s*(seller|supplier|vendor|exporter|shipper|beneficiary|卖方|供应商|供方|出口商)\\s*[:：]?\\s*$");
    private static final Pattern SELLER_LABEL_INLINE = Pattern.compile(
            "(?i)^\\s*(seller|supplier|vendor|exporter|shipper|卖方|供应商|供方)\\s*[:：]");
    private static final Pattern BUYER_INLINE = Pattern.compile(
            "(?i)^\\s*(?:the\\s+)?(buyer|messrs\\.?|customer|consignee|sold\\s*to|bill\\s*to|importer|to|买方|客户|收货人|购货方)"
                    + "\\s*(?:name)?\\s*[:：]\\s*(.+)$");
    private static final Pattern BUYER_LABEL = Pattern.compile(
            "(?i)^\\s*(?:the\\s+)?(buyer|messrs\\.?|customer|consignee|sold\\s*to|bill\\s*to|importer|to|买方|客户|收货人|购货方)"
                    + "\\s*(?:name)?\\s*[:：]?\\s*$");
    private static final Pattern CONTACT = Pattern.compile(
            "(?i)^\\s*(attn|attention|contact\\s*person|contact|联系人)\\.?\\s*[:：]?\\s*(.+)$");
    private static final Pattern ADDRESS = Pattern.compile("(?i)^\\s*(address|addr|add|地址)\\.?\\s*[:：]\\s*(.+)$");
    private static final Pattern TAX = Pattern.compile(
            "(?i)(?<![A-Z])(tax\\s*(?:no\\.?|number|id|code)?|vat\\s*(?:no\\.?|number)?|tin|trn|税号|纳税人识别号)"
                    + "\\s*[:：#]?\\s*(?=[A-Z0-9-]*\\d)([A-Z0-9][A-Z0-9-]{4,})");
    private static final Pattern REGISTRATION = Pattern.compile(
            "(?i)(?<![A-Z])(registration\\s*(?:no\\.?|number)?|reg\\.?\\s*no\\.?|注册号)\\s*[:：#]?\\s*(?=[A-Z0-9-]*\\d)"
                    + "([A-Z0-9][A-Z0-9-]{4,})");
    private static final Pattern DATE_LABEL = Pattern.compile("(?i)(?:^|\\s)(date|dated|日期)\\s*[:：]?\\s*(.*)$");
    private static final Pattern DOC_NO = Pattern.compile(
            "(?i)(?:pro[- ]?forma|profoma|proforma|commercial)?\\s*(?:invoice|pi|p\\.i\\.|quotation|quote|order|contract|p\\.?o\\.?)"
                    + "\\s*(?:no\\.?|number|#|n°)\\s*[:：]?\\s*#?\\s*([A-Z0-9][A-Z0-9/\\-]{1,30})");
    private static final Pattern DOC_NO_HASH = Pattern.compile("(?i)(?:invoice|quotation|pi|order|contract)\\s*#\\s*([A-Z0-9][A-Z0-9/\\-]{1,30})");
    private static final Pattern DOC_NO_CN = Pattern.compile("(合同号|订单号|单号|发票号|报价单号)\\s*[:：]?\\s*([A-Za-z0-9][A-Za-z0-9/\\-]{1,30})");
    private static final Pattern EMAIL = Pattern.compile("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}");
    private static final Pattern WEBSITE = Pattern.compile(
            "(?i)(?:website|web\\s*site|网址|网站)\\s*[:：]\\s*((?:https?://|www\\.)[^\\s<>]+)");
    /**
     * 电话标签: 英文词前后不紧挨字母(「Total」「Photo」不算), 单字母「T」必须带「.」或「:」; 中文标签不限位置。
     * 「Phone No.:」这类带编号字样的也吃掉, 让号码紧跟在标签后面。
     */
    private static final Pattern PHONE_LABEL = Pattern.compile(
            "(?i)(?:(?<!\\p{L})(?:telephone|tel|ph|phone|mobile|mob|cell|cellphone|fax|whatsapp|wechat|viber|contact)(?!\\p{L})"
                    + "\\.?(?:\\s*(?:no\\.?|number|#))?|(?<!\\p{L})t(?=\\s*[.:：])\\.?|电话|手机|传真|联系电话|联系人|联系)"
                    + "\\s*[:：]?\\s*");
    /** 整格只是电话标签(号码在右边一格)。 */
    private static final Pattern PHONE_LABEL_CELL = Pattern.compile(
            "(?i)^\\s*(?:telephone|tel|t|ph|phone|mobile|mob|cell|cellphone|fax|whatsapp|wechat|viber|contact)"
                    + "\\.?(?:\\s*(?:no\\.?|number|#))?\\s*[:：]?\\s*$|^\\s*(?:电话|手机|传真|联系电话|联系人|联系)\\s*[:：]?\\s*$");
    /** 整格只是税号/注册号标签(号码在右边一格)。 */
    private static final Pattern TAX_LABEL_CELL = Pattern.compile(
            "(?i)^\\s*(?:tax\\s*(?:no\\.?|number|id|code)?|vat\\s*(?:no\\.?|number)?|tin|trn|税号|纳税人识别号"
                    + "|registration\\s*(?:no\\.?|number)?|reg\\.?\\s*no\\.?|注册号)\\s*[:：#]?\\s*$");
    private static final Pattern PHONE_NUMBER = Pattern.compile("\\+?\\d[\\d\\s\\-().]{5,}\\d");
    private static final Pattern DATE_LIKE = Pattern.compile("^\\s*(\\d{4}[-/.]\\d{1,2}[-/.]\\d{1,2}|\\d{1,2}[-/.]\\d{1,2}[-/.]\\d{2,4})\\s*$");
    private static final Pattern INCOTERM = Pattern.compile("(?i)(?<![A-Z])(EXW|FOB|CIF|CFR|CNF|C&F|DDP|DAP|DDU|FCA|CPT|CIP|EX[- ]?WORKS?)(?![A-Z])");
    private static final Pattern PORT_AFTER_TERM = Pattern.compile("(?i)(?<![A-Z])(?:FOB|CIF|CFR|CNF)\\s+([A-Z][A-Za-z]+(?:\\s+[A-Z][A-Za-z]+){0,2})");
    private static final Pattern PORT_LABEL = Pattern.compile("(?i)port\\s+of\\s+(?:loading|shipment|discharge|destination)\\s*[:：]\\s*(.+)$");
    private static final Pattern PAYMENT = Pattern.compile("(?i)(?:payment\\s*(?:terms?)?|付款方式|付款条件|付款)\\s*[:：]\\s*(.+)$");
    private static final Pattern PAYMENT_TERMS_WORDS = Pattern.compile("(?i)(?<![A-Z])(T/T|TT|L/C|D/P|D/A|western union|paypal)(?![A-Z])");
    private static final Pattern LEADING_NUMBERING = Pattern.compile("^\\s*\\d{1,2}\\s*[.)、]\\s*");
    /** 独立的数字(不是型号里的数字): 前后不紧挨字母、数字、连字符或斜杠。 */
    private static final Pattern STANDALONE_NUMBER = Pattern.compile(
            "(?<![\\p{L}\\d.,\\-/])\\d[\\d,]*(\\.\\d+)?(?![\\p{L}\\d\\-/])");
    private static final Pattern HAS_LETTER = Pattern.compile("\\p{L}");
    private static final Pattern TABLE_QTY_WORD = Pattern.compile("(?i)(?<![a-z])(qty|quantity|q'ty|pcs)(?![a-z])|数量");
    private static final Pattern TABLE_OTHER_WORD = Pattern.compile(
            "(?i)(?<![a-z])(price|amount|description|model|item|part)(?![a-z])|单价|金额|品名|型号|货号|描述");
    /** 新段落的开头(结束银行信息块): 合计、备注、付款、交货、包装等, 前面可以有「1.」这样的编号。 */
    private static final Pattern SECTION_START = Pattern.compile(
            "(?i)^\\s*(?:\\d{1,2}\\s*[.)、]\\s*)?(?:total|sub\\s*total|grand\\s*total|remarks?|notes?|payment|delivery"
                    + "|lead\\s*time|packing|package|shipment|port|validity|terms?|price|item|description|qty|quantity"
                    + "|合计|总计|备注|说明|付款|交货|交期|包装|装运)(?![a-z])");

    private IntakeHeaderRules() {
    }

    // ------------------------------------------------------------------ seller exclusion

    /** 卖方(我司)单元格坐标集合「行:列」(行列从 0 开始)。 */
    static Set<String> sellerCells(Sheet sheet, int headerRow0) {
        Set<String> out = new HashSet<>();
        for (Row row : sheet.rows()) {
            if (row.index0() >= headerRow0) {
                break;
            }
            for (Cell cell : row.cells()) {
                String text = cell.text();
                if (SELLER_NAME.matcher(IntakeTextNormalizer.nfkc(text)).find()) {
                    out.add(key(row.index0(), cell.col0()));
                    // 我司名称下方同列的抬头行(地址、电话), 直到空行或下一个标签。
                    for (int r = row.index0() + 1; r < Math.min(headerRow0, row.index0() + 5); r++) {
                        String below = sheet.text(r, cell.col0());
                        if (below.isBlank() || isLabel(below)) {
                            break;
                        }
                        out.add(key(r, cell.col0()));
                    }
                }
                if (SELLER_LABEL.matcher(text).matches() || SELLER_LABEL_INLINE.matcher(text).find()) {
                    int labelCol = cell.col0();
                    int endCol = nextLabelColumn(row, labelCol);
                    out.add(key(row.index0(), labelCol));
                    for (int r = row.index0() + 1; r < Math.min(headerRow0, row.index0() + 7); r++) {
                        Row below = sheet.row(r);
                        if (below == null) {
                            continue;
                        }
                        for (Cell c : below.cells()) {
                            if (c.col0() >= labelCol && c.col0() < endCol && !DATE_LABEL.matcher(c.text()).find()) {
                                out.add(key(r, c.col0()));
                            }
                        }
                    }
                }
            }
        }
        return out;
    }

    private static int nextLabelColumn(Row row, int labelCol) {
        for (Cell c : row.cells()) {
            if (c.col0() > labelCol && (BUYER_LABEL.matcher(c.text()).matches() || BUYER_INLINE.matcher(c.text()).find())) {
                return c.col0();
            }
        }
        return Integer.MAX_VALUE;
    }

    private static boolean isLabel(String text) {
        return BUYER_LABEL.matcher(text).matches() || BUYER_INLINE.matcher(text).find()
                || SELLER_LABEL.matcher(text).matches() || DATE_LABEL.matcher(text).find()
                || DOC_NO.matcher(text).find() || DOC_NO_HASH.matcher(text).find();
    }

    static String key(int row0, int col0) {
        return row0 + ":" + col0;
    }

    // ------------------------------------------------------------------ rules

    /**
     * 规则抽取。
     *
     * @param sheet      工作表
     * @param headerRow0 明细表表头行(买方信息只在它上方找)
     */
    static IntakeHeader extract(Sheet sheet, int headerRow0) {
        IntakeHeader h = new IntakeHeader();
        Set<String> seller = sellerCells(sheet, headerRow0);
        StringBuilder buyerContext = new StringBuilder();
        boolean taxFromTaxLabel = false;
        for (Row row : sheet.rows()) {
            if (row.index0() >= headerRow0) {
                break;
            }
            for (Cell cell : row.cells()) {
                String text = cell.text();
                boolean isSeller = seller.contains(key(row.index0(), cell.col0()));
                String firstLine = firstLine(text);
                if (!isSeller) {
                    Matcher website = WEBSITE.matcher(text);
                    if (h.website == null && website.find()) {
                        String value = website.group(1).replaceAll("[.,;，；]+$", "");
                        if (value.length() <= 200) h.website = value.startsWith("www.") ? "https://" + value : value;
                    }
                    if (h.buyerName == null) {
                        Matcher inline = BUYER_INLINE.matcher(firstLine);
                        if (inline.find()) {
                            h.buyerName = cleanValue(inline.group(2));
                        } else if (BUYER_LABEL.matcher(firstLine).matches()) {
                            h.buyerName = valueNear(sheet, row.index0(), cell.col0(), headerRow0, seller);
                        }
                        if (h.buyerName != null) {
                            buyerContext.append(h.buyerName).append('\n');
                        }
                    }
                    Matcher contact = CONTACT.matcher(firstLine);
                    if (h.contactName == null && contact.find()) {
                        h.contactName = cleanValue(contact.group(2));
                    }
                    Matcher address = ADDRESS.matcher(text.replace('\n', ' '));
                    if (h.buyerAddress == null && address.find()) {
                        h.buyerAddress = cleanValue(address.group(2));
                        buyerContext.append(h.buyerAddress).append('\n');
                    }
                    Matcher tax = TAX.matcher(IntakeTextNormalizer.nfkc(text));
                    if (!taxFromTaxLabel && tax.find()) {
                        h.taxId = tax.group(2);
                        taxFromTaxLabel = true;
                    } else if (h.taxId == null) {
                        Matcher reg = REGISTRATION.matcher(IntakeTextNormalizer.nfkc(text));
                        if (reg.find()) {
                            h.taxId = reg.group(2);
                        }
                    }
                    Matcher email = EMAIL.matcher(text);
                    while (email.find()) {
                        String e = email.group();
                        if (!SELLER_NAME.matcher(e).find()) {
                            h.addEmail(e);
                        }
                    }
                    extractPhones(text, h);
                }
                if (h.docNo == null) {
                    h.docNo = docNo(text);
                }
                if (h.docDate == null) {
                    Matcher date = DATE_LABEL.matcher(firstLine);
                    if (date.find()) {
                        String value = date.group(2).isBlank()
                                ? nextCellText(sheet, row.index0(), cell.col0()) : date.group(2);
                        h.docDate = parseDate(value);
                    } else if (cell.kind() == CellKind.DATE && h.docDate == null && isDateLabelLeft(row, cell)) {
                        h.docDate = cell.text().length() >= 10 ? cell.text().substring(0, 10) : cell.text();
                    }
                }
            }
        }
        termsAndPayment(sheet, h);
        String country = IntakeCountries.detect(buyerContext.toString());
        if (country == null) {
            country = IntakeCountries.detect(aboveTableBuyerText(sheet, headerRow0, seller));
        }
        h.country = country;
        return h;
    }

    private static boolean isDateLabelLeft(Row row, Cell cell) {
        for (Cell c : row.cells()) {
            if (c.col0() < cell.col0() && DATE_LABEL.matcher(c.text()).find()) {
                return true;
            }
        }
        return false;
    }

    private static String aboveTableBuyerText(Sheet sheet, int headerRow0, Set<String> seller) {
        StringBuilder sb = new StringBuilder();
        for (Row row : sheet.rows()) {
            if (row.index0() >= headerRow0) {
                break;
            }
            if (BANK_ROW.matcher(row.joinedText()).find()) {
                continue;
            }
            for (Cell c : row.cells()) {
                if (!seller.contains(key(row.index0(), c.col0()))) {
                    sb.append(c.text()).append('\n');
                }
            }
        }
        return sb.toString();
    }

    private static void extractPhones(String text, IntakeHeader h) {
        Matcher label = PHONE_LABEL.matcher(text);
        while (label.find()) {
            String rest = text.substring(label.end());
            Matcher number = PHONE_NUMBER.matcher(rest);
            if (number.lookingAt() || (number.find() && number.start() < 3)) {
                String candidate = number.group().strip();
                if (candidate.replaceAll("\\D", "").length() >= 7) {
                    h.addPhone(candidate);
                }
            }
        }
    }

    private static String valueNear(Sheet sheet, int row0, int col0, int headerRow0, Set<String> seller) {
        for (int r = row0 + 1; r <= Math.min(headerRow0 - 1, row0 + 2); r++) {
            String below = sheet.text(r, col0);
            if (!below.isBlank() && !seller.contains(key(r, col0)) && !isLabel(below)) {
                return cleanValue(firstLine(below));
            }
        }
        Row row = sheet.row(row0);
        if (row != null) {
            for (Cell c : row.cells()) {
                if (c.col0() > col0 && c.col0() <= col0 + 3 && !seller.contains(key(row0, c.col0())) && !isLabel(c.text())) {
                    return cleanValue(firstLine(c.text()));
                }
            }
        }
        return null;
    }

    private static String nextCellText(Sheet sheet, int row0, int col0) {
        Row row = sheet.row(row0);
        if (row == null) {
            return "";
        }
        for (Cell c : row.cells()) {
            if (c.col0() > col0) {
                return c.text();
            }
        }
        return "";
    }

    static String docNo(String text) {
        String t = IntakeTextNormalizer.nfkc(text);
        for (Pattern p : List.of(DOC_NO_HASH, DOC_NO)) {
            Matcher m = p.matcher(t);
            if (m.find()) {
                String v = m.group(1);
                if (v.chars().anyMatch(Character::isDigit)) {
                    return v;
                }
            }
        }
        Matcher cn = DOC_NO_CN.matcher(t);
        if (cn.find()) {
            return cn.group(2);
        }
        return null;
    }

    /** 贸易条款、港口、付款方式: 任何非银行行都可以。 */
    private static void termsAndPayment(Sheet sheet, IntakeHeader h) {
        for (Row row : sheet.rows()) {
            String joined = row.joinedText();
            if (joined.isBlank() || BANK_ROW.matcher(joined).find()) {
                continue;
            }
            for (Cell cell : row.cells()) {
                for (String line : cell.text().split("\n")) {
                    String l = IntakeTextNormalizer.nfkc(line).strip();
                    if (l.isEmpty() || BANK_ROW.matcher(l).find()) {
                        continue;
                    }
                    if (h.incoterm == null) {
                        Matcher m = INCOTERM.matcher(l);
                        if (m.find()) {
                            String term = m.group(1).toUpperCase(Locale.ROOT);
                            h.incoterm = term.startsWith("EX") && !term.equals("EXW") ? "EXW"
                                    : term.equals("CNF") || term.equals("C&F") ? "CFR" : term;
                        }
                    }
                    if (h.port == null) {
                        Matcher p = PORT_LABEL.matcher(l);
                        if (p.find()) {
                            h.port = cleanValue(p.group(1));
                        } else {
                            Matcher q = PORT_AFTER_TERM.matcher(l);
                            if (q.find() && !q.group(1).equalsIgnoreCase("price")) {
                                h.port = cleanValue(q.group(1));
                            }
                        }
                    }
                    if (h.paymentTerms == null) {
                        Matcher p = PAYMENT.matcher(LEADING_NUMBERING.matcher(l).replaceFirst(""));
                        if (p.find() && PAYMENT_TERMS_WORDS.matcher(p.group(1)).find()) {
                            h.paymentTerms = cleanValue(p.group(1));
                        } else if (PAYMENT_TERMS_WORDS.matcher(l).find() && l.contains("%")) {
                            h.paymentTerms = cleanValue(LEADING_NUMBERING.matcher(l).replaceFirst(""));
                        }
                    }
                }
            }
        }
    }

    private static final List<DateTimeFormatter> DATE_FORMATS = List.of(
            DateTimeFormatter.ofPattern("uuuu-M-d"), DateTimeFormatter.ofPattern("uuuu/M/d"),
            DateTimeFormatter.ofPattern("uuuu.M.d"), DateTimeFormatter.ofPattern("d-MMM-uuuu", Locale.ENGLISH),
            DateTimeFormatter.ofPattern("d MMM uuuu", Locale.ENGLISH), DateTimeFormatter.ofPattern("MMM d, uuuu", Locale.ENGLISH),
            DateTimeFormatter.ofPattern("MMMM d, uuuu", Locale.ENGLISH), DateTimeFormatter.ofPattern("d MMMM uuuu", Locale.ENGLISH),
            DateTimeFormatter.ofPattern("uuuu年M月d日"), DateTimeFormatter.ofPattern("d/M/uuuu"), DateTimeFormatter.ofPattern("d.M.uuuu"));

    /** 常见日期写法 → ISO(yyyy-MM-dd); 认不出返回 null。「d/M/yyyy」按日/月/年(外贸文件多为欧式)。 */
    static String parseDate(String value) {
        if (value == null) {
            return null;
        }
        String v = IntakeTextNormalizer.nfkc(value).strip();
        Matcher iso = Pattern.compile("(\\d{4})[-/.年](\\d{1,2})[-/.月](\\d{1,2})").matcher(v);
        if (iso.find()) {
            try {
                return LocalDate.of(Integer.parseInt(iso.group(1)), Integer.parseInt(iso.group(2)),
                        Integer.parseInt(iso.group(3))).toString();
            } catch (RuntimeException ignored) {
                return null;
            }
        }
        String cleaned = v.replaceAll("(?i)(\\d)(st|nd|rd|th)", "$1").replaceAll("\\s+", " ");
        for (DateTimeFormatter f : DATE_FORMATS) {
            try {
                String candidate = cleaned.length() > 24 ? cleaned.substring(0, 24) : cleaned;
                return LocalDate.parse(capitalizeMonth(candidate), f).toString();
            } catch (DateTimeParseException ignored) {
                // 试下一种写法
            }
        }
        return null;
    }

    private static String capitalizeMonth(String s) {
        Matcher m = Pattern.compile("[A-Za-z]+").matcher(s);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            String w = m.group();
            m.appendReplacement(sb, w.substring(0, 1).toUpperCase(Locale.ROOT) + w.substring(1).toLowerCase(Locale.ROOT));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    static String firstLine(String text) {
        if (text == null) {
            return "";
        }
        int nl = text.indexOf('\n');
        return (nl < 0 ? text : text.substring(0, nl)).strip();
    }

    static String cleanValue(String value) {
        if (value == null) {
            return null;
        }
        String v = IntakeTextNormalizer.nfkc(value).replaceAll("\\s+", " ").strip();
        v = v.replaceAll("[\\s,;:.]+$", "").strip();
        if (v.length() > 200) {
            v = v.substring(0, 200);
        }
        return v.isEmpty() ? null : v;
    }

    // ------------------------------------------------------------------ minimization

    /** 发给 AI 的表头文本与占位符映射(占位符 → 原文)。 */
    record MinimizedHeader(String text, Map<String, String> placeholders) {
    }

    /**
     * 表头最小化: 只取表头行上方, 去掉银行信息(关键字行及紧跟的银行信息行)、卖方单元格;
     * 邮箱/电话/税号换成 ⟨EMAIL_1⟩ ⟨PHONE_1⟩ ⟨TAXID_1⟩。
     * 数字单元格(可能是金额)一律不发。
     */
    static MinimizedHeader minimize(Sheet sheet, int headerRow0, int maxChars) {
        Set<String> seller = sellerCells(sheet, headerRow0);
        Map<String, String> placeholders = new LinkedHashMap<>();
        List<Row> kept = new ArrayList<>();
        BankBlock bank = new BankBlock();
        for (Row row : sheet.rows()) {
            if (row.index0() >= headerRow0) {
                break;
            }
            if (bank.drop(IntakeTextNormalizer.nfkc(row.joinedText()), row.index0(), goodsLikeRow(row))) {
                continue;
            }
            List<Cell> cells = new ArrayList<>();
            for (Cell c : row.cells()) {
                if (seller.contains(key(row.index0(), c.col0())) || c.kind() == CellKind.NUMBER) {
                    continue;
                }
                String masked = maskPii(c.text(), placeholders, true);
                if (!masked.isBlank()) {
                    cells.add(Cell.text(c.col0(), masked));
                }
            }
            if (!cells.isEmpty()) {
                kept.add(new Row(row.index0(), cells));
            }
        }
        StringBuilder sb = new StringBuilder();
        for (Row r : kept) {
            String line = PromptTable.renderRow(r);
            if (line == null) {
                continue;
            }
            if (sb.length() + line.length() + 1 > maxChars) {
                sb.append(PromptTable.TRUNCATION_MARKER);
                break;
            }
            sb.append(line).append('\n');
        }
        return new MinimizedHeader(sb.toString().stripTrailing(), placeholders);
    }

    /** 表头区域: 邮箱、电话、税号全部换成占位符(同一原文同一占位符)。 */
    static String maskPii(String text, Map<String, String> placeholders) {
        return maskPii(text, placeholders, true);
    }

    /**
     * 邮箱、税号一律换成占位符; 电话在 {@code aggressive} 时凡 7 位以上数字串(不像日期)都换, 否则只换带电话标签、
     * 以 + 开头或用 - 连接且没有小数点的号码(PDF 明细行里的「数量 单价 金额」不能被当成电话抹掉)。
     */
    static String maskPii(String text, Map<String, String> placeholders, boolean aggressive) {
        String out = replaceAll(EMAIL, text, "EMAIL", placeholders);
        for (Pattern taxPattern : List.of(TAX, REGISTRATION)) {
            Matcher tax = taxPattern.matcher(out);
            StringBuilder masked = new StringBuilder();
            while (tax.find()) {
                String ph = placeholder("TAXID", tax.group(2), placeholders);
                tax.appendReplacement(masked, Matcher.quoteReplacement(tax.group(1) + " " + ph));
            }
            tax.appendTail(masked);
            out = masked.toString();
        }
        Matcher phone = PHONE_NUMBER.matcher(out);
        StringBuilder sb = new StringBuilder();
        while (phone.find()) {
            String candidate = phone.group();
            boolean looksLikePhone = candidate.replaceAll("\\D", "").length() >= 7 && !DATE_LIKE.matcher(candidate).matches();
            if (looksLikePhone && !aggressive) {
                String before = out.substring(Math.max(0, phone.start() - 14), phone.start());
                boolean labelled = PHONE_LABEL.matcher(before).find();
                boolean formatted = candidate.strip().startsWith("+")
                        || (candidate.contains("-") && !candidate.contains("."));
                looksLikePhone = labelled || formatted;
            }
            if (looksLikePhone) {
                phone.appendReplacement(sb, Matcher.quoteReplacement(placeholder("PHONE", candidate.strip(), placeholders)));
            } else {
                phone.appendReplacement(sb, Matcher.quoteReplacement(candidate));
            }
        }
        phone.appendTail(sb);
        return sb.toString();
    }

    private static String replaceAll(Pattern p, String text, String kind, Map<String, String> placeholders) {
        Matcher m = p.matcher(text);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            m.appendReplacement(sb, Matcher.quoteReplacement(placeholder(kind, m.group(), placeholders)));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    private static String placeholder(String kind, String original, Map<String, String> placeholders) {
        for (Map.Entry<String, String> e : placeholders.entrySet()) {
            if (e.getValue().equals(original) && e.getKey().startsWith("⟨" + kind + "_")) {
                return e.getKey();
            }
        }
        long n = placeholders.keySet().stream().filter(k -> k.startsWith("⟨" + kind + "_")).count() + 1;
        String ph = "⟨" + kind + "_" + n + "⟩";
        placeholders.put(ph, original);
        return ph;
    }

    /** AI 返回值里的占位符换回原文。 */
    static String unmask(String value, Map<String, String> placeholders) {
        if (value == null) {
            return null;
        }
        String out = value;
        for (Map.Entry<String, String> e : placeholders.entrySet()) {
            out = out.replace(e.getKey(), e.getValue());
        }
        return out;
    }

    /**
     * 认列用的表格片段: 去掉银行信息(银行关键字行及紧跟的银行信息行); 我司名称在第一行货品/表头之前(抬头区)时整行去掉,
     * 之后(如货品描述里写「UTEN logo」)只把我司名称换成占位符; 文字格里的邮箱/电话/税号换成占位符(不还原, 认列用不到)。
     * 抬头区(买方、联系人一带)按表头同口径从严: 7 位以上数字串都当电话, 7 位以上的整数数字格也换成占位符;
     * 任何一行里左边一格只是「Tel:」「VAT No.」这类标签时, 右边的号码一律换成占位符。
     * 表头之后的单价、数量等数字保留(认列需要看到数据的样子)。
     */
    static Sheet sanitizeForColumnPrompt(Sheet sheet, int fromRow0, int toRow0) {
        Map<String, String> placeholders = new LinkedHashMap<>();
        List<Row> kept = new ArrayList<>();
        BankBlock bank = new BankBlock();
        boolean letterhead = true;
        for (Row row : sheet.rows()) {
            if (row.index0() < fromRow0 || row.index0() > toRow0) {
                continue;
            }
            String joined = IntakeTextNormalizer.nfkc(row.joinedText());
            boolean goods = goodsLikeRow(row);
            if (goods || tableHeaderText(joined)) {
                letterhead = false;
            }
            if (bank.drop(joined, row.index0(), goods)) {
                continue;
            }
            boolean seller = SELLER_NAME.matcher(joined).find();
            if (seller && letterhead) {
                continue;
            }
            List<Cell> cells = new ArrayList<>();
            Cell left = null;
            for (Cell c : row.cells()) {
                // 货品行里「T」「Tin」之类的格可能是尺码/材质, 不当标签; 只在联系方式这类非货品行里认。
                String labelKind = goods || left == null || left.kind() != CellKind.TEXT
                        ? null : labelledValueKind(left.text());
                left = c;
                if (labelKind != null && (labelKind.equals("TAXID") || digitCount(c.text()) >= 7)) {
                    cells.add(Cell.text(c.col0(), placeholder(labelKind, c.text().strip(), placeholders)));
                } else if (c.kind() == CellKind.TEXT) {
                    String text = seller ? maskSeller(c.text(), placeholders) : c.text();
                    String masked = maskPii(text, placeholders, letterhead);
                    if (!masked.isBlank()) {
                        cells.add(Cell.text(c.col0(), masked));
                    }
                } else if (letterhead && c.kind() == CellKind.NUMBER && longWholeNumber(c)) {
                    cells.add(Cell.text(c.col0(), placeholder("PHONE", c.text(), placeholders)));
                } else {
                    cells.add(c);
                }
            }
            if (!cells.isEmpty()) {
                kept.add(new Row(row.index0(), cells));
            }
        }
        return new Sheet(sheet.name(), sheet.index(), kept, sheet.merges(), 0, sheet.maxColumn(), false);
    }

    /** 左边一格只是电话/税号标签时, 右边那格该换成哪种占位符; 不是标签返回 null。 */
    private static String labelledValueKind(String leftText) {
        String t = IntakeTextNormalizer.nfkc(leftText == null ? "" : leftText);
        if (TAX_LABEL_CELL.matcher(t).matches()) {
            return "TAXID";
        }
        return PHONE_LABEL_CELL.matcher(t).matches() ? "PHONE" : null;
    }

    private static int digitCount(String text) {
        return text == null ? 0 : (int) text.chars().filter(Character::isDigit).count();
    }

    /** 7 位以上的整数(没有小数部分): 像电话/账号, 不像单价数量。 */
    private static boolean longWholeNumber(Cell c) {
        if (c.number() == null) {
            return false;
        }
        BigDecimal n = c.number().stripTrailingZeros();
        return n.scale() <= 0 && n.abs().toBigInteger().toString().length() >= 7;
    }

    /** PDF 文字最小化(整段当作一页), 见 {@link #minimizeText(List, Set, Map)}。 */
    static String minimizeText(List<String> lines, Map<String, String> placeholders) {
        return minimizeText(lines, Set.of(0), placeholders);
    }

    /**
     * PDF 文字最小化: 去掉银行信息(银行关键字行, 以及紧跟其后、不像货品行也不是新段落的几行, 如银行名称、地址、账号);
     * 我司名称出现在每页第一行货品/表头之前(抬头区)时整行去掉, 之后(货品描述里的「UTEN logo」、页脚)只把我司名称换成
     * 占位符 ⟨SELLER_n⟩, 不丢行; 邮箱/电话/税号换成占位符(抬头区 7 位以上数字串都当电话)。占位符与原文的对应记在 {@code placeholders} 里, 服务端再换回。
     *
     * @param pageStarts 新一页第一行在 {@code lines} 里的下标(每页重新判断抬头区; 从页中间接着的一段不含 0)
     */
    static String minimizeText(List<String> lines, Set<Integer> pageStarts, Map<String, String> placeholders) {
        StringBuilder sb = new StringBuilder();
        BankBlock bank = new BankBlock();
        boolean letterhead = false;
        for (int i = 0; i < lines.size(); i++) {
            if (pageStarts.contains(i)) {
                letterhead = true;
                bank = new BankBlock();
            }
            String line = lines.get(i);
            String normalized = IntakeTextNormalizer.nfkc(line);
            boolean goods = goodsLikeText(normalized);
            if (goods || tableHeaderText(normalized)) {
                letterhead = false;
            }
            if (bank.drop(normalized, i, goods)) {
                continue;
            }
            String text = line;
            if (SELLER_NAME.matcher(normalized).find()) {
                if (letterhead) {
                    continue;
                }
                text = maskSeller(normalized, placeholders);
            }
            // 抬头区(买方、联系人一带)从严: 7 位以上数字串都当电话; 货品区只换带标签或明显格式的号码。
            sb.append(maskPii(text, placeholders, letterhead)).append('\n');
        }
        return sb.toString().stripTrailing();
    }

    /** 我司名称(UTEN/优腾/ZHONGSHAN SHI UTEN)换成 ⟨SELLER_n⟩。 */
    static String maskSeller(String text, Map<String, String> placeholders) {
        String normalized = IntakeTextNormalizer.nfkc(text);
        Matcher m = SELLER_NAME.matcher(normalized);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            m.appendReplacement(sb, Matcher.quoteReplacement(placeholder(SELLER_PLACEHOLDER, m.group(), placeholders)));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    /** 像一行货品: 有文字, 并且有 3 个以上独立数字(序号/数量/单价/金额), 或 2 个以上且其中有小数。 */
    static boolean goodsLikeText(String text) {
        if (text == null || !HAS_LETTER.matcher(text).find()) {
            return false;
        }
        Matcher m = STANDALONE_NUMBER.matcher(text);
        int count = 0;
        boolean decimal = false;
        while (m.find()) {
            count++;
            decimal |= m.group(1) != null;
        }
        return count >= 3 || (count >= 2 && decimal);
    }

    /** 表格里像一行货品: 至少两个数字格和一个有字的文字格, 或拼起来的文字像货品行。 */
    static boolean goodsLikeRow(Row row) {
        long numbers = row.cells().stream().filter(c -> c.kind() == CellKind.NUMBER).count();
        boolean text = row.cells().stream().anyMatch(c -> c.kind() == CellKind.TEXT && HAS_LETTER.matcher(c.text()).find());
        return (numbers >= 2 && text) || goodsLikeText(IntakeTextNormalizer.nfkc(row.joinedText()));
    }

    /** 像货品表的表头: 同时有「数量」类和「单价/金额/品名/型号」类字样。 */
    static boolean tableHeaderText(String text) {
        return text != null && TABLE_QTY_WORD.matcher(text).find() && TABLE_OTHER_WORD.matcher(text).find();
    }

    /**
     * 银行信息块的判断(按顺序喂入每一行): 银行关键字行丢弃并开始一个块; 块内紧跟的行(行号连续)只要不像货品行、
     * 不是表头/新段落/买方/单号/日期标签, 最多 {@link #BANK_BLOCK_MAX_LINES} 行也丢弃(如银行名称、支行地址、没写标签的账号)。
     */
    static final class BankBlock {
        private int lastIndex = Integer.MIN_VALUE;
        private int dropped = Integer.MAX_VALUE;

        boolean drop(String text, int index, boolean goodsLike) {
            if (BANK_ROW.matcher(text).find()) {
                lastIndex = index;
                dropped = 0;
                return true;
            }
            boolean continues = dropped < BANK_BLOCK_MAX_LINES && index == lastIndex + 1 && !goodsLike
                    && !text.isBlank() && !SECTION_START.matcher(text).find() && !isLabel(firstLine(text))
                    && !tableHeaderText(text);
            if (continues) {
                lastIndex = index;
                dropped++;
                return true;
            }
            dropped = Integer.MAX_VALUE;
            return false;
        }
    }

    /** PDF 文字里的买方邮箱/电话(规则, 排除我司与银行行)。 */
    static void contactsFromText(List<String> lines, IntakeHeader h) {
        for (String line : lines) {
            if (BANK_ROW.matcher(line).find() || SELLER_NAME.matcher(IntakeTextNormalizer.nfkc(line)).find()) {
                continue;
            }
            Matcher email = EMAIL.matcher(line);
            while (email.find()) {
                h.addEmail(email.group());
            }
            extractPhones(line, h);
        }
    }
}
