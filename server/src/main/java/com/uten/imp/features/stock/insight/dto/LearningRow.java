package com.uten.imp.features.stock.insight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 单重学习工作清单一行 (GET /api/stock/insights/learning)。单重依据与可靠度与
 * /api/stock/weight/params 同一解析 (按重量计 &gt; 人工设定 &gt; 学到的 &gt; 设计单重 &gt; 无)。
 *
 * @param goodsId             货品
 * @param code                货品编号
 * @param name                货品名称
 * @param model               型号
 * @param unitName            基本单位
 * @param baseUnitDimension   基本单位计量维度 (COUNT / ... / null 未登记)
 * @param basis               MANUAL / LEARNED / MASTER_PRIOR / NONE (按重量计的货品不在清单里)
 * @param evidence            学习依据 REFERENCE / DRAW_ONLY / CONFLICT / null
 * @param tier                可靠度 GREEN / YELLOW / RED (NONE 为 null)
 * @param unitWeightKg        当前单重 (千克/基本单位)
 * @param relHalfWidth        相对半宽 (±%/100)
 * @param nInliers            依据的有效称重次数
 * @param nRef                货品总体学习结果里的参考称重次数 (没有学习结果为 null)
 * @param nDraw               货品总体学习结果里的领料称重次数 (按过往领料推算时即推算依据的次数)
 * @param lastObservedAt      最近一次称重
 * @param stale               超过 365 天没有新称重
 * @param suggestedSampleSize 建议称样件数
 * @param masterUnitWeightKg  货品档案设计单重换算成千克/基本单位 (没有或单位不是重量单位为 null)
 * @param masterDiffPct       学到的单重比设计单重 (%)
 * @param drawBiasPct         领料实发比应发 (%)
 * @param movements90d        近 90 天出入库笔数
 * @param lastMovementAt      最近一笔出入库
 * @param qty                 现存量 (核算仓, 不含线边仓)
 * @param observations        有效称重记录数
 * @param learningEnabled     参与学习
 */
public record LearningRow(
        UUID goodsId,
        String code,
        String name,
        String model,
        String unitName,
        String baseUnitDimension,
        String basis,
        String evidence,
        String tier,
        BigDecimal unitWeightKg,
        Double relHalfWidth,
        @JsonProperty("nInliers") Integer nInliers,
        @JsonProperty("nRef") Integer nRef,
        @JsonProperty("nDraw") Integer nDraw,
        OffsetDateTime lastObservedAt,
        boolean stale,
        Integer suggestedSampleSize,
        BigDecimal masterUnitWeightKg,
        BigDecimal masterDiffPct,
        Double drawBiasPct,
        @JsonProperty("movements90d") long movements90d,
        OffsetDateTime lastMovementAt,
        BigDecimal qty,
        long observations,
        boolean learningEnabled) {
}
