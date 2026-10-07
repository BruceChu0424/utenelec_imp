package com.uten.imp.features.ai.chat;

import java.util.regex.Pattern;
import java.util.List;

/**
 * The model understands ordinary conversation and general work questions. These checks do not classify
 * allowed subjects: they prevent that non-authoritative answer channel being used for company facts,
 * private data, platform rules or operations. All real reads and actions retain their own authorization.
 */
final class AiChatGeneralConversation {
    private AiChatGeneralConversation() {}

    /** A supplied passage is data to transform, not a request to retrieve the facts mentioned inside it. */
    private static final Pattern TEXT_TRANSFORMATION = Pattern.compile(
            "(?is)^[^:：\\n]{0,100}(?:翻译|润色|改写|措辞|重写|translate|rewrite|rephrase|polish)[^:：\\n]{0,60}[:：\\n]\\s*\\S[\\s\\S]*$");

    static boolean transformsUserText(String question) {
        return question != null && TEXT_TRANSFORMATION.matcher(question).matches();
    }

    private static final Pattern DRAFT_MESSAGE = Pattern.compile(
            "(?is)(?:写|拟|起草|撰写|write|draft).{0,100}(?:邮件|短信|通知|道歉|回信|回复|话术|email|message|reply|apology)");
    private static final Pattern READ_RECORDS = Pattern.compile(
            "(?:查|查询|读取|列出|统计).{0,30}(?:工资|薪资|财务|库存|订单|数据|余额|成本)"
                    + "|(?i:\\b(?:look up|retrieve|query|list)\\b.{0,35}\\b(?:salary|payroll|inventory|orders?|records?)\\b)");
    private static final Pattern EXPLICIT_ACCESS = Pattern.compile("权限|无权|(?i:\\b(?:permission|access denied)\\b)|권한");
    private static final Pattern PLATFORM_CONTEXT = Pattern.compile("平台|系统|页面|菜单|按钮|(?i:\\b(?:platform|system|page|menu|button)\\b)");
    /** A request for facts about a referenced record, not the mere presence of a business noun. */
    private static final Pattern FACT_QUESTION = Pattern.compile(
            "查|读取|列出|统计|汇总|多少|几个|几条|几张|哪些|哪个|还有|还剩|剩余|有没有|是否|进度|状态|到哪|到了没|发货了没|批了没|是什么|是啥"
                    + "|(?i:\\b(?:what\\s+(?:is|are|was|were|about)|how\\s+(?:much|many|is|are)|where\\s+(?:is|are|was|were)"
                    + "|has|have|did|does|is|are|was|were|show|lookup|retrieve|query|list|status|balance|remaining)\\b)");

    static boolean draftsUserMessage(String question) {
        return question != null && DRAFT_MESSAGE.matcher(question).find() && !READ_RECORDS.matcher(question).find()
                && !LOCAL_RULE.matcher(question).find()
                && !question.matches(".*(?:公司|平台|系统).{0,16}(?:规定|规则|制度|政策|流程).*");
    }

    private static final List<Pattern> COMPLETED_ACTIONS = List.of(
            "保存|saved", "提交|submitted", "审核|审批|批准|approved", "删除|deleted", "授权|开通|granted",
            "过账|posted", "执行|executed", "修改|改好|改成|changed|updated", "发送|发出|sent",
            "下单|下达", "入库", "出库", "付款|paid", "作废", "填好|填入", "确认", "完成|处理").stream()
            .map(words -> Pattern.compile("(?i)" + String.join("|", java.util.Arrays.stream(words.split("\\|"))
                    .map(word -> word.matches("[a-z]+") ? "\\b" + word + "\\b" : word).toList()))).toList();
    private static final Pattern COMPLETED_MARKER = Pattern.compile("已经|已|刚刚|刚才|成功|(?i:\\b(?:I|we)\\s+(?:have\\s+|had\\s+|already\\s+|just\\s+)?$)");
    private static final Pattern NOT_COMPLETED = Pattern.compile("未|没|没有|尚未|还没|将|打算|准备|计划|(?i:\\b(?:not|never|will|would|plan|intend)\\b)");

    /** A translated/rewritten completion is the user's quoted statement only when the original says the same action was done. */
    static boolean suppliedCompletion(String claim, String question) {
        if (!transformsUserText(question) && !draftsUserMessage(question)) return false;
        String supplied = transformsUserText(question) ? question.split("[:：\\n]", 2)[1] : question;
        boolean found = false;
        for (Pattern action : COMPLETED_ACTIONS) {
            if (!action.matcher(claim).find()) continue;
            found = true;
            boolean supported = false;
            for (String clause : supplied.split("[。！!；;，,\\n]")) {
                var written = action.matcher(clause);
                while (written.find()) {
                    String before = clause.substring(Math.max(0, written.start() - 30), written.start());
                    if (COMPLETED_MARKER.matcher(before).find() && !NOT_COMPLETED.matcher(before).find()) supported = true;
                }
            }
            if (!supported) return false;
        }
        return found;
    }

    static String attributeSuppliedText(String reply, String language) {
        return switch (language) {
            case "en" -> "Suggested wording (based on your text):\n" + reply;
            case "ko" -> "제공하신 내용을 바탕으로 다듬은 문구:\n" + reply;
            default -> "建议表述（根据你提供的内容）：\n" + reply;
        };
    }

    private static final Pattern BUSINESS_REFERENCE = Pattern.compile(
            "本(?:平台|系统|公司)|(?:我们|我司|你们|公司)(?:的)?(?:规定|规则|制度|流程|政策|工资|财务|库存|订单|数据)"
                    + "|(?:这|那|刚才|之前|上次|上一轮|前面)(?:张|个|批|份|笔|的|提到的|查到的|说的)*(?:单|订单|报价|货|数据|结果|库存|工资|页面)"
                    + "|(?:我的|他的|她的|同事的|员工的)(?:工资|薪资|报销|财务|库存|权限|订单|数据)"
                    + "|(?:平台|系统|公司)(?:里|中|上|规定|规则)|(?:查|查询|读取|列出|统计).*(?:工资|薪资|财务|库存|订单|数据)"
                    + "|(?i:\\b(?:our|your|this)\\s+(?:company|platform|system|order|invoice|stock|inventory|policy|payroll)\\b"
                    + "|\\b(?:my|their|his|her)\\s+(?:salary|payroll|orders?|expenses?|permissions?)\\b"
                    + "|\\b(?:previous|earlier|last)\\s+(?:orders?|invoices?|records?|results?|stock|payroll)\\b)");
    private static final Pattern LOCAL_RULE = Pattern.compile(
            "(?:在|这个|我们|本)(?:平台|系统|软件)|(?:公司|平台|系统)(?:要求|必须|允许|不允许|支持|不支持|默认|会|不会|自动)"
                    + "|(?i:\\b(?:the|our|this)\\s+(?:system|platform|company)\\s+(?:requires?|allows?|will|does|automatically|defaults?)\\b)");
    private static final Pattern CLAIMED_FACT = Pattern.compile(
            "(?:(?:我|已经|已)(?:查询到|查到|查得)|(?:查询结果|记录|系统|页面)显示|(?:实时天气|今天气温)(?:是|为)|今天(?:晴天|下雨|阴天|是晴天|是阴天))"
                    + "|(?:你的|我的|他的|她的|本公司|我司).{0,15}(?:工资|余额|库存|订单|权限).{0,10}(?:是|为|有|已|剩|批准|发货)"
                    + "|(?:这张|那张|该)(?:订单|订货单|报价单|单据).{0,10}(?:已|未|正在|通过|批准|取消|发货)"
                    + "|(?i:\\b(?:records? show|I found|I looked up|current weather is|today.s temperature is)\\b)");

    static boolean requiresEvidence(String question, AiChatConversation.History history) {
        if (transformsUserText(question)) {
            // Evaluate the actual instruction, not the separately supplied passage. Mixed read/permission
            // requests in that instruction are not made safe just by adding a translation marker.
            String instruction = question.split("[:：\\n]", 2)[0];
            return READ_RECORDS.matcher(instruction).find() || EXPLICIT_ACCESS.matcher(instruction).find();
        }
        if (draftsUserMessage(question)) return false;
        boolean platform = PLATFORM_CONTEXT.matcher(question).find();
        if (AiChatJobHandler.dataQuestion(question)
                || (BUSINESS_REFERENCE.matcher(question).find() && (FACT_QUESTION.matcher(question).find()
                || question.matches(".*(?:规定|规则|制度|政策|流程|policy|rules).*")))
                || LOCAL_RULE.matcher(question).find() || EXPLICIT_ACCESS.matcher(question).find()
                || (platform && (AiChatDialogueSupport.asksAboutAccess(question) || AiChatDialogueSupport.asksWhere(question)))
                || AiChatDialogueSupport.asksAboutPageText(question)) return true;
        // Elliptical follow-ups retain the previous authority class, never relabel its facts as general knowledge.
        var latest = history.latest();
        return latest != null && !java.util.Set.of("SMALL_TALK", "GENERAL_HELP").contains(latest.intent())
                && (AiChatDialogueSupport.followUpMode(question) != null
                || question.matches(".*(?:刚才|之前|上一|那张|这张|那批|这些|那些|earlier|previous).*"));
    }

    static boolean claimsAuthoritativeFacts(String reply) {
        return LOCAL_RULE.matcher(reply).find() || CLAIMED_FACT.matcher(reply).find();
    }

    static String unavailable(String language) {
        return switch (language) {
            case "en" -> "I couldn't put together a reliable answer this time. Tell me a little more about what you need and I'll try again.";
            case "ko" -> "이번에는 믿을 만한 답변을 정리하지 못했어요. 어떤 도움이 필요한지 조금 더 알려 주세요.";
            default -> "这次没能整理出可靠的回答。可以再说具体一点，我接着帮你想。";
        };
    }
}
