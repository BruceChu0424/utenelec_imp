package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.application.port.WorkshopTaskExportContract;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.security.CurrentAuthorityGuard;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

/** Uses the exact workshop task reader, including assignment and history scope.
 * File writing, column projection, encryption and durable jobs remain shared. */
@Service
@RequiredArgsConstructor
public class ProductionWorkshopTaskExportService {
    public static final String REPORT = WorkshopTaskExportContract.REPORT;
    private final ProductionExecutionWorkbenchService tasks;
    private final ExportLimitPort limits;
    @Transactional(readOnly = true)
    public ExportPayload export(Map<String, String> p, String sort, String order) {
        CurrentAuthorityGuard.requireAll("production_execution:view", "production_report:export");
        WorkshopTaskExportContract.validate(p, sort, order);
        String status = p.get("status");
        UUID workshop = ReportQueryKit.parseUuid(p.get("workshopDepartmentId"));
        LocalDate from = ReportQueryKit.parseDate(p.get("dateFrom")), to = ReportQueryKit.parseDate(p.get("dateTo"));
        return ReportQueryKit.paginateAll(limits.exportMaxRows(),
                (page, size) -> tasks.workshopTasks(page, size, p.get("keyword"), status, workshop, from, to,
                        p.get("preparationFilter"), p.get("routeFilter"), p.get("analysisNo"), p.get("segmentCode"), sort, order),
                page -> page.getTotal(), page -> columns(status),
                page -> page.getItems().stream().map(ProductionWorkshopTaskExportService::row).toList());
    }

    public static List<ExportColumn> columns(String status) {
        List<ExportColumn> columns = new ArrayList<>();
        columns.add(new ExportColumn("status", "状态", "text"));
        if ("IN_PROGRESS".equals(status)) columns.add(new ExportColumn("route", "生产路线", "text"));
        if ("PREPARING".equals(status)) columns.add(new ExportColumn("nextStep", "下一步", "text"));
        columns.addAll(List.of(new ExportColumn("segment", "工单号", "text"),
                new ExportColumn("sourcePlan", "来源计划", "text"), new ExportColumn("order", "关联订单", "text")));
        if (!"COMPLETED".equals(status)) columns.add(new ExportColumn("material", "物料", "text"));
        columns.addAll(List.of(new ExportColumn("name", "产品名称", "text"),
                new ExportColumn("productCode", "编号", "text"), new ExportColumn("color", "颜色", "text"),
                new ExportColumn("qty", "产品数量", "qty", null, null, "__unit"),
                new ExportColumn("allowedOverproductionRate", "允许超产比例", "text"),
                new ExportColumn("salesRequirements", "销售生产要求", "text"), new ExportColumn("workshop", "生产车间", "text")));
        if (Set.of("IN_PROGRESS", "REPORT_INSPECTION").contains(status))
            columns.add(new ExportColumn("actualOutput", "实际产出", "text"));
        return List.copyOf(columns);
    }

    static Map<String, Object> row(ProductionExecutionWorkbenchSegment t) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("__recordId", t.segmentId().toString());
        r.put("status", ProductionWorkshopTaskStage.label(t));
        String route = switch (Objects.toString(t.startRoute(), "")) {
            case "FULL_KIT" -> "齐套生产"; case "CONTINUOUS" -> "持续生产"; case "BATCH" -> "分批生产"; default -> "选择生产路线";
        };
        r.put("route", route); r.put("nextStep", route);
        r.put("segment", t.segmentCode()); r.put("sourcePlan", t.analysisNo()); r.put("order", t.salesOrderNos());
        r.put("material", materialText(t));
        r.put("name", t.productName()); r.put("productCode", t.productCode()); r.put("color", t.productColorName());
        r.put("qty", t.plannedQty()); r.put("__unit", t.productUnitName());
        r.put("allowedOverproductionRate", t.overproductionPolicyApplies()
                ? number(t.allowedOverproductionRate().multiply(new BigDecimal("100"))) + "%" : "固定追加量");
        r.put("salesRequirements", t.salesRequirements() == null ? "" : t.salesRequirements().stream()
                .map(n -> java.util.stream.Stream.of(n.orderRemark(), n.itemRemark()).filter(Objects::nonNull)
                        .collect(java.util.stream.Collectors.joining(" / "))).collect(java.util.stream.Collectors.joining("\n")));
        r.put("workshop", t.workshopName());
        r.put("actualOutput", "报工 " + number(t.reportedQty())
                + (positive(t.actualSurplusReportedQty()) ? " · 超产 " + number(t.actualSurplusReportedQty()) : "")
                + (positive(t.overLimitPendingQty()) ? " · 待处理 " + number(t.overLimitPendingQty()) : ""));
        return r;
    }
    private static String materialText(ProductionExecutionWorkbenchSegment t) {
        if ("NEED_BIN".equals(t.binMaterialState())) return "车间内料仓未开启";
        if ("NEED_CHOICE".equals(t.binMaterialState())) return "待认料 · 开工时选用料";
        if (t.materialDiscoveryRequired()) return "PENDING".equals(t.materialDiscoveryStatus()) ? "待仓库填写物料" : "需要登记领料物料";
        boolean fromBin = "KNOWN".equals(t.binMaterialState());
        if (t.zeroMaterial() || t.materialKindCount() == 0) return fromBin ? "车间内料仓供料" : "无需物料";
        List<String> material = new ArrayList<>();
        material.add("已领 " + t.materialIssuedKindCount() + "/" + t.materialKindCount() + " 种");
        if (t.materialShortKindCount() > 0) material.add("缺 " + t.materialShortKindCount() + " 种"
                + (t.materialShortMakeKindCount() > 0 ? "(自制子件 " + t.materialShortMakeKindCount() + ")" : ""));
        if (t.materialPlanningGapKindCount() > 0) material.add("计划未下单 " + t.materialPlanningGapKindCount() + " 种");
        if (t.materialDrawableKindCount() > 0) material.add("可领 " + t.materialDrawableKindCount() + " 种");
        if (t.materialAwaitingWarehouseKindCount() > 0) material.add("待发 " + t.materialAwaitingWarehouseKindCount() + " 种");
        if (fromBin) material.add("另有内料仓供料");
        return String.join(" · ", material);
    }
    private static boolean positive(BigDecimal n) { return n != null && n.signum() > 0; }
    private static String number(BigDecimal n) { return n == null ? "0" : n.stripTrailingZeros().toPlainString(); }
}
