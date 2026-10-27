package com.uten.imp.features.production.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportDocument;
import com.uten.imp.common.export.DocumentPageSink;
import com.uten.imp.common.export.LegacyExportBudget;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.report.ReportExportCursor;
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
    public static final int PAGE_ROWS=200,MAX_ROWS=ExportDocument.MAX_SECTION_ROWS,SYNCHRONOUS_MAX_ROWS=LegacyExportBudget.MAX_ROWS;
    private final ProductionWhereUsedQueryService query;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;
    private final EmployeeNameResolver employeeNames;

    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('production_where_used:export')")
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ExportDocument document(UUID materialId, String source, LocalDate from, LocalDate to,
                                   String sort, String order) {
        Collector collector=new Collector();
        emit(materialId,source,from,to,sort,order,false,collector);
        return collector.document();
    }

    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('production_where_used:export')")
    public void streamDocument(UUID materialId,String source,LocalDate from,LocalDate to,String sort,String order) {
        if(DocumentPageSink.current()==null
                || !org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()
                || !org.springframework.transaction.support.TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(java.sql.Connection.TRANSACTION_REPEATABLE_READ).equals(
                org.springframework.transaction.support.TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())) {
            throw new IllegalStateException("A document export requires its active read-only repeatable-read snapshot");
        }
        var authentication=org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication();
        if(authentication==null || !authentication.isAuthenticated() || !(authentication.getPrincipal() instanceof com.uten.imp.security.AuthUser user)
                || !user.isAccountNonLocked() || user.isVisitor() || user.isMustChangePassword() || user.getImpersonatedBy()!=null
                || !user.getPermissions().contains("production_where_used:view")
                || !user.getPermissions().contains("production_where_used:export"))throw new ApiException(ErrorCode.FORBIDDEN);
        // Own this cursor even when a caller has another outer report cursor scope.
        try(var cursor=ReportExportCursor.open()) {
            emit(materialId,source,from,to,sort,order,true,DocumentPageSink.current());
        }
    }

    private ReportTableResponse read(UUID material,String source,LocalDate from,LocalDate to,int page,
                                     String sort,String order) {
        return query.whereUsedExportPage(material,source,from,to,page,PAGE_ROWS,sort,order,page==1);
    }
    private void emit(UUID material,String source,LocalDate from,LocalDate to,String sort,String order,
                      boolean streaming,DocumentPageSink.Consumer sink) {
        if(material==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择组件后导出");
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ALL)) {
            ReportTableResponse response=read(material,source,from,to,1,sort,order);
            long expected=response.total();
            int maximum=streaming?MAX_ROWS:SYNCHRONOUS_MAX_ROWS;
            if(expected<0)throw new IllegalStateException("The document source did not supply its primary row count");
            if(!streaming)LegacyExportBudget.requireRows(expected);
            if(expected>maximum)throw new ApiException(ErrorCode.VALIDATION_FAILED,streaming
                    ?"筛选结果超过 50000 行，请缩小范围后导出":"同步导出最多 500 行，请使用后台导出任务");
            Prepared prepared=prepare(material,source,from,to,sort,order,response);
            List<com.uten.imp.features.production.report.ReportColumn> columns=response.columns();
            String unit=prepared.unit();
            sink.begin(prepared.header());
            long processed=0;
            int pages=Math.max(1,ReportReadPlan.totalPages(expected,PAGE_ROWS));
            for(int page=1;page<=pages;page++) {
                LegacyExportBudget.checkpoint();
                if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
                if(page>1)response=read(material,source,from,to,page,sort,order);
                if(response.page()!=page || response.size()!=PAGE_ROWS || response.total()!=expected
                        || !response.columns().equals(columns) || response.rows().size()>PAGE_ROWS
                        || (response.rows().isEmpty()&&processed<expected))throw new IllegalStateException("Document pagination changed or ended early");
                processed+=response.rows().size();
                if(processed>expected)throw new IllegalStateException("Document source row count changed");
                var sections=sections(columns,response.rows(),unit);
                for(int index=0;index<sections.size();index++)if(!sections.get(index).rows().isEmpty())
                    sink.accept(new DocumentPageSink.Page("section-"+index,sections.get(index).rows()));
            }
            if(processed!=expected)throw new IllegalStateException("Document source row count is incomplete");
        }
    }

    private record Prepared(DocumentPageSink.Header header,String unit) {}
    private Prepared prepare(UUID materialId,String source,LocalDate from,LocalDate to,String sort,String order,
                                     ReportTableResponse first) {
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
                "共 " + first.total() + " 个产品；导出全部筛选结果，不限于当前页。",
                "当前 BOM 表示查询时有效的理论关系；日期仅筛选历史证据。",
                "生产冻结需求、旧生产快照与委外证据各自列示，不相加、不代表实际耗用。",
                "未归属到具体产品的旧需求：" + first.meta().getOrDefault("unattributedDemandCount", 0)
                        + " 条，需求量 " + first.meta().getOrDefault("unattributedDemandQty", 0) + " (原证据单位)。",
                "历史用量保留原证据口径，不用当前货品单位推定或换算；不同来源的数量不相加。");
        var definitions=sections(first.columns(),List.of(),unit);
        List<DocumentPageSink.Section> declarations=new ArrayList<>();
        for(int index=0;index<definitions.size();index++) {
            var section=definitions.get(index);
            declarations.add(new DocumentPageSink.Section("section-"+index,section.name(),section.columns(),index==0,index>0));
        }
        return new Prepared(new DocumentPageSink.Header("物料反查与追溯 · 关系筛选结果",metadata,declarations,first.total()),unit);
    }

    private static List<ExportDocument.Section> sections(List<ReportColumn> reportColumns,List<Map<String,Object>> rows,String unit) {
        List<ExportColumn> columns = reportColumns.stream().map(column ->
                new ExportColumn(column.key(), column.label(), column.type(),
                        column.width() == null ? null : column.width().doubleValue(),
                        column.unitLabel(), column.unitKey())).toList();
        List<ExportDocument.Section> sections = new ArrayList<>();
        sections.add(new ExportDocument.Section("组件使用产品", columns, rows));
        var current = rows.stream().filter(row -> Boolean.TRUE.equals(row.get("__currentBom"))
                || Boolean.TRUE.equals(row.get("__invalidBom"))).toList();
        sections.add(new ExportDocument.Section("当前组装依据", List.of(
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
        return sections;
    }

    private static void addEvidenceSection(List<ExportDocument.Section> sections, List<Map<String, Object>> rows,
                                           String name, String evidenceKey, List<ExportColumn> evidenceColumns) {
        List<Map<String, Object>> evidence = rows.stream().filter(row -> positive(row.get(evidenceKey))
                || name.startsWith("委外") && (positive(row.get("__subcontractIssueEvidenceCount"))
                || positive(row.get("__executionSubcontractEvidenceCount")))).toList();
        List<ExportColumn> columns = new ArrayList<>(List.of(new ExportColumn("goodsName", "产品名称", "text"),
                new ExportColumn("goodsCode", "产品编号", "text"), new ExportColumn("colorName", "颜色", "text")));
        columns.addAll(evidenceColumns);
        sections.add(new ExportDocument.Section(name, columns, evidence));
    }

    private static boolean positive(Object value) { return value instanceof Number number && number.doubleValue() > 0; }

    static String sourceLabel(String source) {
        return switch (source==null?"all":source.trim().toLowerCase(java.util.Locale.ROOT)) {
            case "current" -> "当前 BOM";
            case "history" -> "全部历史";
            case "production" -> "生产关系";
            case "subcontract" -> "委外关系";
            default -> "全部已知关系";
        };
    }

    private static final class Collector implements DocumentPageSink.Consumer {
        DocumentPageSink.Header header;
        final Map<String,List<Map<String,Object>>> rows=new java.util.LinkedHashMap<>();
        @Override public void begin(DocumentPageSink.Header value){header=value;for(var section:value.sections())rows.put(section.id(),new ArrayList<>());}
        @Override public void accept(DocumentPageSink.Page page){rows.get(page.sectionId()).addAll(page.rows());}
        ExportDocument document(){return new ExportDocument(header.title(),header.metadata(),header.sections().stream()
                .filter(section->!section.omitIfEmpty()||!rows.get(section.id()).isEmpty())
                .map(section->new ExportDocument.Section(section.name(),section.columns(),rows.get(section.id()))).toList());}
    }
}
