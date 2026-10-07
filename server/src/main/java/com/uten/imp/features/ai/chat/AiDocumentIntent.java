package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * What the uploader wants, read only from the user's own message (never from the document). Precedence:
 * explicit refusal or analysis-only, then filling a form, reconciling, importing, analysing, asking.
 */
final class AiDocumentIntent {
    enum Intent { RECONCILE, IMPORT, FILL, ANALYZE, QUESTION, NONE }

    private static final Pattern ANALYSIS_ONLY = Pattern.compile(
            "(?:不要|不需要|无需|禁止|别|勿|不用|不能).{0,20}(?:生成|新建|创建|填写|开单|保存|报销|订货|报价|单据)"
            + "|(?:只|仅|单纯).{0,8}(?:分析|识别|查看|看看|了解|检查|看一下|读一下)"
            + "|(?:do not|don't|don’t|never|no need to).{0,20}(?:create|fill|generate|save|submit)"
            + "|(?:only|just)\\s+(?:analy[sz]e|identify|inspect|read|view)"
            + "|(?:analy[sz]e|identify|inspect|read|view)\\s+only");
    private static final Pattern ORDER = Pattern.compile("(?:生成|新建|创建|填写|做|开|弄|整|来(?=一|张|个|份)).{0,8}(?:订货|销售订单)|(?:create|fill|make|open).{0,12}sales order");
    private static final Pattern QUOTE = Pattern.compile("(?:生成|新建|创建|填写|做|开|弄|整|来(?=一|张|个|份)).{0,8}报价|(?:create|fill|make|open).{0,12}quotation");
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
        if (ANALYSIS_ONLY.matcher(text).find()) return Intent.ANALYZE;
        if (!requestedWorkflow(text).equals("NONE")) return Intent.FILL;
        if (RECONCILE.matcher(text).find()) return Intent.RECONCILE;
        if (IMPORT.matcher(text).find()) return Intent.IMPORT;
        if (ANALYZE.matcher(text).find()) return Intent.ANALYZE;
        if (QUESTION.matcher(text).find()) return Intent.QUESTION;
        return Intent.NONE;
    }

    /** The form the user explicitly asked to fill, or NONE. Only the user's own words count. */
    static String requestedWorkflow(String message) {
        String text = normalize(message);
        if (contains(text, "报销", "expense claim", "reimbursement")) return "EXPENSE_CLAIM";
        if (ORDER.matcher(text).find()) return "SALES_ORDER";
        if (QUOTE.matcher(text).find()) return "SALES_QUOTE";
        return "NONE";
    }

    /** An explicit refusal takes precedence over positive words inside the same sentence. */
    static boolean analysisOnly(String message) {
        return ANALYSIS_ONLY.matcher(normalize(message)).find();
    }

    private static boolean contains(String text, String... words) {
        for (String word : words) if (text.contains(word)) return true;
        return false;
    }

    private static String normalize(String message) {
        return Normalizer.normalize(message == null ? "" : message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
    }
}
