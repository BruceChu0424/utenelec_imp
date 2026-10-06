package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * ADR-153 deterministic scope gate on the user's own words, run before anything else: the assistant only
 * answers questions about using this platform, its business rules and the user's permitted business data.
 * A request to write or change code, reach a server or run commands, write or run SQL, read or change
 * files, logs or configuration, obtain secrets, internal addresses, the assistant's instructions or AI
 * configuration, or to switch the assistant's role is refused with a fixed reply: no model call, no
 * tool, no confirmation card.
 *
 * <p>The question is first folded into one canonical text (ADR-153 revision): compatibility forms (NFKC), invisible
 * format characters (zero-width spaces, joiners, bidirectional controls) removed, look-alike Cyrillic and Greek
 * letters folded to Latin, and the traditional characters of the trigger words folded to simplified ones.
 * Three views of that text are matched:
 * <ul>
 *   <li>{@code spaced}: lower case, punctuation as spaces. English and other Latin words are only ever matched as
 *       whole words ({@code \b}), so "standard price" never contains "rdp" and "SSH-100" (a product code, folded to
 *       a placeholder first) never means ssh;</li>
 *   <li>{@code compact}: the same text without the spaces that touch a Chinese, Japanese or Korean character, so
 *       "忽 略 之 前" reads "忽略之前" while Latin words stay apart; Chinese and Korean rules run here;</li>
 *   <li>{@code original}: case kept, for internal names typed by the user (StockService, stock_balances,
 *       /api/...) and dotted IP addresses.</li>
 * </ul>
 *
 * <p>Business words that share a trigger word are neutralized first ("客户代码", "模具代码", "错误代码",
 * "服务器状态页", "审计日志页", "密码锁", "客户数据库"). Words with an everyday business meaning only count in a
 * request shape: "凭证/证书/token" are never secrets by themselves, "代码" is code only with a programming verb,
 * "调试模式" only when the assistant is asked to switch into it, "重启系统后..." asks about an effect, not for a
 * restart. The password rules let "怎么修改我的登录密码" through while "管理员密码是多少" is refused. The platform's own
 * texts are read as business text: its permission codes ("缺少操作权限：sales_order:approve"), a field name inside an error
 * it showed, "实现原理/程序逻辑/计算逻辑" without a request for code, and what a figure on the server status page means;
 * a pasted internal error ("页面报错 NullPointerException") gets a fixed, helpful text. Page text,
 * knowledge and history are never classified here: they are data and cannot trigger anything (see the action and
 * tool gates in {@link AiChatJobHandler}).
 */
final class AiChatScopeGate {
    /**
     * Why a question is outside the assistant's scope (also the log category; never shown to the user).
     * {@code INTERNAL_ERROR} is a pasted internal error: answered with a fixed, helpful text, never sent to the model.
     */
    enum Category { CODE, SERVER, SQL, FILES, SECRETS, PROMPT, JAILBREAK, SECURITY, INTERNAL_ERROR }

    // ------------------------------------------------------------------ folding

    /** Traditional characters of the trigger vocabulary, paired with their simplified form. */
    private static final String TRADITIONAL_PAIRS = "碼码資资據据規规則则現现開开發发統统詞词語语腳脚術术數数變变環环誌志錄录權权"
            + "帳账號号戶户書书證证憑凭鑰钥網网執执運运務务機机會会話话問问題题輸输內内讀读員员擊击繞绕過过這这個个們们給给"
            + "說说寫写換换讓让為为麼么嗎吗對对關关閉闭啟启動动檔档設设節节點点擬拟應应該该後后臺台訊讯連连線线頁页顯显條条"
            + "項项類类別别產产稱称單单價价貨货訂订購购買买賣卖財财報报銷销審审準准備备編编製制廠厂區区屬属標标記记檢检驗验"
            + "質质歷历紀纪際际幫帮許许達达選选擇择實实經经營营業业計计劃划畫画進进鍵键盤盘腦脑電电軟软體体憶忆處处層层範范"
            + "圍围測测試试維维護护錯错誤误隱隐竊窃違违載载傳传遞递獲获閱阅從从請请將将聽听結结構构欄栏斷断鏈链雲云鎖锁錢钱"
            + "獎奖無无視视約约預预匯汇復复當当時时間间來来濾滤參参優优齊齐歸归響响頭头習习樣样態态雙双級级組组織织團团闆板"
            + "盜盗駭骇碟碟庫库裡里扮扮麼么嗎吗儲储儀仪務务";
    /** Traditional or regional words that the character folding alone does not turn into the trigger word. */
    private static final Map<String, String> REGIONAL_WORDS = regionalWords();
    /** Cyrillic and Greek letters that look like Latin ones ("ЅQL" is SQL). */
    private static final String LOOKALIKE_FROM = "АВЕКМНОРСТХЅІЈҮаеорсухѕіјԁԛԝѵӏΑΒΕΖΗΙΚΜΝΟΡΤΥΧαεικνορτυχ";
    private static final String LOOKALIKE_TO = "ABEKMHOPCTXSIJYaeopcyxsijdqwvlABEZHIKMNOPTYXaeikvoptux";
    private static final Map<Character, Character> FOLD = foldTable();
    /** A business code typed by the user ("SO-127001", "SH127001", "SSH-100", "A001"): never a technical word. */
    private static final Pattern CODE_TOKEN = Pattern.compile("(?<![a-z0-9])(?!(?:base|sha|utf|ipv|http|win|x)\\d)[a-z]{1,6}[-_]?\\d{2,}[a-z0-9_-]*(?![a-z0-9])");
    /** English business codes ("product code", "mold code", "HS code"): never source code. */
    private static final Pattern BUSINESS_CODE_EN = Pattern.compile("\\b(?:product|customer|client|item|goods|material|supplier|vendor|mold|mould"
            + "|colou?r|error|hs|zip|postal|tax|currency|country|warehouse|department|status|reason|order|document|bin|location|bar|qr"
            + "|discount|invoice|model|part|batch|lot|work\\s+order|contract|machine|equipment|swift|bank|style|size)\\s+(?:codes?|numbers?)\\b");

    // ------------------------------------------------------------------ neutralized business phrases (compact)

    private static final String BIZ_PREFIX = "客户|货品|物料|产品|商品|供应商|科目|部门|颜色|单位|仓库|库位|分类|海关|\\bhs|税收|税务|税则"
            + "|国家|地区|币种|货币|银行|行业|款式|型号|批次|条形|条码|订单|单据|工序|工艺|岗位|职位|员工|项目|费用|错误|报错|状态|原因"
            + "|区域|城市|省份|邮政|港口|运输|快递|物流|二维|激活|优惠|折扣|发票|税|模具|设备|机台|机器|工单|合同|材料|零件|部件|配件"
            + "|包装|托盘|班组|车间|产线|品牌|系列|规格|尺寸|样品|质检|检验|不良|缺陷|工装|治具|刀具|夹具|色号|料号|品号|货号|款号";
    /** "客户代码", "模具编码", "工单编号": business codes. */
    private static final Pattern BUSINESS_CODE = Pattern.compile("(?:" + BIZ_PREFIX + ")(?:代码|编码|编号|代号|码)");
    /** "客户的编码": business codes as well ("编码/编号" never mean source code). */
    private static final Pattern BUSINESS_CODE_OF = Pattern.compile("(?:" + BIZ_PREFIX + ")的(?:编码|编号|代号)");
    /** "订单的代码": a business code unless the sentence asks to write or change code ("订单的代码怎么改成不校验库存"). */
    private static final Pattern BUSINESS_CODE_OF_CODE = Pattern.compile("(?:" + BIZ_PREFIX + ")的代码");
    private static final Pattern PROGRAMMING_VERB = Pattern.compile("(?<![填书抄描])写|(?<![更])改|修复|调试|生成|重构|优化|开发|编程|\\breview\\b|审查");
    private static final Pattern BUSINESS_PHRASES = Pattern.compile("服务器状态页?|审计日志页?|操作日志页?"
            + "|系统日志页|登录日志|(?:导出|下载)(?:的)?(?:文件|表格|\\bexcel\\b|报表)|密码保护|加密导出|文件密码"
            + "|密码(?:锁|箱|柜|挂锁|盒|门|键盘)|指纹锁|(?:客户|货品|物料|产品|供应商|员工|商品|人员)(?:数据库|资料库)");

    // ------------------------------------------------------------------ jailbreak (compact, then spaced English)

    private static final String IGNORE = "(?<!我)(?<!我们)(?<!自己)(?<!他)(?<!她)(?:忽略|无视|忘记|忘掉|忘了|抛开|抛弃|丢掉|扔掉|不要管|别管"
            + "|不用管|绕开|绕过|跳过|解除|撤销|撤掉|放弃遵守|不再遵守|不用遵守|不必遵守|不要遵守|别遵守|违反|违背|突破|摆脱)(?:掉|了)?";
    private static final String QUALIFIER = "(?:之前|以上|上面|前面|先前|此前|原先|所有|全部|一切|系统|原来|原有|你的|你所有|这些|那些"
            + "|任何|平台|开发者|官方|预设|内置|默认)";
    private static final String STRONG_QUALIFIER = "(?:所有|全部|一切|系统|你的|你所有|平台|任何|原有|预设|默认|内置|开发者|官方)";
    private static final String RULE_WORD = "(?:规则|规定|指令|指示|提示词|提示语|约束|限制|安全策略|人设|守则|准则|原则|条款)";
    private static final String WEAK_RULE_WORD = "(?:要求|范围|身份|角色|提示|策略)";
    private static final String ROLE_WORD = "(?:开发者|开发人员|程序员|管理员|超管|超级管理员|黑客|系统管理员|\\broot|\\bdan\\b|没有(?:任何)?(?:限制|约束|规则)"
            + "|不受(?:任何)?(?:限制|约束)|无限制|\\bgpt|chatgpt|工程师|运维|\\blinux|终端|另一个\\bai\\b|别的\\bai\\b|其他\\bai\\b)";
    private static final Pattern JAILBREAK_ZH = Pattern.compile(String.join("|",
            IGNORE + QUALIFIER + "(?:里|中|上)?的?(?:所有|全部|一切)?的?" + RULE_WORD,
            IGNORE + STRONG_QUALIFIER + "(?:里|中|上)?的?(?:所有|全部|一切)?的?" + WEAK_RULE_WORD,
            "(?<!我)(?:忽略|无视|抛开|不要管|别管|不用管|不再遵守|不用遵守|不必遵守|不要遵守|别遵守|绕开|突破|摆脱|违反|违背)(?:掉|了)?"
                    + "(?:规则|约束|限制|指令|提示词|人设|安全策略|系统提示|守则)",
            "把" + QUALIFIER + "(?:里|中|上)?的?(?:所有|全部|一切)?的?(?:" + RULE_WORD + "|要求|身份|角色)(?:都|全|全部|统统|先|暂时)?"
                    + "(?:忘掉|忘了|忘记|忽略|无视|抛开|丢掉|扔掉|放一边|放在一边|放下|删掉|去掉|取消|解除|关掉|关闭|撤掉|不管|抛弃)",
            "(?:进入|切换到|切换成|切换为|切到|切成|开启|打开|启用|激活|变成|进到|转到|转为|转成|改成|改为|调成|以|处于|现在是|你是|进)(?:一个|一种)?"
                    + "(?:开发者|开发人员|开发|调试|上帝|管理员|超级管理员|超管|越狱|无限制|特权|\\broot|\\bdan\\b|\\bgod|\\bdebug|\\bdeveloper"
                    + "|\\badmin|\\bsudo|无审查|维护|无过滤|无约束|自由|运维|黑客)模式",
            "(?:开发者|上帝|越狱|无限制|无审查|无过滤|无约束|特权)模式|\\bdan\\b模式",
            "(?<!我)(?:你现在是|现在你是|你现在就是|你已经是|你将是|你将成为|你变成了?|你成为|你就是)(?:一个|一名|个|一位)?"
                    + "(?:开发|程序员|管理员|超级|超管|黑客|系统|\\broot|\\bdan\\b|没有|不受|无限制|自由|越狱|调试|运维|工程师|\\bgpt|chatgpt"
                    + "|\\blinux|终端|\\bshell|命令行|\\bbash|\\bcmd|控制台|\\bterminal|数据库|\\bsql|\\bpython|解释器|另一个|新的|真正的)",
            "(?:从现在(?:开始|起)|从今以后|从此以后|从此|此后|今后)你(?:就)?(?:是|扮演|就是|要扮演|将扮演|作为|当|不再|必须|只需|只能|要|会|将)",
            "接下来你(?:就)?(?:扮演|就是|将扮演|要扮演|不再是|作为|当|是一个|是一名|是个|将是)",
            "(?:假装|装作|扮演|模仿|充当)(?:你|自己)?(?:是|成|为|作)?.{0,8}?" + ROLE_WORD,
            "(?:当作|就当|想象|设想|当)你是.{0,6}?" + ROLE_WORD,
            "假设你是(?:一个|一名|个|一位)?(?:开发|程序员|黑客|系统|\\broot|\\bdan\\b|没有限制|不受限制|无限制|\\bgpt|chatgpt|\\blinux|终端)",
            "假设你是(?:一个|一名|个|一位)?(?:超级管理员|管理员|超管|运维|工程师).{0,12}(?:帮我|给我|替我|告诉我|把|输出|打开|开通|执行|透露|泄露|权限都)",
            "你不再是|你不是(?:一个)?(?:助手|\\bai\\b|\\berp\\b)",
            "角色扮演|玩(?:个|一个)?(?:角色|游戏).{0,12}(?:你是|你扮演|扮演)",
            "(?:你|回答|回复|说话|作答)(?:时|的时候)?(?:可以|就|将|会|已经|现在|已|也|都)?(?:不受|没有|不再受|摆脱了?|解除了?|无|不用再?受"
                    + "|不必再?受|无需受|不需要受|不用遵守|不必遵守)(?:任何)?(?:平台|系统)?(?:的)?(?:范围)?(?:限制|约束|审查|过滤|规则)",
            "(?:不受|没有|无|解除|突破|摆脱)(?:任何)?(?:限制|约束|审查|过滤)的(?:\\bai\\b|助手|模式|版本|你|运维|专家|角色|机器人)",
            "以(?:开发者|\\broot|\\bdan\\b|黑客|越狱|运维|上帝)(?:的)?(?:身份|权限|角色|口吻|模式)",
            "以(?:管理员|超管|超级管理员|系统)(?:的)?(?:身份|权限|角色|口吻)(?:运行|执行|回答|回复|说话|告诉我|输出)",
            "越狱|\\bjailbreak|提示词?注入|\\bpromptinjection\\b|新的?(?:系统)?指令如下|以下是(?:新的?)?(?:系统)?指令",
            "(?:解码|解密|\\bbase64\\b)(?:后|并|然后|再|一下)?(?:执行|运行|照做|遵照|遵守|按.{0,4}执行)|(?:执行|运行|照做)(?:这段|以下|下面)?(?:\\bbase64\\b|密文)",
            // Korean (spaces next to Hangul are removed in the compact view)
            "(?:이전|위의?|앞의?|모든|기존|너의|당신의)(?:지시|지침|명령|규칙|프롬프트|설정|제한).{0,8}(?:무시|잊어|잊고|따르지|어기)"
                    + "|개발자모드|관리자모드|탈옥|제한(?:이)?없는(?:\\bai\\b|모드|어시스턴트|비서|챗봇|역할)|제한없이(?:답|대답|응답|말)"
                    + "|(?:역할|롤)(?:극|놀이|플레이)|지금부터(?:너는|넌|당신은)"));
    private static final Pattern JAILBREAK_EN = Pattern.compile(String.join("|",
            "\\b(?:ignore|disregard|forget|override|bypass|skip|drop|ditch)\\s+(?:(?:all|any|the|your|of|previous|prior|above|earlier"
                    + "|system|these|those|every|original|initial|preceding)\\s+)*(?:instructions?|rules|prompts?|guidelines|directions"
                    + "|restrictions|filters|safety|constraints|limits|limitations|programming|policies|guardrails|directives)\\b",
            "\\b(?:ignore|disregard|forget)\\s+(?:(?:all|everything|anything|of|the)\\s+)*(?:above|before|prior|preceding"
                    + "|previous\\s+messages?)\\b",
            "\\byou\\s+are\\s+now\\b",
            "\\b(?:you\\s+are|you\\s+re|act\\s+as|pretend\\s+to\\s+be|play\\s+the\\s+role\\s+of|respond\\s+as|answer\\s+as|behave\\s+as"
                    + "|roleplay\\s+as)\\s+(?:a\\s+|an\\s+)?(?:developer|admin|administrator|root|hacker|system|unrestricted|uncensored"
                    + "|unfiltered|jailbroken|evil|dan|linux|terminal|shell|another|different)\\b",
            "\\bpretend\\s+(?:to\\s+be|you\\s+are)\\b|\\brole\\s?play\\b",
            "\\b(?:developer|debug|god|admin|jailbreak|dan|sudo|maintenance|unrestricted|unfiltered|unlocked)\\s+mode\\b|\\bjailbr(?:eak|oken)",
            "\\b(?:you|assistant|ai|bot|chatbot|model|that|who)\\s+(?:\\w+\\s+){0,3}?(?:has|have|answer|answers|respond|reply|talk|speak"
                    + "|act|behave|operate|are|re|is)\\s+(?:\\w+\\s+)?(?:no|without(?:\\s+any)?)\\s+(?:restrictions?|limits|limitations"
                    + "|filters?|rules|censorship|guardrails|boundaries)\\b",
            "\\b(?:answer|respond|reply)\\s+(?:freely|without\\s+(?:any\\s+)?(?:filters?|restrictions?|limits|rules|censorship))\\b",
            "\\bnew\\s+(?:system\\s+)?instructions\\b|\\bsystem\\s+override\\b",
            "\\bfrom\\s+now\\s+on\\b.{0,60}?\\b(?:you\\s+are|you\\s+re|act\\s+as|respond\\s+as|answer\\s+as|behave\\s+as|pretend|play|ignore"
                    + "|forget|have\\s+no|has\\s+no)\\b",
            "\\b(?:decode|base64)\\b.{0,30}?\\b(?:execute|run|follow|obey)\\b",
            "\\blet\\s?s\\s+play\\s+a\\s+game\\b.{0,60}?\\byou\\s+(?:are|re)\\b"));

    // ------------------------------------------------------------------ the assistant's own instructions and configuration

    private static final Pattern PROMPT_ZH = Pattern.compile(String.join("|",
            "系统提示词|系统指令|初始指令|原始指令|隐藏指令|内部指令|底层指令|隐藏(?:的)?(?:规则|设定|说明|提示|指令)|\\bsystemprompt\\b",
            "你的(?:系统)?(?:指令|提示词|设定|人设|守则|准则|限制|配置|上下文|初始设置|底层设置)",
            "你(?:这次|本次|最开始|最初|一开始|刚才|之前|开头|刚开始)?(?:收到|拿到|得到|看到|接收到?|被给予|被告知)的(?:那段|那些|这段|完整|全部"
                    + "|所有|原始|最初|最开始)?的?(?:上下文|指令|提示|说明|内容|消息|文字|资料|话|英文|规则|要求|设定|\\bsources\\b|\\btools\\b)",
            "开头(?:那段|的那段)(?:英文)?(?:说明|话|文字|指令|内容)",
            "(?:重复|复述|输出|打印|泄露|透露|列出|发|给)(?:一下)?(?:我)?(?:你)?(?:的)?(?:最开始|最初|开头|系统)(?:的)?(?:内容|话|文字|指令|消息|说明|提示)",
            "(?:输出|打印|泄露|透露)(?:一下)?(?:你)?(?:上面|以上|前面|之前)(?:的)?(?:所有|全部|完整)(?:的)?(?:内容|话|文字|指令|消息)",
            "你(?:的)?(?:回答|回复|作答|工作|说话)?(?:时|的时候)?(?:必须|需要|要|得|应该|应当)?(?:遵守|遵循|遵照|执行|服从)的.{0,8}?"
                    + "(?:规则|规定|要求|指令|限制|原则|条)",
            "你的?(?:回答|回复|作答)(?:规则|规定|原则|守则)",
            "你(?:是|用的是|使用的是|基于|调用的是|接的是|接入的是|背后是|底层是|底层用的是?)(?:什么|哪个|哪家|哪一个|哪种)(?:公司的?)?"
                    + "(?:模型|大模型|\\bai\\b|服务商|厂商|接口|版本|技术|框架)",
            "你(?:是|由)(?:哪家|哪个|什么)(?:公司|团队|厂商)(?:开发|做|训练|研发|提供)",
            "底层(?:用的|使用|采用|是|用了)?(?:什么|哪个|哪种|哪家)?(?:技术|模型|框架|架构|大模型)",
            "你(?:是|用的是)(?:\\bgpt|chatgpt|claude|\\bglm|智谱|deepseek|通义|千问|qwen|文心|kimi|豆包|gemini)",
            "(?:\\bai\\b|大模型|ai模型|ai助手)(?:服务)?的?(?:配置|密钥|\\bkey\\b|服务商|厂商|地址|接口|参数|温度|模型名|型号|版本|提供商)",
            "(?:智谱|\\bglm\\b|deepseek|openai|chatgpt|claude|通义|千问|qwen|文心|kimi|豆包|gemini).{0,6}(?:配置|密钥|\\bkey\\b|地址|接口|参数"
                    + "|模型名|账号|额度)",
            "你(?:能|可以|会)?(?:调用|使用|用)(?:哪些|什么|的)(?:工具|函数|插件|接口|\\bfunctions?\\b|\\btools?\\b)",
            "(?:列出|输出|告诉我|给我|说出)(?:一下)?(?:你的?|你能用的|你可以用的)(?:所有|全部)?(?:可用的?)?(?:工具|函数|插件|\\btools?\\b|\\bfunctions?\\b)",
            "(?:工具|函数)(?:名|名称)(?:和|及|与)参数|\\bsources\\b.{0,8}\\btools\\b|\\btools\\b.{0,8}\\bsources\\b",
            "意图(?:列表|清单)|你的?意图(?:有哪些|分为|包括)|\\bti\\s?shi\\s?ci\\b",
            "시스템프롬프트|프롬프트|(?:숨겨진|내부|초기)(?:지시|규칙|설정|명령)|(?:지시사항|지침)(?:을|를)?(?:보여|알려|출력)"));
    /** "原样/逐字 ..." asks for the instructions only next to a word naming them. */
    private static final Pattern VERBATIM_ASK = Pattern.compile("(?:原样|逐字|一字不差地?|完整地?)(?:发|输出|给|告诉|打印|复述|重复|贴|显示|翻译|列出)");
    private static final Pattern PROMPT_CONTEXT = Pattern.compile("你|上面|以上|前面|开头|最开始|系统|上下文|指令|提示|收到");
    private static final Pattern PROMPT_EN = Pattern.compile(String.join("|",
            "\\bsystem\\s+(?:prompt|message|instructions?)\\b",
            "\\b(?:your|the)\\s+(?:initial|original|hidden|secret|internal|system)\\s+(?:prompt|instructions?|message|rules|guidance|guidelines)\\b",
            "\\byour\\s+(?:instructions|prompt|configuration|system\\s+message|guidelines|programming)\\b|\\binitial\\s+prompt\\b",
            "\\b(?:repeat|print|output|show|write|copy|echo|reproduce|reveal|dump|display|translate|summari[sz]e)\\s+(?:me\\s+)?(?:back\\s+)?"
                    + "(?:everything|all|anything|the\\s+text|the\\s+content|what\\s+(?:is|was|comes)|the\\s+words)\\s+(?:written\\s+"
                    + "|that\\s+(?:is|was|came)\\s+)?(?:above|before|prior)\\b",
            "\\bverbatim\\b.{0,40}?\\b(?:above|prompt|instructions|everything|you\\s+are)\\b|\\bstarting\\s+(?:from|with)\\s+you\\s+are\\b",
            "\\bwhat\\s+(?:were|was|have)\\s+you\\s+(?:been\\s+)?(?:told|instructed|given|programmed)\\b"
                    + "|\\bbefore\\s+(?:this|our|my)\\s+(?:conversation|chat|message|first\\s+message)\\b|\\byou\\s+were\\s+given\\b"
                    + "|\\bhidden\\s+(?:guidance|instructions|prompt|rules)\\b|\\blist\\s+of\\s+intents\\b",
            "\\bwhat\\s+(?:llm|ai\\s+model|model|language\\s+model)\\s+(?:are\\s+you|do\\s+you\\s+use|powers\\s+you|is\\s+behind)\\b"
                    + "|\\bwhich\\s+(?:ai\\s+|language\\s+|llm\\s+)?model\\s+(?:are\\s+you|do\\s+you\\s+use|powers|is\\s+behind|runs\\s+you)\\b"
                    + "|\\bare\\s+you\\s+(?:gpt|chatgpt|claude|glm|gemini|deepseek|qwen)\\b",
            "\\b(?:ai|model|llm)\\s+(?:configuration|config|provider|api\\s+key)\\b",
            "\\b(?:list|show|print|tell\\s+me|what\\s+are)\\s+(?:me\\s+)?(?:all\\s+|every\\s+)?(?:of\\s+)?(?:your\\s+|the\\s+)?(?:tools?|functions?"
                    + "|tool\\s+names?)\\s+(?:you\\s+(?:can\\s+)?(?:call|use|have)|available)\\b|\\bevery\\s+tool\\b|\\btools?\\s+you\\s+can\\s+call\\b"
                    + "|\\bjson\\s+parameters\\b",
            "\\b(?:json|output)\\s+(?:fields|format|schema|keys)\\s+(?:are\\s+)?you\\b|\\byou\\s+(?:are\\s+)?required\\s+to\\s+(?:return|output"
                    + "|follow|answer)\\b|\\brules\\s+you\\s+(?:must\\s+)?(?:follow|obey|were\\s+given)\\b"));

    // ------------------------------------------------------------------ security bypass

    private static final Pattern SECURITY_ZH = Pattern.compile("黑客|入侵|渗透测试|\\bsql\\b注入|注入攻击|安全漏洞|系统漏洞|漏洞利用|找漏洞|挖漏洞|提权"
            + "|越权(?:访问|操作|查看)|破解(?:密码|系统|软件|版|账号)|暴力破解|爆破密码|木马|系统后门|留后门|抓包"
            + "|绕过(?:权限|登录|验证|认证|鉴权|安全|风控|审计|密码|验证码|审核记录)|篡改(?:数据库|日志|审计|记录)|攻击(?:系统|服务器|网站)"
            + "|해킹|해커|취약점|보안(?:우회|을우회)");
    private static final Pattern SECURITY_EN = Pattern.compile("\\b(?:hack|hacking|exploit|vulnerabilit(?:y|ies)|sql\\s+injection|xss|csrf"
            + "|privilege\\s+escalation|backdoor|malware|brute\\s*force)\\b|\\bcrack\\s+(?:the\\s+|a\\s+)?password|\\bbypass\\s+(?:the\\s+)?"
            + "(?:login|authentication|permission|permissions|security)\\b");

    // ------------------------------------------------------------------ secrets and internal addresses

    private static final String SECRET_NOUN = "(?:密码|口令|密钥|私钥|秘钥|令牌|授权码|\\bcookies?\\b|会话\\bid\\b|\\bsessionid\\b|\\bjwt\\b|\\bapikey\\b"
            + "|\\bsecretkey\\b|\\baccesskey\\b|\\bapi\\s?key\\b|\\bsecret\\s?key\\b|\\baccess\\s?key\\b)";
    /** A system's secrets: its password, key, token, certificate or connection string. */
    private static final Pattern SYSTEM_SECRET = Pattern.compile("(?:数据库|服务器|后台|后端|阿里云|腾讯云|智谱|接口|邮件服务器?|路由器|网关|\\bai\\b服务|大模型)"
            + "(?:的|账号的|账户的)?.{0,4}?(?:密码|口令|密钥|私钥|秘钥|令牌|\\btoken\\b|\\bkey\\b|\\bcookie\\b|连接串|连接字符串)"
            + "|(?:数据库|服务器|阿里云|腾讯云|智谱|邮件服务器?|网关|\\bai\\b服务)(?:的)?(?:凭证|凭据|证书)"
            + "|\\b(?:root|ssh|redis|db|jwt|oss|ai|api|smtp|vpn|wifi|nas|git|github|server|database|mysql|postgres|pg)\\b\\s?(?:的|账号的|账户的"
            + "|服务的?|服务器的?|账号|账户)?\\s?(?:\\bapi\\b\\s?)?(?:密码|口令|密钥|私钥|秘钥|令牌|凭证|证书|\\btoken\\b|\\bkey\\b|\\bcookie\\b"
            + "|\\bpassword\\b|\\bsecret\\b)");
    /** Someone else's password, key or token. */
    private static final Pattern PERSON_SECRET = Pattern.compile("(?:管理员|超管|超级管理员|\\badmin\\b|别人|他人|同事|其他人|其它人|老板|员工|用户|所有人"
            + "|全部用户|邮箱)(?:的|账号的|账户的)?.{0,4}?(?:密码|口令|密钥|私钥|秘钥|令牌|\\btoken\\b|\\bcookie\\b)");
    /** A secret's value asked for: "密码是多少", "把密钥发我", "告诉我令牌". */
    private static final Pattern SECRET_VALUE = Pattern.compile(SECRET_NOUN + "(?:是多少|是什么|多少|发我|发给我|给我|告诉我|拿来|在哪|在哪里|存在哪"
            + "|放在哪|明文)|(?:给我|告诉我|发我|发给我|查一下|查看|看看|导出|拿到|获取|提供|列出|泄露|透露|破解|猜|还原|解密)(?:一下)?"
            + "(?:你的|系统的|他的|她的|别人的|所有|全部|的)?.{0,6}?" + SECRET_NOUN);
    private static final Pattern SECRET_HELP = Pattern.compile("(?:怎么|如何|怎样)(?:给|帮|为|替|找|让|请)?.{0,6}(?:重置|找回)(?:一下)?(?:我的|他的|她的|员工的|自己的)?"
            + "(?:登录)?(?:密码|口令)|(?:怎么|如何|怎样|在哪|哪里|去哪|想要|要)(?:里|儿)?(?:修改|改|重置|找回|设置|设|更换|换|更新)"
            + "(?:一下)?(?:我的|自己的)?(?:登录)?(?:账号)?(?:的)?(?:密码|口令)|忘记(?:了)?(?:我的)?(?:登录)?密码|密码(?:忘了|忘记了|过期|错误|输错|锁定|被锁"
            + "|不对|规则|要求|强度|多长|几位|有效期|怎么改|怎么设|怎么修改|如何修改|在哪改)|初始密码(?:怎么|如何)?(?:改|修改)|改密码|修改密码|重置密码");
    private static final Pattern SECRET_EN = Pattern.compile("\\b(?:api|secret|access|private|ssh|db|database|admin|root|jwt|signing|encryption"
            + "|server)\\s+(?:keys?|tokens?|passwords?|secrets?|credentials?)\\b|\\b(?:access|refresh|bearer|auth|session|jwt|github)\\s+tokens?\\b"
            + "|\\b(?:password|passwd|passcode|credentials?|cookies?|session\\s+id|private\\s+key|secret\\s+key|api\\s+key)\\b");
    private static final Pattern SECRET_HELP_EN = Pattern.compile("\\b(?:how\\s+(?:do|can|should)\\s+i|where\\s+(?:do|can)\\s+i|i\\s+want\\s+to"
            + "|i\\s+need\\s+to|can\\s+i)\\s+(?:change|reset|update|set|recover|modify)\\s+(?:my\\s+)?(?:own\\s+)?(?:login\\s+|account\\s+|user\\s+)?"
            + "password\\b|\\bforgot\\s+(?:my\\s+)?(?:login\\s+)?password\\b|\\bpassword\\s+(?:rules|policy|expired|requirements|reset)\\b"
            + "|\\b(?:change|reset)\\s+(?:my\\s+)?(?:own\\s+)?(?:login\\s+)?password\\b"
            + "|\\bpassword\\s+(?:is\\s+)?(?:wrong|incorrect|not\\s+working|locked|expired|invalid)\\b"
            + "|\\b(?:wrong|incorrect|locked|forgotten|expired)\\s+password\\b|\\blocked\\s+out\\b");
    private static final Pattern SECRET_ASK_EN = Pattern.compile("\\b(?:what|give|show|tell|reveal|dump|get|list|send|crack|leak|find|is|print|share)\\b");
    private static final Pattern SECRET_KO = Pattern.compile("(?:서버|데이터베이스|디비|\\bdb\\b|관리자|다른사람|\\bapi\\b|\\bai\\b).{0,8}(?:비밀번호|암호|패스워드|키|토큰)"
            + "|(?:비밀번호|암호|패스워드)(?:가|는|를|좀)?(?:뭐|무엇|알려|보여|말해)");
    private static final Pattern SECRET_HELP_KO = Pattern.compile("변경|바꾸|바꿔|재설정|잊어|잊었|분실|초기화|찾기");
    private static final Pattern SECRET_PINYIN = Pattern.compile("\\bmi\\s?(?:ma|yao)\\b");
    private static final Pattern SECRET_PINYIN_ASK = Pattern.compile("\\b(?:shu\\s?ju\\s?ku|fu\\s?wu\\s?qi|guan\\s?li\\s?yuan|duo\\s?shao|shi\\s?shen\\s?me"
            + "|gei\\s?wo|gao\\s?su\\s?wo)\\b");
    private static final Pattern ADDRESS_ZH = Pattern.compile("(?:服务器|数据库|后端|后台|内网|接口|\\bapi\\b|\\bai\\b服务|网关|\\bnas\\b|主机|\\bredis\\b|\\boss\\b"
            + "|大模型)(?:的)?(?:\\bip\\b|地址|域名|端口|连接串|连接字符串|\\burl\\b|\\bhost\\b|主机名|内网地址|公网地址)|\\bip\\b地址|\\bip\\b是多少|端口号"
            + "|内网\\bip\\b|公网\\bip\\b|内网地址|公网地址|\\bjdbc\\b|\\blocalhost\\b|서버(?:의)?(?:주소|아이피|\\bip\\b|포트)");
    private static final Pattern ADDRESS_EN = Pattern.compile("\\b(?:server|database|db|backend|internal|host)\\s+(?:ip|address|url|host|port"
            + "|hostname)\\b|\\bip\\s+address\\b|\\bconnection\\s+string\\b|\\bjdbc\\b|\\blocalhost\\b");
    private static final Pattern DOTTED_IP = Pattern.compile("(?<![\\d.])(?:\\d{1,3}\\.){3}\\d{1,3}(?![\\d.])");

    // ------------------------------------------------------------------ SQL and the database

    private static final Pattern SQL_ZH = Pattern.compile(String.join("|",
            "存储过程|触发器|(?:创建|建立|新建|建)(?:一张|张|一个|个)?(?:数据库|数据)表|建表语句|建表脚本|数据库表|(?:数据库|数据)表结构"
                    + "|表结构(?:设计|定义|语句)|查询语句|标准查询语言|结构化查询语言|查询语言(?:的)?写法|表名(?:和|及|与)?字段名|数据库迁移|迁移脚本",
            "\\b(?:sql|psql|mysql|postgres|postgresql|pgadmin|navicat|dbeaver|flyway|plsql)\\b",
            "\\b(?:select|insert|update|delete|drop|alter|truncate)\\b\\s?(?:语句|命令)",
            "数据库.{0,6}?(?:连接|登录|登陆|进入|进去|密码|账号|地址|端口|表|字段|结构|执行|运行|修改|删除|删|写入|插入|备份|恢复|还原|导出|导入"
                    + "|\\bdump\\b|权限|用户名|直接查|直接改|里改|里删|里查|操作|清空|名称|名字|\\bschema\\b)|(?:直接|去|帮我)(?:查|改|删|操作|清空|连|登录|进入)"
                    + "(?:一下)?数据库",
            "(?:后台|后端|数据库|服务器|系统)(?:里|中|上)?(?:是)?(?:存|存在|保存|保存在|放在|存储|存储在|记录在|记在|对应)(?:哪|那|什么)(?:张|个|一张)?"
                    + "(?:表|字段|库)",
            "쿼리.{0,6}(?:작성|짜|만들)|데이터베이스.{0,6}(?:접속|테이블|스키마)"));
    private static final Pattern SQL_EN = Pattern.compile("\\bsql\\b|\\binsert\\s+into\\b|\\bupdate\\s+[a-z_]+\\s+set\\b|\\bdelete\\s+from\\s+"
            + "(?!the\\b|a\\b|my\\b|this\\b|that\\b|list\\b)[a-z_]|\\bdrop\\s+(?:table|database)\\b|\\balter\\s+table\\b|\\bcreate\\s+table\\b"
            + "|\\btruncate\\s+table\\b|\\bdatabase\\s+(?:password|user|schema|table|tables|dump|backup|connection|name|server|host)\\b|\\bschema\\b"
            + "|\\bstored\\s+procedure\\b");
    /** A SELECT statement (on the lower-case text with its punctuation). "select items from the list" is not one. */
    private static final Pattern SQL_SELECT = Pattern.compile("\\bselect\\s+(?:\\*|distinct\\b|top\\s+\\d)"
            + "|\\bselect\\b[^\\n]{0,60}?\\b(?:count|sum|max|min|avg)\\s*\\("
            + "|\\bselect\\b[^\\n]{1,120}?\\bfrom\\s+\\S+\\s*(?:where|join|group\\s+by|order\\s+by|limit|having|;|$)");

    // ------------------------------------------------------------------ servers and commands

    private static final String NOT_AN_EFFECT = "(?!后|以后|之后|时|的时候|期间|过程|会|了吗|吗|是否|还)";
    /** "进程" as an operating-system process; "生产进程/审批进程" is business progress. */
    private static final String PROCESS = "(?<!生产|工作|业务|审批|项目|制造|采购|销售|订单|交货)进程";
    private static final Pattern SERVER_ZH = Pattern.compile(String.join("|",
            "\\bshell\\b命令|\\bshell\\b脚本|命令行|命令提示符|远程桌面|远程登录|远程连接|远程控制|向日葵|宝塔面板|内网穿透|端口映射"
                    + "|防火墙(?:规则|端口|设置|配置)|终端(?:里|中|上)?(?:执行|运行|输入|敲)|打开终端|\\broot\\b权限",
            "服务器.{0,8}?(?:登录|登陆|连接|连上|进入|进去|上去|远程|命令|执行|运行|重启|关机|关闭|停止|停掉|启动|开机|部署|安装|卸载|删除|删|修改|改|配置"
                    + "|文件|日志|目录|密码|账号|权限|\\broot\\b|地址|端口|备份|脚本|进程|装|清理|几台|规格|型号)" + NOT_AN_EFFECT,
            "(?:登录|登陆|连接|连上|进入|进去|远程|重启|关闭|部署到|操作|控制|入侵|攻击|黑进|访问|\\bssh\\b|登|进)(?:一下|到|进|进入)?(?:你的|公司的|我们的"
                    + "|这台|那台|后台的?)?服务器",
            "(?:执行|运行|跑|输入|敲)(?:一下|一个|这个|这条|以下|下面|如下|这些)?(?:的)?(?:命令|\\bshell\\b|\\bcmd\\b|批处理)",
            "(?:重启|关闭|关掉|停掉|停止|启动|升级|回滚|部署|发版|上线|重装)(?:一下|下)(?:系统|服务|后端|前端|后台|数据库|服务器|网站|应用|\\berp\\b|平台)",
            "(?:重启|关闭|关掉|停掉|停止|启动|回滚|部署|重装|重新部署|重新安装)(?:后端|后台|数据库|服务器|前端服务|后端服务|后台服务|\\bnginx\\b|\\btomcat\\b"
                    + "|\\bdocker\\b|容器)" + NOT_AN_EFFECT,
            "(?:帮我|请你?|你来|给我|替我|麻烦你?|你去|你帮我)(?:把)?(?:系统|服务|后端|后台|数据库|服务器|网站|平台)?(?:重启|关闭|关掉|停掉|升级|回滚|部署"
                    + "|发版|上线|发个版|重装)",
            "部署在(?:哪|什么)|(?:几|多少)台服务器|哪家云|云服务器|怎么部署的|部署(?:方式|架构|流程|步骤)",
            "备份(?:文件)?(?:放在|存在|存放|保存在|在)(?:哪|什么地方)|多久备份|备份(?:策略|周期|频率|机制)|数据(?:怎么|如何)备份",
            PROCESS + "(?:号|\\bid\\b|列表)|(?:结束|杀掉|杀死|杀|关掉|关闭|清理|\\bkill\\b)(?:掉)?(?:这个|那个|占用的?)?" + PROCESS
                    + "|(?:占|占用)(?:了)?(?:内存|\\bcpu\\b)的(?:进程|程序)|" + PROCESS + ".{0,6}?(?:结束|杀|关掉|清理)|端口(?:被)?占用|占用(?:了)?\\d*端口"
                    + "|\\d{2,5}端口|磁盘(?:空间|还剩|剩余|占用|满了|使用率|容量)"
                    + "|任务管理器",
            "\\b(?:linux|ubuntu|centos|debian|macos)\\b(?:系统)?(?:下|上|里|中)?(?:怎么|如何)?(?:查看|查|看|执行|运行|设置|配置|清理|删除|杀|关闭|结束|安装)"
                    + "|\\bwindows\\b(?:系统)?(?:下|上|里|中)(?:怎么|如何)?(?:查看|查|看|执行|运行|清理|删除|杀|结束)",
            "서버.{0,8}(?:접속|로그인|연결|재시작|재부팅|명령|배포|들어가)|명령어?(?:실행|입력)|터미널|도커|재부팅"));
    private static final Pattern SERVER_EN = Pattern.compile(String.join("|",
            "\\b(?:ssh|bash|powershell|pwsh|docker|kubectl|kubernetes|k8s|systemctl|journalctl|sudo|chmod|chown|crontab|nginx|tomcat|rdp|ftp|sftp"
                    + "|scp|putty|xshell|winscp|teamviewer|todesk)\\b",
            "\\bshell\\s+(?:command|script|access)\\b|\\bcommand\\s+line\\b|\\bremote\\s+desktop\\b|\\brm\\s+rf\\b|\\bcmd\\s+exe\\b",
            "\\b(?:log\\s*in(?:to)?|login\\s+to|connect\\s+to|hack\\s+into|reboot|restart|shut\\s*down|deploy\\s+to|ssh\\s+into|get\\s+into)\\s+"
                    + "(?:the\\s+|your\\s+|our\\s+|a\\s+|this\\s+)?(?:server|servers|backend|database|host|vps|instance)\\b"
                    + "(?!\\s+(?:status|state|monitor|page|room|report))",
            "\\b(?:restart|reboot|stop|start|kill)\\s+(?:the\\s+)?(?:app|application|service|backend|server|process)\\s+on\\s+the\\s+"
                    + "(?:host|server|machine)\\b",
            "\\b(?:run|execute)\\s+(?:a\\s+|the\\s+|this\\s+|these\\s+|following\\s+|my\\s+|some\\s+)?(?:command|commands|script|shell)\\b",
            "\\b(?:get|open|obtain)\\s+(?:a\\s+|an\\s+)?(?:terminal|shell|console)\\b|\\bmachine\\s+running\\b",
            "\\btail\\s+(?:f\\s+)?(?:the\\s+)?(?:backend|server|log|logs|output|app)\\b",
            "\\b(?:which|what)\\s+(?:process|program)\\s+(?:is\\s+)?(?:using|occupies|holding|uses)\\s+(?:port|the\\s+port)\\b|\\bdisk\\s+(?:space|usage)\\b"
                    + "|\\bkill\\s+(?:the\\s+)?process\\b",
            "\\bwhere\\s+is\\s+(?:the\\s+)?(?:platform|system|erp|app)\\s+(?:deployed|hosted)\\b|\\bhow\\s+many\\s+servers\\b|\\bwhich\\s+cloud\\b"));

    // ------------------------------------------------------------------ files, logs and configuration

    private static final Pattern FILES_ZH = Pattern.compile(String.join("|",
            "日志文件|(?:系统|服务器|后端|后台|程序|应用|服务|数据库|\\bnginx\\b|\\btomcat\\b)(?:的)?(?:错误|运行|访问|应用|程序|报错|启动)?日志|日志目录"
                    + "|\\blog\\b文件|\\bcatalina\\b|配置文件|环境变量|\\bapplication\\s?(?:yml|yaml|properties)\\b|\\benv\\b文件|文件系统|磁盘文件|源文件"
                    + "|安装目录|部署目录|上传目录|\\bjar\\b(?:文件|包)|系统文件|根目录|\\betc\\b目录|\\bvar\\b目录",
            "(?:读|读取|打开|查看|看|看看|发|给我|下载|修改|改|写|写入|删除|删|上传|列出|搜索|找)(?:一下)?(?:服务器|后端|程序)(?:上|里|中)?(?:的)?"
                    + "(?:文件|日志|配置|目录)|(?:后端|服务器|程序|数据库|\\bnginx\\b)(?:的)?配置",
            "로그파일|설정파일|환경변수"));
    private static final Pattern FILES_EN = Pattern.compile("\\b(?:log\\s+files?|server\\s+logs?|system\\s+logs?|config(?:uration)?\\s+files?"
            + "|environment\\s+variables?|env\\s+vars?|file\\s*system|backend\\s+(?:logs?|output|console))\\b|\\benv\\s+file\\b"
            + "|\\bapplication\\s+(?:yml|yaml|properties)\\b|\\b(?:read|open|cat|tail|edit|modify|delete|list)\\s+(?:the\\s+|a\\s+|all\\s+)?"
            + "(?:server|system|backend)\\s+(?:files?|logs?|config)\\b");
    private static final Pattern FILES_RAW = Pattern.compile("(?<![\\w.])\\.env\\b");

    // ------------------------------------------------------------------ code

    private static final Pattern CODE_ZH = Pattern.compile(String.join("|",
            "源码|源代码|源程序|伪码|伪代码|正则表达式|正则|宏代码|代码块|代码片段|代码段|示例代码|代码示例|实现代码|后端代码|前端代码|系统代码|平台代码"
                    + "|二次开发|\\bstacktrace\\b|\\btraceback\\b|空指针|堆栈|\\bvba\\b|批处理|\\bbat\\b(?:批处理|脚本|文件)|\\bshell\\b脚本"
                    + "|变量名|函数名|方法名|类名|英文变量|程序员(?:能)?看(?:得)?懂|按类和方法|\\bif\\s?else\\b|判断语句|接口路径|后台接口"
                    + "|后端接口|\\bapi\\b(?:路径|接口|文档|地址)|接口(?:地址|文档)|调用接口|调接口|调用(?:你的|系统的|平台的)?\\bapi\\b",
            "(?:后台|后端|系统|程序)(?:里|中)?(?:的)?(?:哪个|哪些|什么)(?:类(?!型|别|目|似)|方法|函数|接口(?!人)|代码)",
            "(?:哪个|什么)(?:函数|类(?!型|别|目|似))(?:出的?问题|报错|出错)",
            "(?:写|编写|生成|开发)(?:一个|个|段|一段|一下|下|些|一些|个小)?.{0,10}?(?:代码|脚本|程序|函数|插件|小工具|自动化|爬虫|宏)",
            "(?:改|修改|修复|调试|重构|优化|\\breview\\b|审查)(?:一下|下)?.{0,10}?(?:代码|脚本|源码|\\bbug\\b|函数|逻辑代码)",
            "(?:代码|脚本)(?:怎么写|怎么改|怎么修改|写法|改一下|改成|改为|修改|实现|逻辑|报错|里的|中的)",
            "(?:给我|发我|发给我|贴出|贴一下|提供|输出)(?:一下)?(?:这段|那段|完整的?|全部的?|整段|一段)(?:源)?代码",
            "(?:코드|스크립트|프로그램|함수|매크로|정규식).{0,8}(?:작성|짜|만들|수정|고쳐|디버그|알려|보여)|(?:파이썬|자바|자바스크립트|\\bpython\\b|\\bjava\\b)"
                    + ".{0,8}(?:코드|스크립트|작성)|소스코드"));
    /** A programming language only counts next to a programming word ("python纹手袋" is a product). */
    private static final Pattern LANGUAGE = Pattern.compile("(?:\\bpython\\d?\\b|\\bjava\\b|\\bjavascript\\b|\\bjs\\b|\\btypescript\\b|\\bdart\\b|\\bflutter\\b"
            + "|\\bkotlin\\b|\\bgolang\\b|\\bgo\\b语言|c\\+\\+|c#|\\bnode\\s?js\\b|\\bnode\\b|\\bphp\\b|\\bruby\\b|\\brust\\b|\\bscala\\b|\\bperl\\b"
            + "|\\blua\\b)");
    private static final Pattern PROGRAMMING_WORD = Pattern.compile("脚本|代码|程序|写|编写|实现|函数|语句|语法|开发|工具|\\bscript\\b|\\bcode\\b|\\bprogram\\b");
    /**
     * "实现原理/程序逻辑/计算逻辑" ask how a feature works, a rule question, unless the sentence asks for code: a programming
     * verb next to it ("把程序逻辑写出来") or a code word anywhere ("后台的实现原理", "用代码讲实现原理").
     */
    private static final Pattern LOGIC_WORD = Pattern.compile("程序逻辑|实现原理|实现逻辑|计算逻辑");
    private static final Pattern LOGIC_AS_CODE = Pattern.compile("(?:写|编写|改|修改|修复|调试|生成|重构|优化|开发|审查|\\breview\\b)(?:一下|下)?.{0,6}?"
            + "(?:程序逻辑|实现原理|实现逻辑|计算逻辑)|(?:程序逻辑|实现原理|实现逻辑|计算逻辑).{0,6}?(?:怎么写|写出来|写成|写一下|改成|改为|怎么改)"
            + "|代码|源码|脚本|函数|变量|类名|方法名|类和方法|接口|后台|后端|程序员|伪码|伪代码|编程");
    private static final Pattern CODE_EN = Pattern.compile(String.join("|",
            "\\bsource\\s+code\\b",
            "\\b(?:write|fix|debug|refactor|modify|change|edit|review|generate|patch|implement|draft|create|build|code|develop|make)\\s+"
                    + "(?:me\\s+)?(?:a\\s+|an\\s+|the\\s+|this\\s+|my\\s+|your\\s+|some\\s+)?(?:small\\s+|simple\\s+|quick\\s+|little\\s+|short\\s+)?"
                    + "(?:code|script|function|program|regex|bug|automation|macro|bot|snippet|plugin)\\b"
                    + "(?!\\s+(?:of|for|field|column|format|number)\\b)",
            "\\b(?:coding|programming|github|gitlab|repository|pull\\s+request|regexp?|stack\\s+trace|traceback|vba|nodejs|node\\s+js"
                    + "|shell\\s+script|bash\\s+script|powershell\\s+script)\\b",
            "\\b(?:in|using|with)\\s+(?:python|java|javascript|typescript|go|golang|dart|php|kotlin|vba|bash|powershell|node(?:\\s+js)?)\\b",
            "\\bcalls?\\s+(?:your|the|our)\\s+api\\b|\\bapi\\s+(?:endpoints?|paths?|routes?|calls?)\\b|\\bendpoints?\\b",
            "\\bwhich\\s+(?:class|method|function|service)\\s+(?:handles|processes|implements)\\b"));
    /** Internal names typed by the user: API paths, snake_case table or field names, Java class names, file paths. */
    private static final Pattern INTERNAL_NAME = Pattern.compile("(?<![\\w/])/api/|(?<![\\w@.])[a-z]{2,}(?:_[a-z0-9]{2,})+(?![\\w@.])"
            + "|(?<![\\w])[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)*(?:Service|Controller|Handler|Repository|Impl|Dto|DTO|Entity|Mapper|Utils?|Config"
            + "|Configuration|Exception|Dao|DAO)(?![\\w])"
            + "|(?i:\\b[a-z]:\\\\|(?<![\\w.])/(?:etc|var|home|usr|opt|root|tmp|srv)/|\\.(?:java|dart|py|sh|bat|ps1|yml|yaml|properties|conf|jar"
            + "|sql)\\b)");

    private AiChatScopeGate() {}

    /** The three views of one question that the rules run on (see the class comment). */
    record Forms(String original, String lower, String spaced, String compact) {}

    /**
     * The category that puts this question outside the assistant's scope, or empty when it may be answered. A pasted
     * internal error ("页面报错 NullPointerException 怎么办", "审核时提示触发器拦截") that asks for nothing else is
     * {@link Category#INTERNAL_ERROR}: a fixed, helpful reply instead of "I don't debug code".
     */
    static Optional<Category> classify(String message) {
        if (message == null || message.isBlank()) return Optional.empty();
        Optional<Category> category = classifyForms(forms(message));
        if (category.isPresent() && (category.get() == Category.CODE || category.get() == Category.SQL)
                && pastedInternalError(message)) {
            // The rest of the sentence is classified without the error's own words: any other request keeps its refusal.
            Optional<Category> rest = classifyForms(forms(ERROR_TOKEN.matcher(fold(message)).replaceAll(" 系统报错 ")));
            if (rest.isEmpty()) return Optional.of(Category.INTERNAL_ERROR);
        }
        return category;
    }

    /** Words that only appear in a pasted internal error: exception names, stack traces, database triggers. */
    private static final Pattern ERROR_TOKEN = Pattern.compile("(?<![\\w])[A-Z][A-Za-z0-9]*(?:Exception|Error)(?![\\w])"
            + "|空指针(?:异常)?|堆栈(?:信息)?|(?i:\\bstack\\s?trace\\b|\\btraceback\\b)|触发器|存储过程");
    /** The user says the platform showed it ("报错", "提示", "弹出", "拦截", "失败"). */
    private static final Pattern ERROR_CONTEXT = Pattern.compile("报错|报了|出错|错误|异常|提示|弹出|弹窗|出现|显示|拦截|拦住|失败|不让"
            + "|(?i:\\berror\\b|\\bfailed\\b|\\bshows?\\b|\\bpopped\\b)");
    /** Asking to fix, debug or locate code is a code request, whatever error it starts from. */
    private static final Pattern FIX_REQUEST = Pattern.compile("(?<![填书抄描])写|(?<![更])改|修复|修一下|调试|重构|优化|开发|编程|代码|源码"
            + "|后端|后台|哪个类|哪个方法|哪个函数|函数|接口|(?i:\\bfix\\b|\\bdebug\\b|\\bpatch\\b|\\bcode\\b)");

    /** An internal error message the user saw and pasted, without asking for code, a fix or anything technical. */
    static boolean pastedInternalError(String message) {
        String text = fold(message);
        String compact = withoutCjkSpaces(text.toLowerCase(Locale.ROOT));
        return ERROR_TOKEN.matcher(text).find() && ERROR_CONTEXT.matcher(compact).find() && !FIX_REQUEST.matcher(compact).find();
    }

    private static Optional<Category> classifyForms(Forms forms) {
        String compact = forms.compact();
        String spaced = forms.spaced();
        if (JAILBREAK_ZH.matcher(compact).find() || JAILBREAK_EN.matcher(spaced).find()) return Optional.of(Category.JAILBREAK);
        if (PROMPT_ZH.matcher(compact).find() || PROMPT_EN.matcher(spaced).find()
                || (VERBATIM_ASK.matcher(compact).find() && PROMPT_CONTEXT.matcher(compact).find())) {
            return Optional.of(Category.PROMPT);
        }
        if (SECURITY_ZH.matcher(compact).find() || SECURITY_EN.matcher(spaced).find()) return Optional.of(Category.SECURITY);
        if (secretRequest(compact, spaced) || ADDRESS_ZH.matcher(compact).find() || ADDRESS_EN.matcher(spaced).find()
                || DOTTED_IP.matcher(forms.original()).find()) {
            return Optional.of(Category.SECRETS);
        }
        if (SQL_ZH.matcher(compact).find() || SQL_EN.matcher(spaced).find() || SQL_SELECT.matcher(forms.lower()).find()) {
            return Optional.of(Category.SQL);
        }
        if (SERVER_ZH.matcher(compact).find() || SERVER_EN.matcher(spaced).find()) return Optional.of(Category.SERVER);
        if (FILES_ZH.matcher(compact).find() || FILES_EN.matcher(spaced).find() || FILES_RAW.matcher(forms.lower()).find()) {
            return Optional.of(Category.FILES);
        }
        if (CODE_ZH.matcher(compact).find() || CODE_EN.matcher(spaced).find() || languageForCode(compact)
                || (LOGIC_WORD.matcher(compact).find() && LOGIC_AS_CODE.matcher(compact).find())
                || INTERNAL_NAME.matcher(forms.original()).find()) {
            return Optional.of(Category.CODE);
        }
        return Optional.empty();
    }

    /**
     * Someone else's or a system secret is always refused; the user's own password only when its value is
     * asked for. How to change, reset or recover one's own password is a platform question.
     */
    private static boolean secretRequest(String compact, String spaced) {
        if (SYSTEM_SECRET.matcher(compact).find()) return true;
        boolean help = SECRET_HELP.matcher(compact).find();
        if (PERSON_SECRET.matcher(compact).find() && !help) return true;
        if (SECRET_VALUE.matcher(compact).find() && !help) return true;
        if (SECRET_KO.matcher(compact).find() && !SECRET_HELP_KO.matcher(compact).find()) return true;
        if (SECRET_PINYIN.matcher(spaced).find() && SECRET_PINYIN_ASK.matcher(spaced).find()) return true;
        return SECRET_EN.matcher(spaced).find() && !SECRET_HELP_EN.matcher(spaced).find() && SECRET_ASK_EN.matcher(spaced).find();
    }

    private static boolean languageForCode(String compact) {
        var language = LANGUAGE.matcher(compact);
        while (language.find()) {
            int from = Math.max(0, language.start() - 12);
            int to = Math.min(compact.length(), language.end() + 12);
            String around = compact.substring(from, language.start()) + " " + compact.substring(language.end(), to);
            if (PROGRAMMING_WORD.matcher(around).find()) return true;
        }
        return false;
    }

    /**
     * A platform permission code ("sales_order:approve", "payroll:view:all"): the access-denied message itself says
     * "缺少操作权限：sales_order:approve". Table names and URLs ("jdbc:postgresql://") never have this shape.
     */
    private static final Pattern PERMISSION_CODE = Pattern.compile("(?<![\\w/.@-])(?!(?:https?|s?ftp|ssh|file|mailto|jdbc|redis|mysql|postgres(?:ql)?"
            + "|mongodb|wss?|tcp|udp|git|javascript|data|ldap|smtp|sql|select|insert|update|delete|drop|alter|create|truncate|exec"
            + "|execute|cmd|bash|sh|shell|powershell|python|java|node|docker|kubectl|sudo|root|db|database|table|schema):)"
            + "[a-z][a-z0-9_]*(?::[a-z][a-z0-9_]*){1,2}(?![\\w:/.@-])");
    /**
     * A field name inside an error the platform showed ("导入报错 goods_code 不能为空"): the user reads it off the
     * screen. A question about tables or field names ("stock_balances 这张表有哪些字段") is never one.
     */
    private static final Pattern SHOWN_ERROR = Pattern.compile("报错|提示|错误|出错|弹出|(?i:\\berror\\b)");
    private static final Pattern SCHEMA_WORDS = Pattern.compile("表|字段名|列名|数据库|结构|(?i:\\btable\\b|\\bcolumn\\b|\\bschema\\b|\\bsql\\b)");
    private static final Pattern SNAKE_NAME = Pattern.compile("(?<![\\w@.])[a-z]{2,}(?:_[a-z0-9]{2,})+(?![\\w@.])");
    /**
     * The server status page reports disk, memory, CPU, backup and database figures; asking what such a figure on that
     * page means is a page question. Asking where something is stored, or to clean, restart or connect, is not.
     */
    private static final Pattern STATUS_PAGE = Pattern.compile("服务器状态(?:页|页面|监控)?(?:上|里|中)");
    private static final Pattern STATUS_PAGE_QUESTION = Pattern.compile("是什么意思|什么意思|啥意思|代表什么|代表啥|含义|指什么|怎么理解|怎么看"
            + "|正常吗|是否正常|高不高|多不多|显示什么|显示的是什么|为什么(?:是|显示|变|会|这么)");
    private static final Pattern STATUS_PAGE_REQUEST = Pattern.compile("清理|删除|删掉|删|重启|关闭|关掉|停掉|停止|释放|扩容|登录|登陆|连接到|连上"
            + "|执行|运行|命令|杀|结束|放在|存在|存放|位置|路径|地址|端口|\\bip\\b|密码|账号|帮我|给我|替我|怎么(?:处理|解决|办|弄|清)");
    private static final Pattern STATUS_FIGURE = Pattern.compile("磁盘(?:空间|还剩|剩余|占用|满了|使用率|容量)?|内存(?:占用|使用率)?|\\bcpu\\b"
            + "|备份(?:策略|周期|频率|机制|文件|状态|结果)?|数据库(?:连接数?|大小|容量|状态|备份)?");

    /** A secret word inside a code-shaped name; no platform permission code holds one ("client:credit:view" does not). */
    private static final Pattern SECRET_PART = Pattern.compile("(?i)password|passwd|passphrase|pwd|secret|token|api_?key|private_?key"
            + "|credentials?|cookie|session|jwt");

    private static boolean secretPart(String name) {
        return SECRET_PART.matcher(name).find();
    }

    /** Folds the question and builds its three views (package-private for tests). */
    static Forms forms(String message) {
        // A name that holds a secret word ("datasource:password", "admin_password") is never read as business text.
        String folded = PERMISSION_CODE.matcher(fold(message))
                .replaceAll(code -> secretPart(code.group()) ? Matcher.quoteReplacement(code.group()) : "业务权限");
        if (SHOWN_ERROR.matcher(folded).find() && !SCHEMA_WORDS.matcher(folded).find() && !FIX_REQUEST.matcher(folded).find()) {
            folded = SNAKE_NAME.matcher(folded)
                    .replaceAll(name -> secretPart(name.group()) ? Matcher.quoteReplacement(name.group()) : "业务字段");
        }
        String lower = CODE_TOKEN.matcher(folded.toLowerCase(Locale.ROOT)).replaceAll(" bizcode ");
        String spaced = lower.replaceAll("[\\p{P}\\p{S}&&[^+#]]+", " ").replaceAll("\\s+", " ").strip();
        spaced = BUSINESS_CODE_EN.matcher(spaced).replaceAll("bizcode");
        String compact = withoutCjkSpaces(spaced);
        if (STATUS_PAGE.matcher(compact).find() && STATUS_PAGE_QUESTION.matcher(compact).find()
                && !STATUS_PAGE_REQUEST.matcher(compact).find()) {
            compact = STATUS_FIGURE.matcher(compact).replaceAll("页面指标");
        }
        // Business phrases are read as a whole; "X的代码" only while nothing asks to write or change code.
        compact = BUSINESS_PHRASES.matcher(compact).replaceAll("业务页");
        compact = BUSINESS_CODE.matcher(compact).replaceAll("业务编码");
        compact = BUSINESS_CODE_OF.matcher(compact).replaceAll("业务编码");
        if (!PROGRAMMING_VERB.matcher(compact).find()) compact = BUSINESS_CODE_OF_CODE.matcher(compact).replaceAll("业务编码");
        return new Forms(folded, lower, spaced, compact);
    }

    /** NFKC, no invisible format characters, look-alike letters as Latin, trigger words in simplified Chinese. */
    static String fold(String message) {
        String text = Normalizer.normalize(message.replaceAll("\\p{Cf}+", ""), Normalizer.Form.NFKC).replaceAll("\\p{Cf}+", "");
        StringBuilder out = new StringBuilder(text.length());
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            out.append(FOLD.getOrDefault(c, c));
        }
        String value = out.toString();
        for (var word : REGIONAL_WORDS.entrySet()) value = value.replace(word.getKey(), word.getValue());
        return value;
    }

    /** Removes the spaces that touch a CJK or Hangul character; spaces between Latin words stay. */
    private static String withoutCjkSpaces(String spaced) {
        StringBuilder out = new StringBuilder(spaced.length());
        for (int i = 0; i < spaced.length(); i++) {
            char c = spaced.charAt(i);
            if (c == ' ' && ((i > 0 && cjk(spaced.charAt(i - 1))) || (i + 1 < spaced.length() && cjk(spaced.charAt(i + 1))))) continue;
            out.append(c);
        }
        return out.toString();
    }

    private static boolean cjk(char c) {
        Character.UnicodeScript script = Character.UnicodeScript.of(c);
        return script == Character.UnicodeScript.HAN || script == Character.UnicodeScript.HANGUL
                || script == Character.UnicodeScript.HIRAGANA || script == Character.UnicodeScript.KATAKANA;
    }

    private static Map<Character, Character> foldTable() {
        if (LOOKALIKE_FROM.length() != LOOKALIKE_TO.length() || TRADITIONAL_PAIRS.length() % 2 != 0) {
            throw new IllegalStateException("Scope gate folding table is malformed");
        }
        Map<Character, Character> table = new java.util.HashMap<>();
        for (int i = 0; i < LOOKALIKE_FROM.length(); i++) table.put(LOOKALIKE_FROM.charAt(i), LOOKALIKE_TO.charAt(i));
        for (int i = 0; i < TRADITIONAL_PAIRS.length(); i += 2) {
            if (TRADITIONAL_PAIRS.charAt(i) != TRADITIONAL_PAIRS.charAt(i + 1)) {
                table.put(TRADITIONAL_PAIRS.charAt(i), TRADITIONAL_PAIRS.charAt(i + 1));
            }
        }
        return Map.copyOf(table);
    }

    private static Map<String, String> regionalWords() {
        Map<String, String> words = new LinkedHashMap<>();
        words.put("伺服器", "服务器");
        words.put("资料库", "数据库");
        words.put("程式码", "代码");
        words.put("原始码", "源码");
        words.put("程式", "程序");
        words.put("连线字串", "连接字符串");
        words.put("连线", "连接");
        words.put("字串", "字符串");
        words.put("变数", "变量");
        words.put("骇客", "黑客");
        words.put("软体", "软件");
        words.put("通讯埠", "端口");
        words.put("埠号", "端口号");
        return java.util.Collections.unmodifiableMap(words);
    }

    /** The fixed, friendly refusal in the reply language (zh, en or ko): what was refused and what the assistant can do. */
    static String refusal(Category category, String language) {
        String lang = language == null ? "zh" : language;
        return switch (lang) {
            case "en" -> category == Category.INTERNAL_ERROR ? englishLead(category) : englishLead(category) + " " + englishOffer();
            case "ko" -> category == Category.INTERNAL_ERROR ? koreanLead(category) : koreanLead(category) + " " + koreanOffer();
            default -> category == Category.INTERNAL_ERROR ? chineseLead(category) : chineseLead(category) + chineseOffer();
        };
    }

    /** What the assistant can do, in the reply language (zh, en or ko): added to an honest "not found" answer. */
    static String offer(String language) {
        return switch (language == null ? "zh" : language) {
            case "en" -> englishOffer();
            case "ko" -> koreanOffer();
            default -> chineseOffer();
        };
    }

    /**
     * The model judged the question outside the sources it may use or the user's permissions: the same
     * friendly scope explanation, without naming a refused category.
     */
    static String outsideSources(String language) {
        return switch (language == null ? "zh" : language) {
            case "en" -> "I can't answer that: it is outside the information I may use or your current permissions. I can help "
                    + "with how to use this platform, how its business rules work, what the current page shows, and business "
                    + "data you are allowed to see. For system administration questions, please contact your system administrator.";
            case "ko" -> "답변해 드릴 수 없습니다: 제가 사용할 수 있는 자료나 현재 권한 범위를 벗어납니다. 이 플랫폼 사용 방법, 업무 규칙, 현재 "
                    + "페이지 내용, 권한이 있는 업무 데이터 조회를 도와드릴 수 있습니다. 시스템 관리 관련 문의는 시스템 관리자에게 해 주세요.";
            default -> "这个我答不了：它超出了我能使用的资料或你当前的权限。我能帮你的是：解答本平台怎么用、业务规则怎么算、看懂当前页面，"
                    + "以及查询你有权限看的业务数据；系统管理方面的问题请联系系统管理员。";
        };
    }

    /**
     * The AI service itself declined the question (its content review): the same scope explanation as a refusal,
     * never "contact the administrator" as if the service were broken.
     */
    static String declined(String language) {
        return switch (language == null ? "zh" : language) {
            case "en" -> "I can't help with that question. " + englishOffer();
            case "ko" -> "이 질문은 도와드릴 수 없습니다. " + koreanOffer();
            default -> "这个问题我不能处理。" + chineseOffer();
        };
    }

    private static String chineseOffer() {
        return "我能帮你的是：解答本平台怎么用、业务规则怎么算(比如入库没填重量时系统怎么估算)、看懂当前页面，以及查询你有权限看的业务数据。"
                + "需要改系统功能或处理服务器问题，请联系系统管理员。";
    }

    private static String englishOffer() {
        return "I can help with how to use this platform, how its business rules work (for example how stock weight is "
                + "estimated when none was entered), what the current page shows, and business data you are allowed to see. "
                + "For system changes or server problems, please contact your system administrator.";
    }

    private static String koreanOffer() {
        return "이 플랫폼 사용 방법, 업무 규칙이 어떻게 계산되는지(예: 입고 시 중량을 입력하지 않으면 어떻게 추정되는지), 현재 페이지 내용, "
                + "그리고 권한이 있는 업무 데이터 조회를 도와드릴 수 있습니다. 시스템 변경이나 서버 문제는 시스템 관리자에게 문의해 주세요.";
    }

    private static String chineseLead(Category category) {
        return switch (category) {
            case CODE -> "这个我帮不了：我不能编写、修改或调试代码和脚本。";
            case SERVER -> "这个我帮不了：我不能连接或操作服务器，也不能执行任何命令。";
            case SQL -> "这个我帮不了：我不能编写或执行 SQL，也不能直接操作数据库。";
            case FILES -> "这个我帮不了：我不能读取或修改系统的文件、日志和配置。";
            case SECRETS -> "这个我帮不了：我不能提供密码、密钥、令牌或内部地址。";
            case PROMPT -> "这个我帮不了：我的内部设置和 AI 服务配置不能透露。";
            case JAILBREAK -> "这个我帮不了：我会一直按平台的规则工作，不能切换角色或忽略这些规则。";
            case SECURITY -> "这个我帮不了：我不能协助绕过安全措施或攻击系统。";
            case INTERNAL_ERROR -> "这像是系统内部出错的提示，不是你在页面上能改好的。请把报错截图和当时的操作(哪个页面、哪张单据、点了什么)"
                    + "发给管理员。我能帮你的是：你告诉我当时在做什么操作，我按业务规则帮你看看这一步要满足什么条件、接下来怎么办。";
        };
    }

    private static String englishLead(Category category) {
        return switch (category) {
            case CODE -> "I can't help with that: I don't write, change or debug code or scripts.";
            case SERVER -> "I can't help with that: I don't connect to or operate servers, and I don't run commands.";
            case SQL -> "I can't help with that: I don't write or run SQL or work on the database directly.";
            case FILES -> "I can't help with that: I don't read or change system files, logs or configuration.";
            case SECRETS -> "I can't help with that: I don't give out passwords, keys, tokens or internal addresses.";
            case PROMPT -> "I can't help with that: my internal setup and the AI service configuration are not shared.";
            case JAILBREAK -> "I can't help with that: I always work by this platform's rules and can't switch roles or ignore them.";
            case SECURITY -> "I can't help with that: I don't help bypass security or attack systems.";
            case INTERNAL_ERROR -> "This looks like an internal system error, not something you can fix on the page. Please send a "
                    + "screenshot of the error and what you were doing (which page, which document, what you clicked) to your "
                    + "administrator. I can help with the business side: tell me what you were doing and I will explain what that "
                    + "step requires and what to do next.";
        };
    }

    private static String koreanLead(Category category) {
        return switch (category) {
            case CODE -> "도와드릴 수 없습니다: 코드나 스크립트를 작성, 수정, 디버깅하지 않습니다.";
            case SERVER -> "도와드릴 수 없습니다: 서버에 접속하거나 조작하지 않으며 명령도 실행하지 않습니다.";
            case SQL -> "도와드릴 수 없습니다: SQL을 작성하거나 실행하지 않으며 데이터베이스를 직접 다루지 않습니다.";
            case FILES -> "도와드릴 수 없습니다: 시스템 파일, 로그, 설정을 읽거나 바꾸지 않습니다.";
            case SECRETS -> "도와드릴 수 없습니다: 비밀번호, 키, 토큰, 내부 주소는 알려 드리지 않습니다.";
            case PROMPT -> "도와드릴 수 없습니다: 내부 설정과 AI 서비스 구성은 공개하지 않습니다.";
            case JAILBREAK -> "도와드릴 수 없습니다: 항상 플랫폼 규칙에 따라 일하며 역할을 바꾸거나 규칙을 무시할 수 없습니다.";
            case SECURITY -> "도와드릴 수 없습니다: 보안 우회나 시스템 공격은 돕지 않습니다.";
            case INTERNAL_ERROR -> "시스템 내부 오류로 보이며, 화면에서 직접 고칠 수 있는 문제가 아닙니다. 오류 화면 캡처와 당시 작업(어느 페이지, "
                    + "어느 전표, 무엇을 눌렀는지)을 관리자에게 보내 주세요. 당시 하던 작업을 알려 주시면 그 단계의 업무 조건과 다음에 할 일을 "
                    + "도와드릴 수 있습니다.";
        };
    }

    /** All categories, for tests and documentation. */
    static List<Category> categories() { return List.of(Category.values()); }
}
