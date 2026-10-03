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
            "简单点", "再简单点", "简短点", "说简单点", "简单说", "简要说明", "总结一下", "概括一下",
            "换个说法", "summary", "summarize", "simpler", "keepitsimple", "간단히설명해주세요");

    private AiChatDialogueSupport() {}

    /** Exact social utterances only: additional requests or claimed identities remain normal input. */
    static Optional<String> socialReply(String message, Set<String> domains, Set<String> toolNames) {
        String question = normalized(message);
        if (THANKS.contains(question)) {
            return Optional.of("不客气。哪一点还不清楚，可以继续问，也可以让我按步骤说明或举例。");
        }
        boolean greeting = GREETINGS.contains(question);
        if (!greeting && !CAPABILITIES.contains(question)) return Optional.empty();
        Set<String> scope = domains == null ? Set.of() : domains;
        Set<String> tools = toolNames == null ? Set.of() : toolNames;
        List<String> examples = new ArrayList<>();
        if (scope.contains("SELF") && tools.contains("my_workbench")) examples.add("我的工作台有哪些待办？");
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
        if (scope.contains("HR")) examples.add("处理员工资料时，需要注意哪些权限边界？");
        if (scope.contains("ADMIN") && tools.contains("prepare_permission_grant")) {
            examples.add("给某位员工增加一项具体查看权限，先给我授权确认预览。");
        }
        String opening = greeting ? "你好，我在。你可以直接说遇到的问题，也可以让我按步骤说明或举例。"
                : "你可以让我解释当前可用范围内的业务流程，也可以继续追问例子、步骤或简要说明。";
        if (examples.isEmpty()) {
            return Optional.of(opening + "\n\n可以先打开需要帮助的业务页面，再告诉我具体页面或字段。实际可用内容以当前账号范围为准。");
        }
        return Optional.of(opening + "\n\n按你当前可用的范围，可以这样问：\n"
                + String.join("\n", examples.stream().map(value -> "- " + value).toList()));
    }

    /** Returns a presentation intent, never a new business topic, permission or action. */
    static String followUpMode(String message) {
        String question = normalized(message);
        if (EXAMPLES.contains(question)) return "EXAMPLE";
        if (STEPS.contains(question)) return "STEPS";
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
            case "EXAMPLE" -> example.isEmpty() ? "这项说明暂未登记可验证的示例。"
                    : EXAMPLE_MARKER + " " + example;
            case "STEPS" -> steps(explanation, example);
            default -> throw new IllegalArgumentException("Unsupported dialogue presentation mode");
        };
        return entry.title() + "\n\n" + body + "\n\n来源: 平台业务说明 / " + entry.title() + "。";
    }

    private static String steps(String explanation, String example) {
        // Keep source wording and all guards. Numbered presentation does not invent new workflow steps.
        List<String> sentences = List.of(explanation.split("(?<=[。；！？])\\s*|\\R+"))
                .stream().map(String::strip).filter(value -> !value.isEmpty()).toList();
        StringBuilder result = new StringBuilder("可以按下面几点理解：");
        for (int i = 0; i < sentences.size(); i++) result.append("\n").append(i + 1).append(". ").append(sentences.get(i));
        if (!example.isEmpty()) result.append("\n\n").append(EXAMPLE_MARKER).append(" ").append(example);
        return result.toString();
    }

    private static String normalized(String value) {
        if (value == null || value.length() > 2000) return "";
        return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
                .replaceAll("[\\s\\p{P}]+", "");
    }
}
