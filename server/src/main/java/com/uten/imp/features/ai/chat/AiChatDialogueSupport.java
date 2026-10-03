package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/** Local conversational presentation. Callers supply authorized capabilities and recheck each source. */
final class AiChatDialogueSupport {
    private static final String EXAMPLE_MARKER = "举例(假设数据，不是系统当前事实):";
    private static final Set<String> GREETINGS = Set.of(
            "你好", "您好", "嗨", "哈喽", "在吗", "早上好", "下午好", "晚上好", "早安",
            "hello", "hi", "hey", "안녕하세요", "안녕");
    private static final Set<String> THANKS = Set.of(
            "谢谢", "谢谢你", "谢谢啦", "多谢", "感谢", "感谢你", "thankyou", "thanks", "thx", "감사합니다", "고마워요");
    private static final Set<String> CAPABILITIES = Set.of(
            "你能做什么", "你能帮我什么", "你能帮我做什么", "我能让你做什么", "我能让你帮忙做什么",
            "能做什么", "怎么用你", "如何使用你", "whatcanyoudo", "howcanyouhelp", "무엇을할수있나요");
    private static final Set<String> EXAMPLES = Set.of(
            "举例", "举个例子", "请举例", "请举个例子", "给个例子", "再举个例子", "举个具体例子",
            "能举个例子吗", "example", "anexample", "giveanexample", "pleasegiveanexample", "예를들어주세요");
    private static final Set<String> STEPS = Set.of(
            "下一步", "然后呢", "接下来呢", "怎么操作", "具体步骤", "操作步骤", "分步说明", "按步骤说",
            "一步一步说", "接下来怎么做", "下一步怎么做", "steps", "stepbystep", "nextstep", "whatnext", "다음단계");
    private static final Set<String> SUMMARIES = Set.of(
            "简单点", "简单一点", "简洁点", "简洁一点", "再简单点", "简短点", "说简单点", "简单说", "简要说明", "总结一下", "概括一下",
            "换个说法", "说重点", "直接说重点", "一句话", "summary", "summarize", "simpler", "keepitsimple", "간단히설명해주세요");
    private static final Set<String> DETAILS = Set.of("展开", "展开看看", "详细", "详细点", "详细说说", "查看详情", "全部列出来", "更多", "details", "showdetails", "expand");

    private AiChatDialogueSupport() {}

    /** Exact social utterances only: additional requests or claimed identities remain normal input. */
    static Optional<String> socialReply(String message, Set<String> domains, Set<String> toolNames) {
        String question = normalized(message);
        if (THANKS.contains(question)) {
            return Optional.of("不客气，有问题再问我。");
        }
        boolean greeting = GREETINGS.contains(question);
        if (!greeting && !CAPABILITIES.contains(question)) return Optional.empty();
        if (greeting) return Optional.of("你好，需要我帮你做什么？");
        Set<String> scope = domains == null ? Set.of() : domains;
        Set<String> tools = toolNames == null ? Set.of() : toolNames;
        List<String> examples = new ArrayList<>();
        if (scope.contains("SELF") && tools.contains("my_workbench")) examples.add("我的工作台有哪些待办？");
        if (scope.contains("SELF") && tools.contains("workbench_tasks") && !tools.contains("my_workbench")) examples.add("我有哪些待办？");
        if (scope.contains("PRODUCTION") && tools.contains("production_in_progress")) examples.add("有什么正在生产的产品？");
        if (scope.contains("WAREHOUSE") && tools.contains("inventory_lookup")) examples.add("A001 还有多少库存？");
        if (scope.contains("SALES") && tools.contains("query_client_credit")) examples.add("客户有没有逾期欠款？");
        if (scope.contains("HR") && tools.contains("hr_tasks")) examples.add("有哪些待转正和近期入职的人事任务？");
        if (scope.contains("PRODUCTION")) examples.add("生产日报的本次数量怎么填写？请举例。");
        if (scope.contains("SALES")) examples.add("报价核价、客户同意和订货之间是什么顺序？");
        if (scope.contains("PURCHASE")) examples.add("采购分批到货时，数量应该怎么核对？");
        if (scope.contains("WAREHOUSE")) examples.add("库存盘点有差异时，该怎么记录和处理？");
        if (scope.contains("FINANCE")) {
            examples.add(tools.contains("query_goods_cost")
                    ? "帮我查询某个货品编码的成本，并说明成本口径。"
                    : "参考成本和实际成本有什么区别？");
        }
        if (scope.contains("QUALITY")) examples.add("有部分数量待复检时，该怎么理解检验结果？");
        if (scope.contains("SUBCONTRACT")) examples.add("委外分批回厂时，怎么保留订单和数量来源？");
        if (scope.contains("HR")) examples.add("员工资料怎么填写？");
        if (scope.contains("ADMIN") && tools.contains("prepare_permission_grant")) {
            examples.add("给员工开通一项查看权限。");
        }
        if (examples.isEmpty()) {
            return Optional.of("告诉我遇到的问题，或打开页面问我怎么填。");
        }
        return Optional.of("可以这样问我：\n" + String.join("\n", examples.stream().limit(3).map(value -> "• " + value).toList()));
    }

    static boolean wantsDetails(String message) {
        String value = normalized(message);
        if (SUMMARIES.contains(value) || value.matches(".*(?:简短|简洁|简单(?:说|点|一点|一些|些)|简要|精简|说重点|一句话|(?:不要|不用|不需要|无需|不必|别).{0,8}(?:展开|详细|明细)).*")) return false;
        return DETAILS.contains(value) || value.matches(".*(?:详细|展开|全部|所有|明细|每一条|showall|details).*" );
    }
    static boolean isQueryPresentationFollowUp(String message) {
        String value=normalized(message);
        return DETAILS.contains(value) || SUMMARIES.contains(value);
    }

    /** Returns a presentation intent, never a new business topic, permission or action. */
    static String followUpMode(String message) {
        String question = normalized(message);
        if (EXAMPLES.contains(question)) return "EXAMPLE";
        if (STEPS.contains(question)) return "STEPS";
        if (DETAILS.contains(question)) return "STEPS";
        if (SUMMARIES.contains(question)) return "SUMMARY";
        return null;
    }

    /** Formats only an already-authorized catalog entry. It never looks up or expands knowledge. */
    static String renderKnowledge(AiChatKnowledge.Entry entry, String mode) {
        Objects.requireNonNull(entry, "entry");
        String text = Objects.requireNonNull(entry.reply(), "entry.reply").strip();
        int marker = text.indexOf(EXAMPLE_MARKER);
        String explanation = marker < 0 ? text : text.substring(0, marker).strip();
        String example = marker < 0 ? "" : text.substring(marker + EXAMPLE_MARKER.length()).strip();
        String selected = mode == null || mode.isBlank() ? "OVERVIEW" : mode;
        String body = switch (selected) {
            case "OVERVIEW" -> text;
            case "SUMMARY" -> explanation;
            case "EXAMPLE" -> example.isEmpty() ? "暂时没有合适的例子。"
                    : "举例（假设）：" + example;
            case "STEPS" -> steps(explanation, example);
            default -> throw new IllegalArgumentException("Unsupported dialogue presentation mode");
        };
        return body.replace(EXAMPLE_MARKER, "举例（假设）：");
    }

    private static String steps(String explanation, String example) {
        // Keep source wording and all guards. Numbered presentation does not invent new workflow steps.
        List<String> sentences = List.of(explanation.split("(?<=[。；！？])\\s*|\\R+"))
                .stream().map(String::strip).filter(value -> !value.isEmpty()).toList();
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < sentences.size(); i++) result.append("\n").append(i + 1).append(". ").append(sentences.get(i));
        if (!example.isEmpty()) result.append("\n\n").append(EXAMPLE_MARKER).append(" ").append(example);
        return result.toString().strip();
    }

    private static String normalized(String value) {
        if (value == null || value.length() > 2000) return "";
        return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
                .replaceAll("[\\s\\p{P}]+", "");
    }
}
