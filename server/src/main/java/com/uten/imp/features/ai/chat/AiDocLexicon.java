package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * ADR-153 revision: the platform's design documents are written in Chinese, while the interface (and so the
 * questions) may be in English or Korean. This small reviewed lexicon maps the everyday business words of an
 * English or Korean question to the words the documents use, so "Who approves a stock count difference?" is
 * searched as 盘点 / 差异 / 审核 like its Chinese twin. It only adds search words: the reply is still written
 * in the user's language by the model, from the same Chinese rules.
 */
final class AiDocLexicon {
    /** English phrase (lower case, whole words) to the documents' Chinese words. */
    private static final List<Map.Entry<Pattern, String>> ENGLISH = List.of(
            e("unit\\s+weight|weight\\s+per\\s+(?:piece|unit|item|pc)|per[\\s-](?:piece|unit)\\s+weight|each\\s+(?:piece|item|unit)\\s+weigh\\w*"
                    + "|how\\s+(?:much|heavy)\\s+(?:is\\s+)?each", "单重 每个多重"),
            e("average\\s+weight", "均重"),
            e("unweighed|without\\s+weigh\\w*|not\\s+weighed|no\\s+weight|weight\\s+(?:is\\s+)?(?:empty|blank|missing)", "未称 没填重量"),
            e("weigh\\w*|weight\\w*|kg|kilogram\\w*|gram\\w*", "重量 称重"),
            e("estimat\\w*|approximat\\w*", "估算"),
            e("reliab\\w*|trust\\w*|learn\\w*|threshold\\w*", "可靠 单重自学习"),
            e("receiv\\w*|receipt\\w*|stock[\\s-]?in|inbound|put\\s?away|goods\\s+in|arriv\\w*", "入库 到货"),
            e("outbound|stock[\\s-]?out|ship\\s?out|picking|issu(?:e|ed|ing)\\s+(?:stock|material\\w*)", "出库 发料"),
            e("stock\\s*(?:count|take|taking)\\w*|stocktak\\w*|inventory\\s+count\\w*|physical\\s+count\\w*|cycle\\s+count\\w*|count\\s+difference\\w*",
                    "盘点"),
            e("differen\\w*|discrepanc\\w*|varianc\\w*|mismatch\\w*", "差异"),
            e("who\\s+(?:approves|reviews|signs|handles|checks|confirms)|approver\\w*|in\\s+charge|responsib\\w*", "谁来审核 审核归属 负责人"),
            e("approv\\w*|review\\w*|sign[\\s-]?off", "审核"),
            e("stock|inventor\\w*|on\\s+hand", "库存"),
            e("warehouse\\w*|storehouse\\w*", "仓库"),
            e("line[\\s-]?side|workshop\\s+(?:stock|bin|store|warehouse)|material\\s+bin", "内料仓"),
            e("defect\\w*|reject\\w*|scrap\\w*|non[\\s-]?conform\\w*", "不良品 不合格"),
            e("quality|inspect\\w*|qc|iqc|fqc", "质检 检验"),
            e("purchas\\w*|procure\\w*", "采购"),
            e("supplier\\w*|vendor\\w*", "供应商"),
            e("sales\\s+order\\w*|customer\\s+order\\w*", "销售订单 订货"),
            e("quot(?:e|es|ation\\w*)", "报价"),
            e("customer\\w*|client\\w*", "客户"),
            e("ship(?:ment|ping|ped|s)?|deliver\\w*|dispatch\\w*", "出货 发货"),
            e("return\\w*|refund\\w*", "退货"),
            e("resell\\w*|sell\\s+(?:it\\s+)?again|back\\s+(?:in)?to\\s+stock|restock\\w*", "再卖 良品释放"),
            e("produc(?:e|ed|ing|tion)|manufactur\\w*", "生产"),
            e("work\\s+orders?|job\\s+orders?", "工单"),
            e("workshop\\w*|shop\\s+floor", "车间"),
            e("report\\w*\\s+(?:work|output|production)|daily\\s+report\\w*|work\\s+report\\w*", "报工 日报"),
            e("subcontract\\w*|outsourc\\w*", "委外"),
            e("material\\w*", "物料"),
            e("bom|bill\\s+of\\s+materials?", "物料清单"),
            e("over[\\s-]?produc\\w*|overrun\\w*|excess\\s+output|more\\s+than\\s+planned", "超产"),
            e("append\\w*|additional\\s+(?:plan|quantity|production)", "追加"),
            e("plan(?:s|ned|ning)?|schedul\\w*", "计划"),
            e("prices?|pricing|unit\\s+price", "单价 价格"),
            e("costs?|costing", "成本"),
            e("exchange\\s+rates?|currenc\\w*", "汇率 币种"),
            e("payments?\\s+(?:collect\\w*|receiv\\w*)|collect\\w*|receivabl\\w*", "收款"),
            e("payabl\\w*", "应付 付款"),
            e("badge\\w*|red\\s+dot\\w*|counter\\s+number\\w*", "徽章"),
            e("red", "红色"),
            e("yellow|amber", "黄色"),
            e("green", "绿色"),
            e("colou?r\\w*", "颜色"),
            e("drafts?", "草稿"),
            e("sav(?:e|ed|es|ing)", "保存"),
            e("submit\\w*", "提交"),
            e("change\\s+(?:my\\s+)?(?:own\\s+)?(?:login\\s+)?password|password", "修改密码 我的页"),
            e("log\\s?in|sign\\s?in", "登录"),
            e("reimburs\\w*|expense\\s+claim\\w*", "报销"),
            e("leave\\s+request\\w*|day\\s+off", "请假"),
            e("permission\\w*|access\\s+rights?", "权限"),
            e("direct\\s+transfer\\w*", "车间直送"),
            e("requisition\\w*|pick\\s+list\\w*|material\\s+issue\\w*", "领料"),
            e("freez\\w*|frozen|on\\s+hold", "冻结"),
            e("short\\s+(?:delivery|shipment)|shortage\\w*|short\\s+received", "短交 缺货"),
            e("in[\\s-]?transit", "在途"),
            e("task\\s+cent(?:er|re)|to[\\s-]?do\\w*", "任务中心 待办"),
            e("progress\\w*", "进度"),
            e("owner\\w*|keeper\\w*|supervisor\\w*", "负责人"),
            e("scope|visible|can\\s+i\\s+see|who\\s+can\\s+see", "范围 看得到"),
            e("data\\s+(?:is\\s+)?sent|send\\w*\\s+(?:to|data)|privacy|external\\s+(?:ai|model)", "发送 外部 隐私"),
            e("server\\s+status", "服务器状态页"),
            e("audit\\s+log\\w*", "审计日志页"),
            e("notification\\w*|alert\\w*", "通知"),
            e("sound\\w*", "声音"),
            e("setting\\w*|preference\\w*", "设置页"),
            e("import\\w*", "导入"),
            e("export\\w*", "导出"),
            e("mou?ld\\w*", "模具"),
            e("logistic\\w*|carrier\\w*", "物流"),
            e("freight|shipping\\s+(?:cost|fee|charge)\\w*", "运费"),
            e("packag\\w*", "包装"),
            e("report\\w*", "报表"));

    /** Korean words (spaces removed) to the documents' Chinese words. */
    private static final List<Map.Entry<Pattern, String>> KOREAN = List.of(
            k("재고실사|재고조사|실사", "库存盘点"),
            k("재고", "库存"),
            k("차이|불일치", "差异"),
            k("누가승인|승인자|누가검토|누가확인|담당자|책임자", "谁来审核 审核归属 负责人"),
            k("승인|결재|검토", "审核"),
            k("입고", "入库"),
            k("출고", "出库"),
            k("단중|단위중량|개당무게|개당중량|하나당무게", "单重 每个多重"),
            k("평균중량|평균무게", "均重"),
            k("중량|무게", "重量 称重"),
            k("추정|추산", "估算"),
            k("창고", "仓库"),
            k("불량", "不良品"),
            k("검사|품질", "质检 检验"),
            k("구매|발주", "采购"),
            k("공급업체|협력사", "供应商"),
            k("판매|영업", "销售"),
            k("주문|수주", "订单"),
            k("견적", "报价"),
            k("고객|거래처", "客户"),
            k("출하|배송|발송", "出货"),
            k("반품", "退货"),
            k("생산", "生产"),
            k("작업지시", "工单"),
            k("작업장|공장|현장", "车间"),
            k("작업보고|실적", "报工"),
            k("외주", "委外"),
            k("자재", "物料"),
            k("계획", "计划"),
            k("단가|가격", "单价"),
            k("원가", "成本"),
            k("환율|통화", "汇率"),
            k("수금|입금", "收款"),
            k("배지|뱃지", "徽章"),
            k("빨간|빨강|적색", "红色"),
            k("노란|노랑|황색", "黄色"),
            k("임시저장|초안", "草稿"),
            k("저장", "保存"),
            k("제출", "提交"),
            k("비밀번호", "修改密码"),
            k("로그인", "登录"),
            k("권한", "权限"),
            k("경비|비용정산", "报销"),
            k("휴가", "请假"));

    private AiDocLexicon() {}

    private static Map.Entry<Pattern, String> e(String phrase, String chinese) {
        return Map.entry(Pattern.compile("\\b(?:" + phrase + ")\\b"), chinese);
    }

    private static Map.Entry<Pattern, String> k(String words, String chinese) {
        return Map.entry(Pattern.compile(words), chinese);
    }

    /** The documents' words for the English or Korean business words of {@code question} (empty when none). */
    static String translate(String question) {
        if (question == null || question.isBlank()) return "";
        String value = Normalizer.normalize(question, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
        Set<String> words = new LinkedHashSet<>();
        String english = value.replaceAll("[^a-z0-9\\s-]+", " ");
        if (english.matches("(?s).*[a-z]{2,}.*")) {
            for (var entry : ENGLISH) if (entry.getKey().matcher(english).find()) words.add(entry.getValue());
        }
        String korean = value.replaceAll("[^\\p{IsHangul}]+", "");
        if (!korean.isEmpty()) {
            for (var entry : KOREAN) {
                if (entry.getKey().matcher(korean).find()) words.add(entry.getValue());
            }
        }
        return String.join(" ", words);
    }
}
