package com.uten.imp.features.production.schedule.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 待排产订单行（调度工作台左侧列表）。
 *
 * <p>口径：已审未结案未中止订单中，链路行(chain_status 1..8)且待排产缺口大于 0。
 * 剩余未排量 = max(订单量 − 已发 + 已退 − 核销 − 当前预留
 * − max(已排产 − 已产, 0), 0)；已产且已入库预留的数量不会重复扣减。
 * 待排资格仍按净缺口判断；{@link #needQty} 是本次待承接的覆盖总需求，包含可用库存覆盖部分。
 * 例如销售需要1000、现有预留120、尚无计划/分析时，needQty=1000；库存不再先裁成880。
 * 列表按交货日期升序（越近越前）。
 *
 * <p>{@code materialAnalysisId} 起的一组投影字段描述的是**同一订单行上已被承接的那一部分**
 * (最近一张活动分析)，不是本行 needQty 这个残量的齐套情况——全量承接的行根本不在本列表里，
 * 只有部分承接的行才会同时带 needQty > 0 与非空分析投影。
 */
public record PendingPlanRow(
        UUID orderItemId,
        UUID orderId,
        String orderBillNo,
        UUID clientId,
        String clientName,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String spec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal qty,
        BigDecimal reservedQty,
        BigDecimal plannedQty,
        BigDecimal needQty,
        LocalDate deliverDate,
        Short chainStatus,
        boolean urgent,            // 距交货 ≤3 天（含逾期），前端红色醒目
        UUID materialAnalysisId,
        UUID materialAnalysisLineId,
        String materialAnalysisStatus,
        Long materialAnalysisVersion,
        OffsetDateTime materialAnalyzedAt,
        BigDecimal analyzedQty,
        BigDecimal submittedPlanQty,
        BigDecimal approvedPlannedQty,
        BigDecimal readyNowQty,
        BigDecimal readyByDateQty,
        BigDecimal readinessRatio,
        /** 活动物料分析已承接量(该行全部 ACTIVE / PARTIALLY_PLANNED 分析的未下达量之和)。
         *  大于 0 表示本行已有一部分转到「进行中」按分析批次跟踪，列表里这一行是未承接的残量。 */
        BigDecimal analysisCoveredQty) {
}
