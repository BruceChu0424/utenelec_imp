package com.uten.imp.features.sales.intake;

import com.uten.imp.features.sales.intake.GoodsMatcher.Evidence;
import com.uten.imp.features.sales.intake.GoodsMatcher.Reason;
import com.uten.imp.features.sales.intake.GoodsMatcher.Scored;

import java.util.ArrayList;
import java.util.List;

/**
 * 识别结果里给销售看的中文文字(大白话, 不出现分数、识别方式等技术词)。
 */
final class IntakeTexts {

    static final String NOTICE_AI_OFF = "AI 未开启, 只识别常见格式的 Excel";
    static final String NOTICE_AI_FAILED = "AI 暂时用不了, 已按固定规则识别, 请多核对";
    static final String NOTICE_NO_VISIBLE_CLIENTS = "你名下还没有客户资料, 请联系主管在客户资料里把客户分配给你";
    static final String FAIL_NO_TABLE = "没在文件里找到货品明细表(需要有数量, 以及型号或品名这几列), 请检查文件后再试";
    static final String FAIL_NO_TABLE_AI_OFF = "没在文件里找到货品明细表(需要有数量, 以及型号或品名这几列)。AI 未开启, 只能识别常见格式的 Excel";
    static final String FAIL_AI_REQUIRED = "PDF/图片需要开启 AI 才能识别, 请上传 Excel 或联系管理员";
    static final String FAIL_VISION = "这是图片格式的文件, 需要管理员在 AI 服务设置中启用支持图片识别的模型";
    static final String FAIL_NO_LINES = "没从文件里读到货品行, 请检查文件内容";
    static final String FAIL_UNSUPPORTED = "只支持 Excel(.xlsx/.xls)、CSV、PDF 和图片(PNG/JPG/WEBP)";

    private IntakeTexts() {
    }

    /** 候选货品的理由(按证据顺序, 去掉不需要单独说的项)。 */
    static List<String> reasons(Scored s) {
        List<String> out = new ArrayList<>();
        for (Evidence e : s.evidence) {
            String text = switch (e) {
                case ALIAS_AUTHORITATIVE -> "已学习的对应关系";
                case ALIAS -> "以前对应过";
                case ALIAS_GLOBAL -> "其他客户也这样叫";
                case MODEL -> "型号一致";
                case MODEL_VARIANT -> "型号基本一致";
                case MODEL_ONE_EDIT -> "型号只差一个字";
                case CODE -> "编号一致";
                case NAME_EXACT, NAME_SHORT_AGREES -> "名称一致";
                case NAME_APPROX -> "名称基本一致";
                case NAME_SUFFIX -> "名称结尾一致";
                case NAME_BIGRAM -> "名称相似";
                case NAME_EN_EXACT -> "英文名一致";
                case NAME_EN_SIMILAR -> "英文名相似";
                case SERIES_MATCH -> "系列一致";
                case SERIES_NEAR -> "系列相近";
                case SERIES_CONFLICT -> "系列不一致";
                case COLOR_MATCH -> "颜色一致";
                case COLOR_CONFLICT -> "颜色不一致";
                case FRAME_CONFLICT -> "面框颜色不一致";
                case DESCRIPTION_ALIAS -> "客户品名以前对应过";
                case BOUGHT_BEFORE -> "该客户买过(" + s.historyCount + "次)";
                case OWN_PREFIX -> "该客户专用货品";
                case OTHER_CUSTOMER -> "其他客户的专用货品";
                case PRICE_MATCH -> "单价与标价一致";
                case DISCOUNT_ODD -> "折扣异常";
                case AI_PICK -> "AI 建议";
                case ASSEMBLED_PART -> "是组装好的功能件";
                case MODEL_AND_NAME, BUNDLE -> null;
            };
            if (text != null && !out.contains(text)) {
                out.add(text);
            }
        }
        return out;
    }

    /** 待核对/没找到的一句话原因。 */
    static String reasonText(Reason reason, int candidateCount) {
        return switch (reason) {
            case NONE -> null;
            case NOT_FOUND -> "没找到这个货品";
            case BUNDLE -> "这一行是几个配件的组合, 请选对应的货品或拆成几行";
            case ALIAS_AMBIGUOUS -> "以前的对应关系指向好几个货品, 请选一个";
            case SERIES_CONFLICT -> "系列没对上, 请核对";
            case COLOR_CONFLICT -> "颜色没对上, 请核对";
            case FRAME_CONFLICT -> "面框颜色没对上, 请核对";
            case COLOR_AMBIGUOUS -> "文件里的颜色有好几种, 请核对";
            case DISCOUNT_ODD -> "折扣异常, 可能对应错货品";
            case SAME_NAME_SIBLINGS -> "有几个名称相同的货品, 请选一个";
            case MULTI_SERIES -> "同一型号有几个系列, 请选一个";
            case FUZZY_ONLY -> "只找到名称相近的货品, 请核对";
            case CLOSE_CANDIDATES -> "找到 " + Math.max(2, Math.min(candidateCount, GoodsMatcher.TOP_K))
                    + " 个相似货品, 请选一个";
            case LOW_SCORE -> "不太确定是哪个货品, 请核对";
            case CLIENT_UNCONFIRMED -> "客户还没确认, 请核对这个货品";
        };
    }

    static final String REASON_DUPLICATE_GOODS = "这几行对应到了同一个货品, 请核对";
}
