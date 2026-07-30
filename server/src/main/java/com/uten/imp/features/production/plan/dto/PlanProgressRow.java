package com.uten.imp.features.production.plan.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产进度看板行：计划的聚合进度。
 * percent = Σiqty / Σqty（完工入库进度），urgent = 交货 ≤3 天或已逾期。
 * 顶层只列父计划；subplans 为拆分生成的子计划进度（点开展示）。
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
