package com.uten.imp.features.expenseclaim.ocr;

import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.DateTimeException;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 发票 OCR 文本 → 票面要素的规则抽取器（锚点 + 正则）。
 *
 * <p>发票是强版式半结构化文档：标签锚点（发票号码/开票日期/价税合计/销售方名称…）
 * 右侧或下方取值即可覆盖绝大多数字段，可解释、可单测、CPU 零成本；识别不确定
 * 一律留空待人工补（不给半截假数据）。数电票/专票/普票口径同税务总局 2024 年
 * 11 号公告。PaddleOCR 侧车与本解析器的契约：任意来源的文本行序列。
 */
final class InvoiceTextParser {

    private static final Pattern INVOICE_NO = Pattern.compile(
            "发票号码[:\\s：]*(\\d{20}|\\d{8})(?!\\d)");
    private static final Pattern INVOICE_CODE = Pattern.compile(
            "发票代码[:\\s：]*(\\d{12}|\\d{10})(?!\\d)");
    private static final Pattern ISSUE_DATE_CN = Pattern.compile(
            "开票日期[:\\s：]*(\\d{4})年(\\d{1,2})月(\\d{1,2})日");
    private static final Pattern ISSUE_DATE_ISO = Pattern.compile(
            "开票日期[:\\s：]*(\\d{4})-(\\d{2})-(\\d{2})");
    private static final Pattern TOTAL_AFTER_LABEL = Pattern.compile(
            "价税合计[^¥￥0-9]{0,12}[¥￥]?\\s*([0-9][0-9,]*\\.\\d{2})");
    private static final Pattern AMOUNT_WITH_SIGN = Pattern.compile(
            "[¥￥]\\s*([0-9][0-9,]*\\.\\d{2})");
    private static final Pattern TOTAL_LINE_CN = Pattern.compile(
            "价税合计[^0-9]{0,6}[（(]小写[）)][:\\s：]*[¥￥]?\\s*([0-9][0-9,]*\\.\\d{2})");
    private static final Pattern SUMMARY_AMOUNTS = Pattern.compile(
            "合\\s*计[^¥￥0-9]{0,8}[¥￥]?\\s*([0-9][0-9,]*\\.\\d{2})[^¥￥0-9]{0,10}[¥￥]?\\s*([0-9][0-9,]*\\.\\d{2})");
    private static final Pattern EXPLICIT_AMOUNT = Pattern.compile(
            "(?m)^(?:不含税金额|金额)[:：][¥￥]?([0-9][0-9,]*\\.\\d{2})$");
    private static final Pattern EXPLICIT_TAX = Pattern.compile(
            "(?m)^税额[:：][¥￥]?([0-9][0-9,]*\\.\\d{2})$");
    private static final Pattern NAME_AFTER_LABEL = Pattern.compile(
            "[：:][\\t ]*([^\\r\\n:：]{2,200})");
    private static final Pattern TAX_NO = Pattern.compile(
            "(?:纳税人识别号|统一社会信用代码|税\\s*号)[:\\s：]*([0-9A-Z]{20}|[0-9A-Z]{18}|[0-9A-Z]{15})(?![0-9A-Z])");
    private static final Pattern SPECIAL = Pattern.compile("增值税专用发票|专用发票");
    private static final Pattern PAPER = Pattern.compile("纸质|增值税普通发票");

    private InvoiceTextParser() {
    }

    /** 文本行（OCR 输出顺序）→ 票面要素；整体无价税合计返回 null（调用方报识别失败）。 */
    static RecognizedInvoiceDto parse(List<String> lines) {
        String text = lines == null ? "" : lines.stream().filter(java.util.Objects::nonNull)
                .limit(1000).map(line -> line.substring(0, Math.min(2000, line.length())))
                .collect(java.util.stream.Collectors.joining("\n"));
        if (text.length() > 128_000) return null;
        if (text.isBlank()) {
            return null;
        }
        String compact = text.replace(" ", "").replace("\u3000", "");

        String invoiceNo = firstGroup(INVOICE_NO.matcher(compact));
        String invoiceCode = firstGroup(INVOICE_CODE.matcher(compact));
        boolean digital = invoiceNo != null && invoiceNo.length() == 20;
        if (digital) {
            invoiceCode = "";
        }

        LocalDate issueDate = date(compact);
        BigDecimal total = amount(firstGroup(TOTAL_LINE_CN.matcher(compact)));
        if (total == null) {
            total = amount(firstGroup(TOTAL_AFTER_LABEL.matcher(compact)));
        }
        if (total == null) {
            // 仅在价税合计标签附近读取，不把银行账号或最后一项金额猜成票面总额。
            Matcher labelled = afterLabel(compact, "价税合计", AMOUNT_WITH_SIGN);
            if (labelled != null) {
                total = amount(labelled.group(1));
            }
        }
        if (total == null) {
            return null;
        }

        BigDecimal excl = null;
        BigDecimal tax = null;
        Matcher summary = SUMMARY_AMOUNTS.matcher(compact);
        if (summary.find()) {
            excl = amount(summary.group(1));
            tax = amount(summary.group(2));
        } else {
            excl = uniqueAmount(EXPLICIT_AMOUNT, compact);
            tax = uniqueAmount(EXPLICIT_TAX, compact);
        }
        if (excl == null || tax == null || excl.add(tax).compareTo(total) != 0) {
            // 不唯一、不完整或勾稽不符时不猜明细。
            excl = null;
            tax = null;
        }

        return new RecognizedInvoiceDto(
                type(compact, digital),
                emptyToNull(invoiceCode),
                emptyToNull(invoiceNo),
                issueDate,
                sellerName(compact),
                partyTaxNo(compact, "销售方"),
                buyerName(compact),
                partyTaxNo(compact, "购买方"),
                excl,
                tax,
                total,
                null);
    }

    private static String type(String compact, boolean digital) {
        if (digital) {
            return "DIGITAL";
        }
        if (SPECIAL.matcher(compact).find()) {
            return "SPECIAL";
        }
        if (PAPER.matcher(compact).find()) {
            return "PAPER_GENERAL";
        }
        return "";
    }

    private static LocalDate date(String compact) {
        try {
            Matcher cn = ISSUE_DATE_CN.matcher(compact);
            if (cn.find()) {
                return LocalDate.of(Integer.parseInt(cn.group(1)),
                        Integer.parseInt(cn.group(2)), Integer.parseInt(cn.group(3)));
            }
            Matcher iso = ISSUE_DATE_ISO.matcher(compact);
            if (iso.find()) {
                return LocalDate.of(Integer.parseInt(iso.group(1)),
                        Integer.parseInt(iso.group(2)), Integer.parseInt(iso.group(3)));
            }
        } catch (DateTimeException invalidDate) {
            // OCR 日期可能认错；其他可信字段仍可供人工预填。
        }
        return null;
    }

    private static String partyTaxNo(String compact, String party) {
        String[] lines = compact.split("\n");
        for (int index = 0; index < lines.length; index++) {
            if (lines[index].startsWith(party)) {
                for (int next = index; next < Math.min(lines.length, index + 3); next++) {
                    if (next > index && (lines[next].startsWith("购买方") || lines[next].startsWith("销售方"))) break;
                    String taxNo = firstGroup(TAX_NO.matcher(lines[next]));
                    if (taxNo != null) return taxNo;
                }
            }
        }
        // 无法定位购/销方时不猜另一方的税号。
        return null;
    }

    /** 销售方名称：优先「销售方名称：」锚点；退到「销」字区块里的名称行。 */
    private static String sellerName(String compact) {
        String labelled = partyName(compact, "销售方");
        if (labelled != null) return labelled;
        Matcher after = afterLabel(compact, "销售方名称", NAME_AFTER_LABEL);
        if (after != null) {
            return trimName(after.group(1));
        }
        return nameNear(compact, "销");
    }

    private static String buyerName(String compact) {
        String labelled = partyName(compact, "购买方");
        if (labelled != null) return labelled;
        Matcher after = afterLabel(compact, "购买方名称", NAME_AFTER_LABEL);
        if (after != null) {
            return trimName(after.group(1));
        }
        return nameNear(compact, "购");
    }

    private static String partyName(String compact, String party) {
        return firstGroup(Pattern.compile("(?m)^" + party + "(?:名称)?[:：]([^\\r\\n:：]{2,200})$").matcher(compact));
    }

    private static BigDecimal uniqueAmount(Pattern pattern, String text) {
        Matcher matcher = pattern.matcher(text);
        if (!matcher.find()) return null;
        BigDecimal value = amount(matcher.group(1));
        return matcher.find() ? null : value;
    }

    /** 「购/销 售 方」竖排标签块的下一行公司名（数电票左右分栏常见排布）。 */
    private static String nameNear(String compact, String keyword) {
        String[] lines = compact.split("\n");
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].contains(keyword) && lines[i].contains("售")) {
                for (var j = i + 1; j < Math.min(i + 3, lines.length); j++) {
                    Matcher name = Pattern.compile(
                            "名\\s*称[：:]?([\\u4e00-\\u9fa5（）()]{4,40})").matcher(lines[j]);
                    if (name.find()) {
                        return trimName(name.group(1));
                    }
                }
            }
        }
        return null;
    }

    private static String trimName(String raw) {
        String value = raw == null ? "" : raw.trim();
        return value.isEmpty() ? null : value;
    }

    /** 在锚点串之后的文本段里找第一个匹配（限定窗口，避免把合计行误当名称）。 */
    private static Matcher afterLabel(String compact, String label, Pattern valuePattern) {
        int index = compact.indexOf(label);
        if (index < 0) {
            return null;
        }
        int start = index + label.length();
        int end = Math.min(compact.length(), start + 240);
        Matcher matcher = valuePattern.matcher(compact).region(start, end);
        return matcher.find() ? matcher : null;
    }

    private static String firstGroup(Matcher matcher) {
        return matcher != null && matcher.find() ? matcher.group(1) : null;
    }

    private static BigDecimal amount(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        try {
            BigDecimal parsed = new BigDecimal(raw.replace(",", ""));
            return parsed.signum() >= 0 ? parsed : null;
        } catch (Exception exception) {
            return null;
        }
    }

    private static String emptyToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
