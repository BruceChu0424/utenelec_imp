package com.uten.imp.features.sales.intake;

import com.uten.imp.common.text.IntakeTextNormalizer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Locale;

/**
 * 从客户文件抽出的一行货品(识别结果 lines[] 的抽取部分; 匹配与定价另算)。
 *
 * @param key               行键 {@code S<工作表序号>R<行号>}(从 1 开始; PDF 为 {@code P1R<序号>}, 图片为 {@code I1R<序号>}),
 *                          同一任务内稳定, 保存时作为 intakeLineKey 回传
 * @param sourceSheet       来源工作表名(PDF/图片为空)
 * @param sourceRow         来源行号(从 1 开始, 与 Excel 行号一致; PDF/图片为序号)
 * @param partNo            客户型号/货号原文
 * @param description       英文(拉丁文字)描述
 * @param descriptionAlt    中文描述原文
 * @param matchDescription  用于匹配的中文描述: 去掉组装说明; 组合件只取第一个「+」前的部分
 * @param colors            颜色解析结果
 * @param bundleParts       组合件(型号里用 + 连接)拆出的各型号; 非组合件为空
 * @param assembled         描述里写了「组装成功能件」
 * @param warnings          抽取阶段的提醒(单位不是个、金额对不上)
 */
record ExtractedLine(String key, String sourceSheet, int sourceRow, String lineNo, String partNo, String description,
                     String descriptionAlt, String matchDescription, String series, String color, String colorAlt,
                     IntakeColors.ColorSpec colors, BigDecimal qty, String unit, BigDecimal suggestedQty,
                     BigDecimal customerUnitPrice, BigDecimal customerAmount, List<String> bundleParts, boolean assembled,
                     List<IntakeWarning> warnings) {

    ExtractedLine {
        bundleParts = bundleParts == null ? List.of() : List.copyOf(bundleParts);
        warnings = warnings == null ? List.of() : List.copyOf(warnings);
        colors = colors == null ? IntakeColors.ColorSpec.NONE : colors;
    }

    boolean bundle() {
        return bundleParts.size() > 1;
    }

    /** 规范化的完整型号(对照查找用)。 */
    String partNorm() {
        return partNo == null ? "" : IntakeTextNormalizer.normalizePart(partNo);
    }

    /** 规范化的第一个型号(组合件只用第一段找型号)。 */
    String firstPartNorm() {
        String norm = partNorm();
        if (bundle()) {
            return IntakeTextNormalizer.normalizePart(bundleParts.getFirst());
        }
        return norm;
    }

    /** 规范化的系列(大写, 去空白); 没有为空串。 */
    String seriesNorm() {
        if (series == null) {
            return "";
        }
        return IntakeTextNormalizer.nfkc(series).strip().toUpperCase(Locale.ROOT).replaceAll("\\s+", "");
    }

    /** 对照学习的上下文「系列|主色」; 两者都不知道为空串。 */
    String contextNorm() {
        String s = seriesNorm();
        String c = colors.known() ? colors.mainLabel() : "";
        if (s.isEmpty() && c.isEmpty()) {
            return "";
        }
        return s + "|" + c;
    }

    /** 客户品名(优先英文描述, 没有用中文描述), 学习对照与「设为英文名」用。 */
    String clientGoodsName() {
        if (description != null && !description.isBlank()) {
            return description;
        }
        return descriptionAlt;
    }
}
