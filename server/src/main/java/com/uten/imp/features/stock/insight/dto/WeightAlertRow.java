package com.uten.imp.features.stock.insight.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 称重异常一行 (GET /api/stock/insights/weight-alerts)。
 *
 * <p>两类: OBSERVATION = 称重记录在记录当时就和当时的单重对不上 (预期/偏差/告警级别是记录时的快照,
 * 之后单重再怎么学都不改写); REGIME = 单重学习发现单重可能已变化 (换批/换料?)。
 *
 * @param rowType             OBSERVATION / REGIME
 * @param id                  称重记录 id (REGIME 为学习结果行 id)
 * @param observedAt          称重时间 (REGIME 为检测到变化的那次称重时间)
 * @param alertKind           RECEIPT_SHORT 来料少数 / RECEIPT_OVER 来料多数 / DRAW_OVER 领料超发 /
 *                            DRAW_SHORT 领料少发 / RETURN_MISMATCH 退料不符 / COUNT_MISMATCH 盘点差异 /
 *                            FINISHED_MISMATCH 产成品不符 / INBOUND_MISMATCH 入库不符 /
 *                            OUTBOUND_MISMATCH 出库不符 / SAMPLE_DEVIATION 称样偏差 / REGIME_CHANGE 单重可能变化
 * @param alertLabel          上述种类的中文名
 * @param goodsId             货品
 * @param code                货品编号
 * @param name                货品名称
 * @param unitName            基本单位
 * @param baseUnitDimension   基本单位计量维度 (COUNT = 按件, 数量取整显示; 未登记为 null)
 * @param colorName           颜色名
 * @param warehouseId         仓库
 * @param warehouseName       仓库名
 * @param sourceKind          称重来源 (RECEIPT / DRAW / ...)
 * @param supplierId          供应商
 * @param supplierName        供应商名
 * @param counterpartKind     往来方种类 (WORKSHOP / SUBCONTRACTOR / CLIENT / SUPPLIER)
 * @param counterpartId       往来方
 * @param counterpartName     往来方名称
 * @param sourceDocType       来源单据类型
 * @param sourceDocId         来源单据
 * @param sourceDocCode       仓库单据的 doc_type
 * @param billNo              单号
 * @param qtyBase             登记数量 (基本单位)
 * @param weightKg            实称重量 (千克)
 * @param expectedUnitWeightKg 记录当时的单重
 * @param expectedWeightKg    按登记数量应有的重量
 * @param estimatedQty        称重折算数量 (实称 / 当时单重)
 * @param deviationQty        折算数量 − 登记数量
 * @param deviationPct        重量偏差 % = 100 × (实称 / 应有 − 1)
 * @param alertLevel          WARN / ALERT (REGIME 为 null)
 * @param estimateTierUsed    记录当时的可靠度 (REGIME 为当前可靠度)
 * @param estimateBasisUsed   记录当时的单重依据
 * @param unitWeightKg        REGIME: 当前学到的单重
 */
public record WeightAlertRow(
        String rowType,
        UUID id,
        OffsetDateTime observedAt,
        String alertKind,
        String alertLabel,
        UUID goodsId,
        String code,
        String name,
        String unitName,
        String baseUnitDimension,
        String colorName,
        UUID warehouseId,
        String warehouseName,
        String sourceKind,
        UUID supplierId,
        String supplierName,
        String counterpartKind,
        UUID counterpartId,
        String counterpartName,
        String sourceDocType,
        UUID sourceDocId,
        String sourceDocCode,
        String billNo,
        BigDecimal qtyBase,
        BigDecimal weightKg,
        BigDecimal expectedUnitWeightKg,
        BigDecimal expectedWeightKg,
        BigDecimal estimatedQty,
        BigDecimal deviationQty,
        BigDecimal deviationPct,
        String alertLevel,
        String estimateTierUsed,
        String estimateBasisUsed,
        BigDecimal unitWeightKg) {
}
