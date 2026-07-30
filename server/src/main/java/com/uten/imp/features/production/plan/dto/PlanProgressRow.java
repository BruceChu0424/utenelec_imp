package com.uten.imp.features.production.plan.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产进度看板行：计划的聚合进度。
 * percent = Σiqty / Σqty（完工入库进度），urgent = 交货 ≤3 天或已逾期，overdue = 交货日已过。
 * todayQty = 今日完工入库量（当日已审 FINISHED_IN 按 plan_draw_links 溯源汇总，基本单位）。
 * 顶层只列父计划；subplans 为拆分生成的子计划进度（点开展示）。
 * closed 为派生口径（所有明细 qty-iqty ≤ 0，与 recomputeClosed 同口径，不依赖 is_closed 是否已重算）。
 * pinned/important 为看板标记（V127）。
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
        BigDecimal inboundQty,
        LocalDate planBeginDate,
        LocalDate planEndDate,
        double percent,
        boolean closed,
        boolean urgent,
        boolean overdue,
        boolean pinned,
        boolean important,
        BigDecimal todayQty,
        java.util.List<SubProgress> subplans) {

    /** 子计划进度（subplan_links 溯源）。 */
    public record SubProgress(
            UUID planId,
            String billNo,
            String workshopName,
            Short status,
            boolean closed,
            BigDecimal totalQty,
            BigDecimal inboundQty,
            double percent) {
    }
}
