package com.uten.imp.features.production.plan.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产进度看板行：计划的聚合进度。
 * reportedQty = Σfqty（报工进度），inboundQty = Σiqty（成品入库进度）。
 * percent = plannedInboundQty / totalQty；actualSurplusInboundQty 单列，不抵扣计划责任。
 * todayQty = 今日成品入库量（当日已审 FINISHED_IN 按 plan_draw_links 溯源汇总，基本单位）。
 * 顶层只列父计划；subplans 为拆分生成的子计划进度（点开展示）。
 * closed 读取主表 is_closed（含物料结清守卫）；status/stopped/canceled 保留真实终态，归历史不伪造完工。
 * pinned/important 为看板标记。
 */
public record PlanProgressRow(
        UUID planId,
        String billNo,
        LocalDate billDate,
        LocalDate deliveryDate,
        String workshopName,
        UUID departmentId,
        int lineCount,
        BigDecimal totalQty,
        BigDecimal reportedQty,
        BigDecimal inboundQty,
        String materialState,
        int materialSegmentCount,
        int materialReadySegmentCount,
        BigDecimal materialTotalQty,
        BigDecimal materialReadyQty,
        Double materialPercent,
        boolean canStartNow,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        double percent,
        boolean closed,
        boolean urgent,
        boolean overdue,
        boolean pinned,
        boolean important,
        BigDecimal todayQty,
        java.util.List<SubProgress> subplans,
        BigDecimal plannedInboundQty,
        BigDecimal actualSurplusInboundQty,
        Short status,
        boolean stopped,
        boolean canceled) {

    /** 子计划进度（subplan_links 溯源）。 */
    public record SubProgress(
            UUID planId,
            String billNo,
            String workshopName,
            Short status,
            boolean closed,
            BigDecimal totalQty,
            BigDecimal reportedQty,
            BigDecimal inboundQty,
            String materialState,
            int materialSegmentCount,
            int materialReadySegmentCount,
            BigDecimal materialTotalQty,
            BigDecimal materialReadyQty,
            Double materialPercent,
            boolean canStartNow,
            double percent,
            BigDecimal plannedInboundQty,
            BigDecimal actualSurplusInboundQty) {
    }
}
