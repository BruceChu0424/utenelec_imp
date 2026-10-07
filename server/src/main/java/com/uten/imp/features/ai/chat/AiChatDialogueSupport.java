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

    /** Obvious recreational requests are rejected locally; other input still uses the closed ERP router. */
    static boolean clearlyNonWork(String message) {
        String value = normalized(message);
        return value.matches("(?:请|帮我|给我|能不能|可以)?(?:讲|说|编)(?:一个|个|一段)?(?:笑话|鬼故事|童话|段子).*"
                + "|(?:请|帮我|给我)?(?:写|创作)(?:一首|首|一封|封|一个|个)?(?:情诗|情书|小说|歌曲).*"
                + "|(?:请|帮我|给我)?推荐(?:几部|一部|个|一个)?(?:电影|电视剧|游戏).*"
                + "|(?:陪我闲聊|陪我聊天|今天的?星座运势|tellmeajoke|writealovepoem).*"
                + "|(?:今天|明天)(?:天气|会下雨)(?:怎么样|如何|吗)?");
    }

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
        if (scope.contains("SALES") && tools.contains("sales_order_progress")) examples.add("这张销售订货单(写上单号)现在到哪一步了？");
        if (scope.contains("PURCHASE") && tools.contains("purchase_order_status")) examples.add("这张采购订货单(写上单号)到货了吗？");
        if (scope.contains("SUBCONTRACT") && tools.contains("subcontract_order_status")) {
            examples.add("这张委外申请(写上单号)为什么还不能下单？");
        }
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

    static boolean isQueryPresentationFollowUp(String message) {
        String value=normalized(message);
        return DETAILS.contains(value) || SUMMARIES.contains(value);
    }

    /** The user asks what colours, status tones or legends on the page mean. */
    static boolean asksAboutColors(String message) {
        String value = normalized(message);
        return asksAboutColourWords(message)
                || value.matches(".*状态.*(?:含义|意思|代表|区别|分别|说明).*")
                || value.matches(".*(?:红框|黄框|红色数字|黄色数字|红色徽章|黄色徽章|括号里?的数字).*(?:意思|含义|代表|是什么|干什么).*");
    }

    /** The user asks which values need checking, are missing or flagged on the current page. */
    static boolean asksForReview(String message) {
        String value = normalized(message);
        return value.matches(".*(?:检查|核对|核实|再确认|需要确认|待确认|待核|要确认|黄框|红框|必填|没填|漏填|未填|错误|报错|问题|异常|不对|有误|标红|review|check|verify|missing|확인).*");
    }

    /**
     * ADR-153 the question asks how something works (how it is calculated, why, the rule, the flow, what
     * happens if ...): the platform's design documents are searched for it.
     */
    static boolean asksForRules(String message) {
        String value = normalized(message);
        return value.matches(".*(?:怎么|如何|怎样|为什么|为何|为啥|规则|口径|逻辑|原理|流程|步骤|区别|意思|含义|计算|估算|换算|折算|怎么算"
                + "|会显示|显示成|会变|会不会|能不能|可不可以|是否|如果|假如|比如|例如|举例|什么情况|什么时候|何时|哪里|在哪|谁来|谁能|谁审"
                + "|算不算|算作|计入|扣多少|多重|作用|用途|下一步|然后呢|做什么|干什么|要做|先做|需要什么|要什么|条件|前提|要求|注意|能否"
                + "|显示什么|是什么|看什么|有什么用|干什么用|做什么用|按哪|哪天|哪一天|多久|谁来|谁负责|谁确认|按什么|的算|怎么定|如何定"
                + "|可否|允许|必须|how|why|rule|explain|calculat|whathappens|whatif|difference|mean|whatdoi|whatshouldi"
                // Yes/no and listing questions about how the platform behaves ("…马上就改了吗", "包含哪些单据", "我看得到吗").
                + "|吗|嘛|是不是|对不对|对吗|哪些|包含|包括|看得到|看得见|看不到|算不算|马上|立即|立刻|直接|会怎样|会怎么样|怎么办|影响"
                + "|需不需要|要不要|行不行|有没有用|^who|who(?:approves|reviews|can|is|handles)|when|does|^do|^is|^are|^can|^will|^should"
                + "|어떻게|왜|규칙|누가|언제|어디|무엇|나요|까요|습니까|인가요|되나요|하나요|있나요).*");
    }

    /**
     * A plain lookup of the user's own business data ("A001 还有多少库存", "我有哪些待办", "订单 SO-1 现在什么状态",
     * "XD20261006000003 发货了没"): answered by a tool, so no design document is searched for it. A question that asks
     * how or why is never one; a yes/no question is one only when it asks for a status ("PO-2026001 到货了吗").
     */
    static boolean dataLookup(String message) {
        String value = normalized(message);
        if (value.isEmpty() || value.matches(".*(?:为什么|为何|为啥|怎么|如何|规则|口径|流程|逻辑|why|how|rule|왜|어떻게).*")) return false;
        boolean code = businessCode(message);
        // "我的仓库" names a feature (a rule question); "我有哪些待办" asks for the user's own items.
        boolean mine = value.matches(".*(?:我有哪些|我有多少|我今天|我这周|我本月|待办|工作台|我的(?:待办|任务|订单|单据|申请|报销单)(?!中心)).*");
        boolean yesNo = value.matches(".*(?:吗|嘛|看得到|看得见|看不到|包含|算不算|会不会|能不能).*");
        if (code && STATUS_WORDS.matcher(value).find()) return true;
        return (code || mine) && !yesNo && asksForData(message);
    }

    /** A business code or document number the user typed ("XD20261006000003", "SO-127001", "PO-2026001", "A001"). */
    static boolean businessCode(String message) {
        return message != null && message.length() <= 2000 && BUSINESS_CODE.matcher(Normalizer.normalize(message, Normalizer.Form.NFKC)).find();
    }

    private static final java.util.regex.Pattern BUSINESS_CODE =
            java.util.regex.Pattern.compile("(?<![A-Za-z0-9])[A-Za-z]{1,6}[-_]?\\d{2,}[A-Za-z0-9_-]*");
    /**
     * Everyday words that ask whether something is there, enough, done or where it stands (on the normalized text):
     * "螺丝还有吗", "够不够用", "到了没", "发货了没有", "批了没", "到哪一步了", "卡在哪", "什么时候到", "做完没".
     */
    private static final java.util.regex.Pattern STATUS_WORDS = java.util.regex.Pattern.compile("还有吗|还有没有|有货|有没有货|够不够|够用|还够"
            + "|缺不缺|到了没|到了吗|到没到|到货了没|到货了吗|到货没|发了没|发了吗|发货了没|发货了吗|发没发|批了没|批了吗|审了没|审了吗|了没有|了没|到哪(?:一步)?了"
            + "|到哪一步|卡在|什么时候到|几时到|进展|做完没|做完了吗|几时");
    /** A question in the user's own words ("…吗", "…多少", "…?"). */
    private static final java.util.regex.Pattern QUESTION = java.util.regex.Pattern.compile("[?？]|吗|呢|么|没|多少|几|什么|哪|是否|怎样|如何"
            + "|状态|进度|情况|(?i:\\b(?:what|when|where|which|how|is|has|did)\\b)");

    /**
     * The user's own words ask for a careful, step-by-step analysis: this answer thinks more deeply than the account's
     * default (which favours fast answers).
     */
    static boolean asksForDeepAnalysis(String message) {
        String value = normalized(message);
        return value.matches(".*(?:详细分析|仔细分析|深入分析|认真分析|仔细想|好好想|认真想|推演|一步一步|一步步|逐步推算|详细推算|详细算|仔细算|深度思考"
                + "|thinkcarefully|stepbystep|indepth|analy[sz]eindetail|detailedanalysis|자세히분석|단계별|깊이생각).*");
    }

    /**
     * ADR-153 the user's own words ask for business data (a list, a count, a status, a balance): only then may
     * the model's choice run a read tool. Page text, documents or history asking for a tool never qualify.
     */
    static boolean asksForData(String message) {
        String value = normalized(message);
        if (value.matches(".*(?:查|多少|几个|几条|几张|几单|几项|几种|几天|哪些|哪个|哪几|有没有|有什么|是否有|列出|列一下|看看|看一下|告诉我"
                + "|统计|汇总|情况|进度|状态|还剩|剩余|余额|库存|存货|待办|任务|欠款|逾期|在产|正在|最近|今天|昨天|本周|上周|本月|上月|今年"
                + "|成本|信用|额度|工作台|入职|转正|权限|授权|开通|howmany|howmuch|which|list|show|status|pending|stock|overdue|inprogress"
                + "|cost|credit|몇|얼마|목록|재고).*")) return true;
        if (STATUS_WORDS.matcher(value).find()) return true;
        // A business code or document number with a question ("XD20261006000003 这个订单呢", "A001 还够做100个吗").
        return businessCode(message) && QUESTION.matcher(Normalizer.normalize(message, Normalizer.Form.NFKC)).find();
    }

    /**
     * Whether the user's own words make this read tool eligible to run once the model chose it. A tool runs only on
     * the user's own request (page text, documents or history never qualify): the feature directory on a question
     * where something is or which features exist, the access check on a question why something cannot be opened or
     * used (not on a question about a numbered document unless it names permissions), every other tool (document
     * status, stock, tasks) on a data question.
     */
    static boolean toolEligible(String toolName, String message) {
        // A question about a numbered document ("EB… 为什么下不了单", "按钮是灰的") is about that document's state, which its
        // status tool explains; the access check runs on it only when the user asks about permissions.
        if (MY_ACCESS.equals(toolName) && businessCode(message) && !asksAboutPermission(message)) return false;
        if (asksForData(message)) return true;
        return switch (toolName == null ? "" : toolName) {
            case FEATURE_DIRECTORY -> asksWhere(message);
            case MY_ACCESS -> asksAboutAccess(message) || asksWhere(message);
            default -> false;
        };
    }

    /** The read tool that answers where a page is and which features exist (feature and page directory). */
    static final String FEATURE_DIRECTORY = "feature_directory";
    /** The read tool that answers whether the user can open or do something and which permissions are missing. */
    static final String MY_ACCESS = "my_access";

    /** "采购单在哪里看", "哪个页面能看库存", "怎么进仓库任务中心", "系统有哪些功能". */
    static boolean asksWhere(String message) {
        return normalized(message).matches(".*(?:在哪里|在哪儿|在哪|哪个页面|哪个页|哪一页|哪个菜单|哪个模块|怎么进|如何进|从哪进|从哪里进|怎么打开"
                + "|如何打开|入口|有哪些功能|有什么功能|哪些功能|能做什么|可以做什么|能干什么|有哪些模块|哪些模块|有哪些页面|哪些页面|什么页面"
                + "|where|whichpage|whichmenu|howdoiopen|howtoopen|howdoiget|whatfeatures|어디|어느화면|어느페이지).*");
    }

    /** "为什么打不开", "没权限", "看不到", "点不了", "按钮是灰的", the platform's own "缺少操作权限：…", "怎么开通权限". */
    static boolean asksAboutAccess(String message) {
        return normalized(message).matches(".*(?:打不开|进不去|进不了|没权限|没有权限|无权限|无权|权限不够|权限不足|看不到|看不见|点不了|按不了|用不了"
                + "|是灰的|变灰|按钮灰|缺少操作权限|缺少权限|开通权限|开权限|申请权限|什么权限|哪个权限|哪些权限|哪项权限|需要权限"
                + "|accessdenied|nopermission|permission|cantopen|cannotopen|권한).*");
    }

    /** The user's words name permissions or a page that will not open, not just a button or a document that is stuck. */
    private static boolean asksAboutPermission(String message) {
        return normalized(message).matches(".*(?:权限|无权|打不开|进不去|进不了|accessdenied|permission|권한).*");
    }

    /**
     * A reply that tells the user what to click or where to go ("进入采购订货单页面点击新建", "1. 打开… 2. 点击…"), or that
     * claims the platform has no such thing: without a cited source such a reply is a guess. The names it quotes and the
     * menu paths it writes are checked against the sources by the navigation guard.
     */
    static boolean claimsStepsOrPlaces(String reply) {
        if (reply == null || reply.isBlank()) return false;
        String text = Normalizer.normalize(reply, Normalizer.Form.NFKC);
        return STEP_OR_PLACE.matcher(text).find() || NUMBERED_STEPS.matcher(text).results().count() >= 2;
    }

    private static final java.util.regex.Pattern STEP_OR_PLACE = java.util.regex.Pattern.compile("点击|点一下|点开|单击|点\\s*「"
            + "|进入.{0,12}(?:页面|页|菜单|模块|界面)|打开.{0,12}(?:页面|页|菜单|模块|界面)"
            + "|在.{1,16}(?:页面|菜单|模块|界面)(?:里|中|上|下)|菜单|入口|按钮|第[一二三四五六七八九十\\d]步"
            + "|平台上?(?:目前)?没有|系统(?:里|中)?(?:目前)?没有|没有这个功能|不支持这个功能|(?i:\\bclick\\b|\\bgo\\s+to\\b|\\bopen\\s+the\\b"
            + "|\\bmenu\\b|\\bbutton\\b)");
    private static final java.util.regex.Pattern NUMBERED_STEPS = java.util.regex.Pattern.compile("(?m)^\\s*\\d{1,2}[.、)]\\s*\\S");

    /** The question names colours ("红色是什么意思", "不同状态是什么颜色"): the page's legend answers it. */
    static boolean asksAboutColourWords(String message) {
        return normalized(message).matches(".*(?:颜色|什么色|哪种色|红色|黄色|绿色|蓝色|紫色|灰色|青色|青绿|品红|琥珀|橙色|底色|图例|标红|标黄"
                + "|变红|变黄|color|colour|legend|색).*");
    }

    /** The question asks what a word, status or message means ("待料是啥", "这个提示是什么意思"). */
    static boolean asksForMeaning(String message) {
        return normalized(message).matches(".*(?:是什么意思|什么意思|啥意思|意思是|代表什么|代表啥|含义|指的是|指什么|是啥|是什么|mean|meaning|뜻|의미).*");
    }

    /** The question is only about the current page's own text ("这个页面写了什么", "页面上的提示是什么"). */
    static boolean asksAboutPageText(String message) {
        return normalized(message).matches(".*(?:这个?页面?(?:上|里)?(?:的)?(?:提示|文字|内容)?(?:写|显示|说|提示)(?:了|的是)?(?:什么|啥)"
                + "|页面(?:上|里)?的?(?:提示|文字|内容|横幅|通知)(?:写|说)?(?:了|的是)?(?:什么|啥)|这个页面在说什么|这页在说什么"
                + "|whatdoesthispagesay|whatisonthispage).*");
    }

    /**
     * The user's own words for the topic of a question no rule covers ("让料是什么意思" gives "让料", "怎么报工" gives "报工",
     * "汇率谁来定" gives "汇率"), so a "not found" answer suggests a better question in the user's words; empty when no
     * short topic remains.
     */
    static String topic(String message) {
        if (message == null || message.length() > 2000) return "";
        String text = Normalizer.normalize(message, Normalizer.Form.NFKC).replaceAll("[\\s\\p{P}\\p{S}]+", "");
        text = text.replaceAll("请问|麻烦|帮我|帮忙|我想知道|我想问|想问一下|问一下|想问|你知道|请", "");
        text = text.replaceAll("是什么意思|什么意思|啥意思|是什么|是啥|指什么|代表什么|怎么办|怎么弄|怎么做|怎么填写|怎么填|怎么算|怎么操作"
                + "|怎么处理|怎么|如何|怎样|为什么|为啥|为何|谁来定|谁来|谁负责|谁审核|谁审|谁批|在哪里|在哪儿|在哪|哪里|哪个|哪些"
                + "|有没有|能不能|可不可以|可以吗|一下|还有|还剩|还够|够不够|够用|有货", "");
        text = text.replaceAll("(?:吗|呢|吧|啊|呀|嘛|了|的)+$", "");
        return text.matches("[\\p{IsHan}A-Za-z0-9]{2,8}") && text.codePoints().anyMatch(Character::isIdeographic) ? text : "";
    }

    private static final String REQUEST_MARKER ="帮我|帮忙|请(?!问)|麻烦|给我|替我|你来|直接|把|将";
    private static final String QUESTION_WORDS =
            "什么|哪些|哪个|哪一|哪里|哪儿|吗|么|呢|是否|有没有|要不要|怎么|如何|为什么|为何|多少|几个|几行";
    private static final java.util.regex.Pattern ENGLISH_REQUEST =
            java.util.regex.Pattern.compile("\\b(?:please|can you|could you|would you)\\b");
    private static final java.util.regex.Pattern ENGLISH_QUESTION = java.util.regex.Pattern.compile(
            "\\b(?:what|which|how|why|whether|is there|are there|do i|should i)\\b");
    /** Chinese verbs (matched on text without spaces) and English verbs (whole words) per action kind. */
    private static final java.util.Map<String, List<String>> OPERATION_VERBS = java.util.Map.of(
            "VIEW", List.of("筛选|过滤|只看|只显示|搜索|搜一下|查找|找出|定位|勾选|选中|选上|全选|取消勾选|取消选择|打开|点开|进入|展开",
                    "filter|search|find|select|tick|open|show only"),
            "FORM", List.of("改|设为|设成|设置|设定|填|写上|写成|录入|输入|换成|调成|调整|更新|确认|标记",
                    "set|change|update|fill|enter|edit|put|confirm|mark"),
            "SAVE", List.of("保存|存一下|存草稿|存成草稿", "save"),
            "SUBMIT", List.of("提交|送审|报审", "submit"));

    /**
     * ADR-150 deterministic gate: a page action may become a card only when the user's own words ask
     * for an operation of that kind. Page text, notices or recognized files never qualify, whatever the
     * model chose. A plain question ("有什么需要确认的") is not a request unless it says "帮我/请/把 ...".
     */
    static boolean requestsAction(String message, String kind) {
        List<String> verbs = OPERATION_VERBS.get(kind);
        if (verbs == null || message == null || message.length() > 2000) return false;
        String value = normalized(message);
        String words = Normalizer.normalize(message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        boolean verb = value.matches(".*(?:" + verbs.get(0) + ").*")
                || java.util.regex.Pattern.compile("\\b(?:" + verbs.get(1) + ")\\b").matcher(words).find();
        if (value.isEmpty() || !verb) return false;
        boolean marked = value.matches(".*(?:" + REQUEST_MARKER + ").*") || ENGLISH_REQUEST.matcher(words).find();
        boolean asks = value.matches(".*(?:" + QUESTION_WORDS + ").*") || ENGLISH_QUESTION.matcher(words).find()
                || message.contains("?") || message.contains("？");
        return marked || !asks;
    }

    /** Negation of a create request inside the same sentence ("不用帮我开单", "don't create a quotation"). */
    private static final java.util.regex.Pattern FORM_REFUSAL = java.util.regex.Pattern.compile(
            "(?:不要|不用|无需|别|勿|禁止|不能|不想|不需要|不再).{0,20}(?:创建|新建|生成|开|做|弄|整|填|订货|报价|报销|单据)");
    /** English negation needs its own pattern: the normalized form strips the spaces \b boundaries rely on. */
    private static final java.util.regex.Pattern ENGLISH_FORM_REFUSAL = java.util.regex.Pattern.compile(
            "\\b(?:don'?t|do not|never|no need to|stop)\\b.{0,20}(?:creat|mak|open|start|quot|sales ?order|expens|reimburse)");
    /** A question never opens a form; it is answered ("什么是订货单", "怎么创建报价单？"). */
    private static final java.util.regex.Pattern FORM_QUESTION = java.util.regex.Pattern.compile(
            "什么|哪些|哪个|哪里|怎么|如何|怎样|为什么|为啥|为何|多少|吗|呢|么|是否");

    /** One fillable form and how the user's own words ask for it (Chinese verbs then English verbs, ADR-163). */
    private record RequestedForm(String workflow, java.util.regex.Pattern asked, java.util.regex.Pattern askedInEnglish,
                                 java.util.regex.Pattern bareAsked) {
        boolean askedBy(String value) {
            return asked.matcher(value).find() || askedInEnglish.matcher(value).find()
                    || (bareAsked != null && bareAsked.matcher(value).find());
        }
    }

    /**
     * One create request, two verb+noun shapes: Chinese verbs (including a quantified 「来一张…」so plain 「来」
     * alone never fires, and 「开」 not right after 「打」 so "打开订货单" reads as viewing) before the noun with
     * at most 10 characters between; English verbs with at most 15. Bare 「订货/报价」 are not nouns here
     * ("整理一下报价" is not a request). Reimbursement is asked for with the word itself, so it also fires as
     * 「帮我报销 / 我要报销」 — a request marker plus the word, never a bare 「报销」 that a view request also
     * contains. Each form's Chinese alternation carries its own English noun too, so mixed words count.
     */
    private static RequestedForm form(String workflow, String nouns, String englishNouns) {
        return form(workflow, nouns, englishNouns, null);
    }

    private static RequestedForm form(String workflow, String nouns, String englishNouns, String bareNouns) {
        return new RequestedForm(workflow,
                java.util.regex.Pattern.compile("(?:创建|新建|生成|建|(?<!打)开|做|弄|整|填).{0,10}(?:" + nouns + ")"
                        + "|来(?:一|张|个|份|点).{0,8}(?:" + nouns + ")"),
                java.util.regex.Pattern.compile("(?:create|make|open|start).{0,15}(?:" + englishNouns + ")"),
                bareNouns == null ? null : java.util.regex.Pattern.compile(
                        "(?:帮我|帮忙|给我|我要|想|麻烦|请|来).{0,4}(?:" + bareNouns + ")"));
    }

    private static final List<RequestedForm> REQUESTED_FORMS = List.of(
            form("SALES_ORDER", "订货单|销售订单|salesorder", "salesorder"),
            form("SALES_QUOTE", "报价单|quotation|quote", "quotation|quote"),
            form("EXPENSE_CLAIM", "报销单|费用报销|expenseclaim|reimbursement", "expenseclaim|reimbursement",
                    "报销|费用报销"));

    /**
     * ADR-163 the form the user's own words ask to create (SALES_ORDER, SALES_QUOTE or EXPENSE_CLAIM), or null
     * when they did not name one or only asked about it: negation and questions never fire (Chinese and English),
     * the verb must come first, and two different workflows named at once stay unanswered by this path. Only the
     * user's own words count here; page, document or history text never triggers it.
     */
    static String requestedForm(String message) {
        if (message == null || message.length() > 2000 || formRequestBlocked(message)) return null;
        String value = normalized(message);
        if (value.isEmpty()) return null;
        String hit = null;
        for (RequestedForm candidate : REQUESTED_FORMS) {
            if (!candidate.askedBy(value)) continue;
            if (hit != null) return null;  // two workflows named: ambiguous, the model answers
            hit = candidate.workflow();
        }
        return hit;
    }

    /**
     * The guards a create request must pass in the user's own words, also re-checked when a remembered way of
     * asking repeats: its key carries no punctuation, so "创建订货单？" would otherwise collide with "创建订货单".
     */
    static boolean formRequestBlocked(String message) {
        if (message == null || message.length() > 2000) return true;
        if (message.contains("?") || message.contains("？")) return true;
        String value = normalized(message);
        if (FORM_REFUSAL.matcher(value).find() || FORM_QUESTION.matcher(value).find()) return true;
        String words = Normalizer.normalize(message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        return ENGLISH_FORM_REFUSAL.matcher(words).find() || ENGLISH_QUESTION.matcher(words).find();
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
