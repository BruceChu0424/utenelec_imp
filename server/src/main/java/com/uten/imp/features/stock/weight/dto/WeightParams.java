package com.uten.imp.features.stock.weight.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 一个货品 (可带供应商) 的单重参数 (POST /api/stock/weight/params 的 items 元素, ADR-135 §7.2)。
 * 客户端据此用 WeightPredictor 自算称重计数、应称重量与偏差; 过账仍以服务端为准。
 *
 * @param key                 请求行的 key 原样返回
 * @param goodsId             货品
 * @param basis               EXACT (按重量计的货品) / MANUAL (人工设定) / LEARNED (学到的) /
 *                            MASTER_PRIOR (货品档案设计单重) / NONE
 * @param supplierSpecific    LEARNED 时是否用的是该供应商自己的单重
 * @param evidence            学习依据: REFERENCE / DRAW_ONLY (按过往领料推算) / CONFLICT (两次矛盾, 请称样) / null
 * @param unitWeightKg        单重 kg/基本单位
 * @param logMean             ln(unitWeightKg)
 * @param lotPrior            请求先验方差 P (EXACT 为 0)
 * @param gamma               单件离散 (相对 sd)
 * @param df                  t 分位数自由度
 * @param tier                可靠度 GREEN/YELLOW/RED (EXACT 为 GREEN, NONE 为 null)
 * @param relHalfWidth        按 N→∞ 的相对半宽
 * @param nInliers            依据的有效称重次数
 * @param suggestedSampleSize 建议称样件数
 * @param exactUpToQty        称重计数能数准 (±0.5 个) 的最大数量 (向下取整; EXACT/NONE 为 null)
 * @param tolerancePct        核对容差 (%)
 * @param defaultTareKg       默认皮重 kg
 * @param lastTareKg          最近一次称重记录的皮重 kg
 * @param massFactorKg        EXACT 时 1 个基本单位等于多少 kg
 * @param stale               学到的单重超过 365 天没有新称重 (可靠度最多 YELLOW)
 * @param lastObservedAt      最近一次称重时间
 * @param drawBiasPct         领料实发比应发 (%)
 * @param manualConflictPct   人工单重与学到的单重差异明显时的差异 (%)
 * @param baseUnitDimension   基本单位的计量维度 (COUNT / MASS / ... / null 未登记)
 * @param learningEnabled     是否参与学习
 * @param scaleResKg          秤分辨率 kg (预测公式里的量化误差项)
 */
public record WeightParams(
        String key,
        UUID goodsId,
        String basis,
        boolean supplierSpecific,
        String evidence,
        BigDecimal unitWeightKg,
        Double logMean,
        Double lotPrior,
        Double gamma,
        Double df,
        String tier,
        Double relHalfWidth,
        @JsonProperty("nInliers") Integer nInliers,
        Integer suggestedSampleSize,
        Long exactUpToQty,
        BigDecimal tolerancePct,
        BigDecimal defaultTareKg,
        BigDecimal lastTareKg,
        BigDecimal massFactorKg,
        boolean stale,
        OffsetDateTime lastObservedAt,
        Double drawBiasPct,
        Double manualConflictPct,
        String baseUnitDimension,
        boolean learningEnabled,
        double scaleResKg) {
}
