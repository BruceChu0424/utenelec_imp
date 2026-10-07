package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.Locale;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * What the uploader wants, read only from the user's own message (never from the document). Precedence:
 * explicit refusal or analysis-only, then filling a form, reconciling, importing, analysing, asking.
 */
final class AiDocumentIntent {
    enum Intent { RECONCILE, IMPORT, FILL, ANALYZE, QUESTION, NONE }

    private static final Pattern ANALYSIS_ONLY = Pattern.compile(
            "(?:不要|不需要|无需|禁止|别|勿|不用|(?<!能)不能).{0,20}(?:生成|新建|创建|填写|开单|保存|报销|订货|报价|单据)"
            + "|(?:只|仅|单纯).{0,8}(?:分析|识别|查看|看看|了解|检查|看一下|读一下)"
            + "|(?:do not|don't|don’t|never|no need to).{0,20}(?:create|fill|generate|save|submit)"
            + "|(?:only|just)\\s+(?:analy[sz]e|identify|inspect|read|view)"
            + "|(?:analy[sz]e|identify|inspect|read|view)\\s+only");
    private static final Pattern ONLY = Pattern.compile("(?:只|仅|单纯).{0,8}(?:分析|识别|查看|看看|了解|检查|看一下|读一下)"
            + "|(?:only|just)\\s+(?:analy[sz]e|identify|inspect|read|view)|(?:analy[sz]e|identify|inspect|read|view)\\s+only");
    private static final Pattern REFUSAL = Pattern.compile("(?:不要|不需要|无需|禁止|别|勿|不用|(?<!能)不能|do not|don't|don’t|never|no need to)");
    private static final Pattern INFORMATION_REQUEST = Pattern.compile("怎么|如何|怎样|流程|步骤|区别|解释|说明"
            + "|(?:能否|能不能|可否|可不可以|是否可以)(?!帮我|替我|为我)"
            + "|(?:可以|能够|能)转(?:换)?(?:成|为).*[吗?？]"
            + "|\\bhow\\b|\\b(?:can|could) (?:this|it|the file)\\b|\\b(?:explain|steps|process)\\b");
    private static final Pattern TARGET = Pattern.compile(
            "(?:生成|新建|创建|填写|制作|做|开|弄|整|来(?=一|张|个|份)|转(?:换)?(?:为|成)|改成|填成)[^，,。;；\\n]{0,10}?"
            + "(订货(?:单)?|销售订单|报价(?:单)?|报销(?:单|申请)?)"
            + "|(?:create|fill|make|open|generate|convert|turn)[^，,。;；\\n]{0,40}?"
            + "(sales order|quotation|quote|expense claim|reimbursement)");
    private static final Pattern CONVERSION = Pattern.compile("(?:convert|turn)[^，,。;；\\n]{0,60}?(?:into|to)\\s+(?:an?\\s+)?(sales order|quotation|quote|expense claim|reimbursement)");
    private static final Pattern COMBINED_TARGETS = Pattern.compile("(?:订货单|销售订单|报价单|报销单|sales order|quotation|quote|expense claim)"
            + "\\s*(?:和|及|与|或|或者|以及|、|and|or)\\s*(?:订货单|销售订单|报价单|报销单|sales order|quotation|quote|expense claim)");
    private static final Pattern RECONCILE = Pattern.compile("对照|核对|比对|对比|校对|更新|修正|纠正|改正|不对|不一致|补充|缺少|缺的|漏的"
            + "|(?<!批量)添加|补录|同步|reconcile|compare|cross[- ]?check|correct");
    private static final Pattern IMPORT = Pattern.compile("导入|录入|批量新增|批量添加|建档|import|bulk add");
    private static final Pattern ANALYZE = Pattern.compile("统计|汇总|分析|statistic|summar|analy[sz]");
    private static final Pattern QUESTION = Pattern.compile("是什么|什么文件|干什么|做什么用|怎么处理|能做什么|怎么办|有什么用"
            + "|what is|what's this|how (?:do|should|can) i");

    private AiDocumentIntent() {}

    static Intent parse(String message) {
        String text = normalize(message);
        if (text.isBlank()) return Intent.NONE;
        if (analysisOnly(text)) return Intent.ANALYZE;
        if (!requestedWorkflow(text).equals("NONE")) return Intent.FILL;
        if (INFORMATION_REQUEST.matcher(text).find()) return Intent.QUESTION;
        if (RECONCILE.matcher(text).find()) return Intent.RECONCILE;
        if (IMPORT.matcher(text).find()) return Intent.IMPORT;
        if (ANALYZE.matcher(text).find()) return Intent.ANALYZE;
        if (QUESTION.matcher(text).find()) return Intent.QUESTION;
        return Intent.NONE;
    }

    /** The form the user explicitly asked to fill, or NONE. Only the user's own words count. */
    static String requestedWorkflow(String message) {
        String text = normalize(message);
        if (ONLY.matcher(text).find()) return "NONE";
        Set<String> targets = new LinkedHashSet<>();
        for (String clause : text.split("[，,。;；\\n]|(?:并|然后)(?=请|帮我|告诉我|解释|说明)")) {
            // A refusal of one destination does not suppress a separate affirmative conversion request.
            if (REFUSAL.matcher(clause).find()) continue;
            if (INFORMATION_REQUEST.matcher(clause).find() || QUESTION.matcher(clause).find()) continue;
            if (COMBINED_TARGETS.matcher(clause).find()) return "NONE";
            var conversion = CONVERSION.matcher(clause);
            if (conversion.find()) {
                targets.add(workflow(conversion.group(1)));
                continue;
            }
            var matcher = TARGET.matcher(clause);
            while (matcher.find()) {
                String target = matcher.group(1) == null ? matcher.group(2) : matcher.group(1);
                targets.add(workflow(target));
            }
            if (contains(clause, "报销", "expense claim", "reimbursement") && !contains(clause, "不是", "并非", "not an", "not a")
                    && targets.isEmpty()) targets.add("EXPENSE_CLAIM");
        }
        return targets.size() == 1 ? targets.iterator().next() : "NONE";
    }

    private static String workflow(String target) {
        return contains(target, "订货", "销售订单", "sales order") ? "SALES_ORDER"
                : contains(target, "报价", "quotation", "quote") ? "SALES_QUOTE" : "EXPENSE_CLAIM";
    }

    /** An explicit refusal takes precedence over positive words inside the same sentence. */
    static boolean analysisOnly(String message) {
        String text = normalize(message);
        return ONLY.matcher(text).find() || (ANALYSIS_ONLY.matcher(text).find() && requestedWorkflow(text).equals("NONE"));
    }

    private static boolean contains(String text, String... words) {
        for (String word : words) if (text.contains(word)) return true;
        return false;
    }

    private static String normalize(String message) {
        return Normalizer.normalize(message == null ? "" : message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
    }
}
