package com.uten.imp.features.finance.intake;

import com.uten.imp.common.files.document.DocumentGrid;
import com.uten.imp.common.files.document.PdfTextReader.DocumentText;

import java.math.BigDecimal;
import java.text.Normalizer;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Conservative fixed-label extraction: one visible transaction, never totals or inferred net proceeds. */
final class FinanceDocumentParser {
    record Result(Map<String, String> fields, Map<String, String> sources, List<String> warnings) { }
    private record Candidate(String field, String label, String raw, String location) { }
    private static final Map<String, String> COMMON = Map.ofEntries(
            Map.entry("银行流水号", "bankReference"), Map.entry("交易流水号", "bankReference"),
            Map.entry("流水号", "bankReference"), Map.entry("回单编号", "bankReference"),
            Map.entry("回单号", "bankReference"), Map.entry("bankreference", "bankReference"),
            Map.entry("transactionreference", "bankReference"),
            Map.entry("交易日期", "transactionDate"), Map.entry("记账日期", "transactionDate"),
            Map.entry("入账日期", "transactionDate"), Map.entry("到账日期", "transactionDate"),
            Map.entry("transactiondate", "transactionDate"), Map.entry("bookingdate", "transactionDate"),
            Map.entry("币种", "currencyCode"), Map.entry("交易币种", "currencyCode"), Map.entry("currency", "currencyCode"),
            Map.entry("到账币种", "currencyCode"), Map.entry("入账币种", "currencyCode"),
            Map.entry("账户币种", "currencyCode"), Map.entry("扣款币种", "currencyCode"),
            Map.entry("手续费币种", "currencyCode"), Map.entry("收款币种", "currencyCode"), Map.entry("付款币种", "currencyCode"),
            Map.entry("银行手续费", "bankFee"), Map.entry("手续费", "bankFee"), Map.entry("bankfee", "bankFee"));
    private static final Set<String> RECEIPT = Set.of("实收金额", "实际到账金额", "到账金额", "入账金额", "收入金额", "贷方发生额", "creditamount");
    private static final Set<String> PAYMENT = Set.of("银行实际总扣款", "账户实际总扣款", "总扣款金额", "totalbankdebit");
    private static final Set<String> PAYMENT_UNCLEAR = Set.of("实付金额", "实际付款金额", "扣款金额", "支出金额", "借方发生额", "debitamount");
    private static final Set<String> AMBIGUOUS = Set.of("金额", "交易金额", "汇款金额", "转账金额", "收款金额", "付款金额", "amount", "transactionamount");
    private static final Pattern MONEY = Pattern.compile("(?:[0-9]{1,12}|[0-9]{1,3}(?:,[0-9]{3}){1,3})(?:\\.[0-9]{1,2})?");
    private final boolean receipt;
    private final List<Candidate> candidates = new ArrayList<>();
    private final LinkedHashSet<String> warnings = new LinkedHashSet<>();
    private boolean wrongDirection;
    private boolean ambiguousAmount;
    private boolean usableCurrency;
    private boolean separatePaymentFee;

    FinanceDocumentParser(String type) { receipt = type.equals("receipt"); }

    Result grid(DocumentGrid grid) {
        var sheets = grid.sheets().stream().filter(s -> !s.rows().isEmpty()).toList();
        if (sheets.size() != 1) return blocked("请每次上传一张只含一笔交易的工作表，多工作表文件请拆分后识别");
        var sheet = sheets.getFirst();
        if (sheet.truncated() || sheet.skippedHiddenRows() > 0)
            return blocked("文件有隐藏行或内容未完整读取，请导出只有这笔交易的完整表格");
        if (foreignDocument(sheet.rows().stream().map(DocumentGrid.Row::joinedText).toList()))
            return blocked("文件包含其他业务资料，请上传单独的银行回单");
        separatePaymentFee = feeContradiction(sheet.rows().stream().map(DocumentGrid.Row::joinedText).toList());
        var rows = sheet.rows();
        boolean headerSeen = false;
        for (int i = 0; i < rows.size(); i++) {
            var row = rows.get(i);
            long labels = row.cells().stream().filter(c -> field(c.text()) != null).count();
            boolean header = labels >= 2 && row.cells().stream().allMatch(c -> field(c.text()) != null
                    || c.text().matches("[\\p{L} _()（）]{1,40}"));
            if (header) {
                if (headerSeen || i + 1 >= rows.size()) return blocked("请只保留一笔银行交易及其表头后再识别");
                headerSeen = true;
                // Any additional non-empty data row is unsafe, even if amounts/references happen to be identical.
                if (rows.size() != i + 2) return blocked("文件含多笔交易或表尾内容，请拆分为单笔回单后识别");
                var values = rows.get(++i);
                for (var cell : row.cells()) {
                    var value = values.cell(cell.col0());
                    if (value != null) accept(cell.text(), value.text(), sheet.name() + "!" + DocumentGrid.columnLetter(cell.col0()) + (values.index0() + 1));
                }
            } else {
                boolean mapped = false;
                boolean unconsumed = false;
                for (int j = 0; j < row.cells().size(); j++) {
                    var cell = row.cells().get(j);
                    String location = sheet.name() + "!" + DocumentGrid.columnLetter(cell.col0()) + (row.index0() + 1);
                    if (field(cell.text()) != null && j + 1 < row.cells().size()
                            && row.cells().get(j + 1).col0() == cell.col0() + 1
                            && field(row.cells().get(j + 1).text()) == null) {
                        var value = row.cells().get(++j);
                        accept(cell.text(), value.text(), sheet.name() + "!" + DocumentGrid.columnLetter(value.col0()) + (row.index0() + 1));
                        mapped = true;
                    } else if (acceptLine(cell.text(), location)) mapped = true;
                    else unconsumed = true;
                }
                if (mapped && unconsumed) return blocked("字段旁有无法对应的内容，请核对原件后手工填写");
            }
        }
        return finish();
    }

    Result pdf(DocumentText text) {
        if (text.scanned()) return blocked("这是扫描 PDF，当前银行回单识别只支持文字 PDF、Excel 或 CSV，请手工核对或重新导出");
        if (text.truncated() || text.pageCount() != 1)
            return blocked("请上传单页、单笔银行回单，不能把多页内容合成一笔金额");
        var lines = text.pages().getFirst().lines();
        if (foreignDocument(lines)) return blocked("文件包含其他业务资料，请上传单独的银行回单");
        separatePaymentFee = feeContradiction(lines);
        for (int i = 0; i < lines.size(); i++) acceptLine(lines.get(i), "第 1 页，第 " + (i + 1) + " 行");
        return finish();
    }

    private boolean acceptLine(String line, String location) {
        String value = Normalizer.normalize(line, Normalizer.Form.NFKC).strip();
        // Single label/value only. Multiple columns on one PDF line are intentionally not guessed.
        int colon = value.indexOf(':');
        if (colon > 0 && value.indexOf(':', colon + 1) < 0) {
            if (field(value.substring(0, colon)) == null) return false;
            accept(value.substring(0, colon), value.substring(colon + 1), location);
            return true;
        }
        var split = value.split("\\s+", 2);
        if (split.length == 2 && field(split[0]) != null) {
            accept(split[0], split[1], location);
            return true;
        }
        return false;
    }

    private String field(String label) {
        String key = key(label);
        if (COMMON.containsKey(key)) return COMMON.get(key);
        if (RECEIPT.contains(key) || PAYMENT.contains(key) || PAYMENT_UNCLEAR.contains(key)) return "directionalAmount";
        return AMBIGUOUS.contains(key) ? "ambiguousAmount" : null;
    }

    private void accept(String label, String raw, String location) {
        String key = key(label);
        String field = field(label);
        if (field == null || raw.isBlank()) return;
        if (field.equals("ambiguousAmount")) { ambiguousAmount = true; return; }
        if (field.equals("directionalAmount")) {
            if (!receipt && PAYMENT_UNCLEAR.contains(key)) { ambiguousAmount = true; return; }
            if (!(receipt ? RECEIPT : PAYMENT).contains(key)) { wrongDirection = true; return; }
            field = "accountAmount";
        }
        if (field.equals("currencyCode")) {
            usableCurrency |= Set.of("币种", "账户币种", "currency").contains(key)
                    || (receipt ? Set.of("到账币种", "入账币种", "收款币种") : Set.of("扣款币种")).contains(key);
        }
        candidates.add(new Candidate(field, label.strip(), Normalizer.normalize(raw, Normalizer.Form.NFKC).strip(), location));
    }

    private Result finish() {
        if (wrongDirection) return blocked("文件出现与当前收付款方向不一致的金额，请核对用途后手工填写");
        if (!receipt && separatePaymentFee) return blocked("文件提到手续费不含在金额内或另扣，无法确认账户实际总扣款，请手工核对");
        if (candidates.stream().filter(c -> c.field.equals("accountAmount")).count() > 1
                || candidates.stream().filter(c -> c.field.equals("bankReference")).count() > 1)
            return blocked("文件出现多笔交易或重复金额、流水号，请拆分为单笔回单后识别");
        var fields = new LinkedHashMap<String, String>();
        var sources = new LinkedHashMap<String, String>();
        Set<String> conflicts = new LinkedHashSet<>();
        for (Candidate candidate : candidates) {
            String value = normalize(candidate.field, candidate.raw);
            if (value == null) {
                conflicts.add(candidate.field);
                warnings.add(candidate.label + "格式不明确，未带入，请按原件填写");
            } else if (fields.containsKey(candidate.field) && !fields.get(candidate.field).equals(value)) {
                conflicts.add(candidate.field);
                warnings.add(candidate.label + "有多个不同值，未带入，请按原件填写");
            } else {
                fields.put(candidate.field, value);
                sources.put(candidate.field, candidate.location + " · " + candidate.label);
            }
        }
        conflicts.forEach(field -> { fields.remove(field); sources.remove(field); });
        if (!usableCurrency) {
            fields.remove("currencyCode"); sources.remove("currencyCode");
        }
        if (!fields.containsKey("currencyCode") && fields.containsKey("accountAmount")) {
            fields.remove("accountAmount"); sources.remove("accountAmount");
            warnings.add("无法确认账户金额的币种，金额未带入，请核对原件后填写");
        }
        if (ambiguousAmount) warnings.add("文件中的交易金额不能证明账户实际收支，未用它推算到账金额或手续费");
        if (!fields.containsKey("accountAmount")) warnings.add("未找到明确的账户" + (receipt ? "实收" : "实付") + "金额，请手工核对");
        if (fields.isEmpty()) warnings.add("没有可确认带入的字段，可继续按原件手工录入");
        return new Result(Map.copyOf(fields), Map.copyOf(sources), List.copyOf(warnings));
    }

    private static String normalize(String field, String raw) {
        return switch (field) {
            case "accountAmount", "bankFee" -> money(raw, field.equals("bankFee"));
            case "transactionDate" -> date(raw);
            case "currencyCode" -> currency(raw);
            case "bankReference" -> raw.matches("[A-Za-z0-9][A-Za-z0-9_/-]{2,79}") ? raw : null;
            default -> null;
        };
    }
    private static String money(String raw, boolean allowZero) {
        if (!MONEY.matcher(raw).matches()) return null;
        BigDecimal value = new BigDecimal(raw.replace(",", ""));
        if (value.signum() < 0 || (!allowZero && value.signum() == 0)) return null;
        return value.setScale(2).toPlainString();
    }
    private static String date(String raw) {
        String value = raw.replace('/', '-').replace("年", "-").replace("月", "-").replace("日", "");
        if (!value.matches("[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}")) return null;
        String[] parts = value.split("-");
        try { return LocalDate.of(Integer.parseInt(parts[0]), Integer.parseInt(parts[1]), Integer.parseInt(parts[2])).toString(); }
        catch (java.time.DateTimeException | NumberFormatException ex) { return null; }
    }
    private static String currency(String raw) {
        return switch (raw.toUpperCase(Locale.ROOT)) {
            case "CNY", "RMB", "人民币" -> "CNY";
            case "USD", "美元" -> "USD";
            case "EUR", "欧元" -> "EUR";
            case "HKD", "港币", "港元" -> "HKD";
            case "JPY", "日元" -> "JPY";
            case "GBP", "英镑" -> "GBP";
            case "KRW", "韩元" -> "KRW";
            default -> null;
        };
    }
    private static String key(String raw) {
        return Normalizer.normalize(raw, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).replaceAll("[\\s:]", "");
    }
    private static boolean foreignDocument(List<String> lines) {
        return lines.stream().anyMatch(line -> Pattern.compile("发票|工资表|薪资表|报销申请|报价单|采购订单|销售订单|合同正文").matcher(line).find());
    }
    private static boolean feeContradiction(List<String> lines) {
        Pattern pattern = Pattern.compile("不含.{0,12}(手续费|费用)|(?:手续费|费用).{0,12}(另扣|另付|另行|另外)|(?:另扣|另付).{0,12}(手续费|费用)|exclud(?:e|es|ing).{0,12}fees?|fees?.{0,12}(separat|exclud)", Pattern.CASE_INSENSITIVE);
        return lines.stream().anyMatch(line -> pattern.matcher(line).find());
    }
    private static Result blocked(String warning) { return new Result(Map.of(), Map.of(), List.of(warning)); }
}
