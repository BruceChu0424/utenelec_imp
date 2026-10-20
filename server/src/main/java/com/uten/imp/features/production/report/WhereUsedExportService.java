package com.uten.imp.features.production.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportDocument;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Export the entire filtered relationship result in one database snapshot. */
@Service
@RequiredArgsConstructor
public class WhereUsedExportService {
    private final ProductionWhereUsedQueryService query;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;
    private final EmployeeNameResolver employeeNames;

    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('production_where_used:export')")
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ExportDocument document(UUID materialId, String source, LocalDate from, LocalDate to,
                                   String sort, String order) {
        ReportTableResponse first = query.whereUsed(materialId, source, from, to, 1, 200, sort, order);
        if (first.total() > 50_000) throw new ApiException(ErrorCode.VALIDATION_FAILED,
                "筛选结果超过 50000 行，请缩小范围后导出");
        List<Map<String, Object>> rows = new ArrayList<>(first.rows());
        for (int page = 2; page <= first.totalPages(); page++) {
            rows.addAll(query.whereUsed(materialId, source, from, to, page, 200, sort, order).rows());
        }
        List<?> material = em.createNativeQuery("""
                SELECT g.code,g.name,u.name FROM goods g LEFT JOIN units u
                ON u.id=g.unit_id OR (g.unit_id IS NULL AND u.legacy_id=g.unit_legacy_id)
                WHERE g.id=:id
                """)
                .setParameter("id", materialId).getResultList();
        String identity = materialId.toString();
        String unit = "原基本单位";
        if (!material.isEmpty()) {
            Object[] values = (Object[]) material.getFirst();
            identity = String.valueOf(values[1]) + " / " + String.valueOf(values[0]) + " / " + materialId;
            if (values[2] != null) unit = String.valueOf(values[2]);
        }
        String operator = currentUser.get().map(user -> {
            String name = employeeNames.nameWithCodeOf(user.getEmployeeId() == null ? user.getId() : user.getEmployeeId());
            return name == null || name.isBlank() ? user.getLoginAccount() + " / " + user.getId() : name;
        })
                .orElseThrow(() -> new IllegalStateException("当前无登录用户"));
        List<String> metadata = List.of(
                "当前组件：" + identity,
                "筛选来源：" + sourceLabel(source),
                "历史日期：" + (from == null ? "不限" : from) + " 至 " + (to == null ? "不限" : to),
                "排序：" + (sort == null ? "默认" : sort) + " / " + (order == null ? "asc" : order),
                "操作员：" + operator,
                "导出时间：" + OffsetDateTime.now(ZoneId.of("Asia/Shanghai")),
                "共 " + rows.size() + " 个产品；导出全部筛选结果，不限于当前页。",
                "当前 BOM 表示查询时有效的理论关系；日期仅筛选历史证据。",
                "生产冻结需求、旧生产快照与委外证据各自列示，不相加、不代表实际耗用。",
                "未归属到具体产品的旧需求：" + first.meta().getOrDefault("unattributedDemandCount", 0)
                        + " 条，需求量 " + first.meta().getOrDefault("unattributedDemandQty", 0) + " (原证据单位)。",
                "历史用量保留原证据口径，不用当前货品单位推定或换算；不同来源的数量不相加。");
        List<ExportColumn> columns = first.columns().stream().map(column ->
                new ExportColumn(column.key(), column.label(), column.type(),
                        column.width() == null ? null : column.width().doubleValue(),
                        column.unitLabel(), column.unitKey())).toList();
        List<ExportDocument.Section> sections = new ArrayList<>();
        sections.add(new ExportDocument.Section("组件使用产品", columns, rows));
        var current = rows.stream().filter(row -> Boolean.TRUE.equals(row.get("__currentBom"))
                || Boolean.TRUE.equals(row.get("__invalidBom"))).toList();
        if (!current.isEmpty()) sections.add(new ExportDocument.Section("当前组装依据", List.of(
                new ExportColumn("goodsName", "产品名称", "text"), new ExportColumn("goodsCode", "产品编号", "text"),
                new ExportColumn("colorName", "颜色", "text"), new ExportColumn("bomRelation", "组装关系", "text"),
                new ExportColumn("__currentDirectQty", "直接单套设计用量", "qty", null, unit, null),
                new ExportColumn("__invalidBom", "存在无效用量路径", "bool")), current));
        addEvidenceSection(sections, rows, "新生产需求依据", "__executionEvidenceCount", List.of(
                new ExportColumn("__executionEvidenceCount", "需求证据数", "number"),
                new ExportColumn("executionSegmentCount", "有效生产段数", "number"),
                new ExportColumn("__executionRequiredQty", "冻结需求量", "qty"),
                new ExportColumn("__executionPerProductMin", "单套用量下限", "qty"),
                new ExportColumn("__executionPerProductMax", "单套用量上限", "qty"),
                new ExportColumn("__executionFirstUsed", "首次历史使用", "date"),
                new ExportColumn("__executionLastUsed", "最近历史使用", "date")));
        addEvidenceSection(sections, rows, "旧生产快照依据", "__legacyEvidenceCount", List.of(
                new ExportColumn("__legacyEvidenceCount", "快照证据数", "number"),
                new ExportColumn("legacyPlanCount", "有效旧生产计划数", "number"),
                new ExportColumn("legacyRequiredQty", "旧展开需求量", "qty"),
                new ExportColumn("__legacyIssuedQty", "领料痕迹数量", "qty"),
                new ExportColumn("__legacyReturnedQty", "退料痕迹数量", "qty"),
                new ExportColumn("__legacyFirstUsed", "首次历史使用", "date"),
                new ExportColumn("__legacyLastUsed", "最近历史使用", "date")));
        addEvidenceSection(sections, rows, "委外需求与历史依据", "__subcontractOrderEvidenceCount", List.of(
                new ExportColumn("__executionSubcontractEvidenceCount", "新委外冻结需求证据数", "number"),
                new ExportColumn("__executionSubcontractRequiredQty", "新委外冻结需求量", "qty"),
                new ExportColumn("__subcontractOrderEvidenceCount", "旧委外订货证据数", "number"),
                new ExportColumn("__subcontractRequiredQty", "旧委外理论需求量", "qty"),
                new ExportColumn("__subcontractIssueEvidenceCount", "旧委外发料痕迹数", "number"),
                new ExportColumn("__subcontractIssueQty", "旧发料数量(待核)", "qty"),
                new ExportColumn("__subcontractReturnedQty", "旧退料数量(待核)", "qty"),
                new ExportColumn("__subcontractWastedQty", "旧损耗数量(待核)", "qty")));
        return new ExportDocument("物料反查与追溯 · 关系筛选结果", metadata, sections);
    }

    private static void addEvidenceSection(List<ExportDocument.Section> sections, List<Map<String, Object>> rows,
                                           String name, String evidenceKey, List<ExportColumn> evidenceColumns) {
        List<Map<String, Object>> evidence = rows.stream().filter(row -> positive(row.get(evidenceKey))
                || name.startsWith("委外") && (positive(row.get("__subcontractIssueEvidenceCount"))
                || positive(row.get("__executionSubcontractEvidenceCount")))).toList();
        if (evidence.isEmpty()) return;
        List<ExportColumn> columns = new ArrayList<>(List.of(new ExportColumn("goodsName", "产品名称", "text"),
                new ExportColumn("goodsCode", "产品编号", "text"), new ExportColumn("colorName", "颜色", "text")));
        columns.addAll(evidenceColumns);
        sections.add(new ExportDocument.Section(name, columns, evidence));
    }

    private static boolean positive(Object value) { return value instanceof Number number && number.doubleValue() > 0; }

    static String sourceLabel(String source) {
        return switch (source) {
            case "current" -> "当前 BOM";
            case "history" -> "全部历史";
            case "production" -> "生产关系";
            case "subcontract" -> "委外关系";
            default -> "全部已知关系";
        };
    }
}
