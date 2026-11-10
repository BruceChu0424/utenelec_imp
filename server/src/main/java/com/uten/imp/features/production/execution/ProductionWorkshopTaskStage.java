package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.util.Set;

/** Server-fact stage shared by synchronous and durable workshop exports.
 * The Dart workshopTaskFlowStage adapter consumes the same v1 contract fixtures.
 * Local report drafts are intentionally not published as approved server facts. */
public final class ProductionWorkshopTaskStage {
    private ProductionWorkshopTaskStage() {}
    private static final Set<String> STARTED = Set.of("IN_PROGRESS", "COMPLETED", "CANCELLED", "REVERSED");
    private static final Set<String> PREPARING = Set.of("WAITING", "READY", "DISPATCHED");
    private static final BigDecimal REPORT_EPSILON = new BigDecimal("0.000001");

    public static String label(ProductionExecutionWorkbenchSegment t) {
        String status = t.segmentStatus() == null ? "" : t.segmentStatus().trim().toUpperCase(java.util.Locale.ROOT);
        String route = t.startRoute() == null ? null : t.startRoute().trim().toUpperCase(java.util.Locale.ROOT);
        boolean continuous = route == null ? t.continuousSupply() : "CONTINUOUS".equals(route);
        boolean ready = "READY".equals(status) || "DISPATCHED".equals(status);
        if (!STARTED.contains(status)) {
            if ("NEED_CHOICE".equals(t.binMaterialState())) return "待认料";
            if ("NEED_BIN".equals(t.binMaterialState())) return "车间内料仓未开启 · 不能开工";
        }
        if (t.materialDiscoveryRequired()) return "PENDING".equals(t.materialDiscoveryStatus())
                ? "待仓库填写物料" : "需要登记领料物料";
        if (t.splitReplaced()) return "已拆分为生产批次";
        if (t.startRoute() == null && PREPARING.contains(status)) return "待选生产路线";
        if (t.materialPlanningGapKindCount() > 0 && !t.zeroMaterial() && PREPARING.contains(status)
                && !t.canStart() && !t.canRequestDraw() && t.materialAwaitingWarehouseKindCount() == 0)
            return (t.planningUrgeCount() > 0 ? "已催计划 · 等下单 " : "等计划下单 · 缺 ")
                    + t.materialPlanningGapKindCount() + " 种";
        if (t.materialKindCount() > 0 && !t.zeroMaterial() && ready) return preparing(t, continuous);
        if (t.materialKindCount() > 0 && !t.zeroMaterial() && "WAITING".equals(status)
                && "FULL_KIT".equals(route) && covered(t) > 0) return coveredLabel(t);
        if (continuous && ready) return t.canStart() ? "部分物料已投 · 可开工"
                : t.canRequestDraw() ? "部分物料可领 · 去领料"
                : t.drawRequested() ? "已提交领料 · 待仓库发料" : "等待物料支持开工";
        if ("IN_PROGRESS".equals(status) && t.remainingReportQty() != null
                && t.remainingReportQty().compareTo(REPORT_EPSILON) <= 0) {
            if (positive(t.fqcPendingQty())) return "已报完 · 待品质检查";
            if (positive(t.finishedInboundPendingQty())) return "品质通过 · 待点收入库";
            if (positive(t.plannedQty()) && amount(t.plannedInboundQty()).compareTo(t.plannedQty()) >= 0)
                return t.hasPendingReturn() && !t.hasAvailableMaterial() ? "已入库 · 待仓库收退料"
                        : t.hasUnregisteredMaterial() ? "已入库 · 待登记实际用料" : "已入库 · 待结清核对";
            return positive(t.fqcFailedQty()) ? "品质异常 · 待处理" : "已报完 · 待仓库登记送检";
        }
        boolean partialIssue = t.partialMaterialReportLimited()!=null ? t.partialMaterialReportLimited()
                : !t.zeroMaterial() && t.materialKindCount()>0 && t.materialIssuedKindCount()<t.materialKindCount();
        return switch (status) {
            case "WAITING" -> "FULL_KIT".equals(route) ? "等待物料到齐 · 齐套生产"
                    : "BATCH".equals(route) ? "等待到货 · 分批生产"
                    : "CONTINUOUS".equals(route) ? "等待部分物料 · 持续生产" : "车间已收到 · 等待物料";
            case "READY", "DISPATCHED" -> t.zeroMaterial() ? "无需领料 · 可开工"
                    : t.issued() ? "物料齐套 · 可开工"
                    : t.drawRequested() ? "已提交领料 · 待仓库发料" : "物料齐套 · 去领料";
            case "IN_PROGRESS" -> partialIssue
                    ? "部分领料生产中 · 按配套报工"
                    : continuous ? "持续生产中 · 按实际投料报工" : "生产中 · 可报工";
            case "COMPLETED" -> "已完工";
            case "CANCELLED" -> "已取消";
            case "REVERSED" -> "已撤回";
            default -> "等待下达车间";
        };
    }

    private static String preparing(ProductionExecutionWorkbenchSegment t, boolean continuous) {
        if (t.canStart()) return t.materialIssuedKindCount() >= t.materialKindCount()
                ? "物料已领齐 · 可开工" : "部分物料已投 · 可开工";
        if (t.canRequestDraw()) return t.materialShortKindCount() > 0
                ? "部分物料可领 · 去领料" : "物料已备齐 · 去领料";
        if (t.materialAwaitingWarehouseKindCount() > 0 || t.drawRequested() && t.materialShortKindCount() == 0)
            return "已提交领料 · 待仓库发料";
        if (t.materialShortKindCount() > 0) return continuous
                ? (t.materialShortMakeKindCount() > 0 ? "等自制子件完成 · 缺 " : "等待到货 · 缺 ")
                    + t.materialShortKindCount() + " 种" : coveredLabel(t);
        return t.materialLineSidePendingKindCount() > 0 ? "直送料待投入 · 等待开工条件" : "备料中 · 等待领料指令";
    }
    private static int covered(ProductionExecutionWorkbenchSegment t) {
        return Math.clamp(t.materialKindCount() - t.materialShortKindCount(), 0, t.materialKindCount());
    }
    private static String coveredLabel(ProductionExecutionWorkbenchSegment t) {
        return "等待物料到齐 · 已备 " + covered(t) + "/" + t.materialKindCount() + " 种";
    }
    private static boolean positive(BigDecimal value) { return amount(value).signum() > 0; }
    private static BigDecimal amount(BigDecimal value) { return value == null ? BigDecimal.ZERO : value; }
}
