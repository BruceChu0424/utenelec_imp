package com.uten.imp.common.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.function.ToLongFunction;

/**
 * 报表查询工具集：六个报表服务（finance / production / purchase / sales / stock / subcontract 的
 * {@code *ReportService}）里逐字重复的私有工具成员，2026-09-16 收敛到本类（原各服务的本地拷贝已删，
 * 调用点改指本类）。只收完全一致的成员；有分歧的留在原服务里（如 finance 的 {@code WhereBuilder}
 * 支持空 fragment 只挂参数、{@code addApprovedByDefault} 用单头别名 {@code t}，sales 的
 * {@code addCommonDocFilters}/{@code addSummaryKw} 含客户名列，production 的 {@code addCommonDocFilters}
 * 取 goodsId）。
 *
 * <p>范式：原生 SQL + EntityManager + 各包自带的 {@code ReportTableResponse}（六包各自定义、结构同型，
 * 故 {@link #paginateAll} 用泛型 + 取数函数适配）。
 */
public final class ReportQueryKit {

    private ReportQueryKit() {}

    /**
     * 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型；
     * orderExpr facet 桶排序表达式（2026-09-16 从六个报表服务收敛：原五组件后追加的可空组件，
     * 仅 purchase 的 execute 读取；其余服务 execute 固定 {@code ORDER BY cnt DESC}，不读它）。
     */
    public record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr,
                            String filterType, String orderExpr) {
        /** 兼容旧调用：默认按命中数倒序（旧行为）。日期等列可显式传 orderExpr 按值排序。 */
        public FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {
            this(key, selectExpr, groupExpr, filterExpr, filterType, "cnt DESC");
        }
    }

    /** WHERE 构造器：base + 若干 AND 子句（带参数）。2026-09-16 从六个报表服务收敛（finance 的空 fragment 变体除外）。 */
    public static final class WhereBuilder {
        private final String base;
        private final List<Clause> clauses = new ArrayList<>();

        public WhereBuilder(String base) { this.base = base; }

        public void add(String fragment, String param, Object val) { clauses.add(new Clause(fragment, param, val)); }

        public Built build(List<Clause> extra) {
            StringBuilder sb = new StringBuilder(base);
            Map<String, Object> params = new LinkedHashMap<>();
            List<Clause> all = new ArrayList<>(clauses);
            if (extra != null) all.addAll(extra);
            for (Clause c : all) {
                sb.append(" AND ").append(c.fragment);
                if (c.param != null) params.put(c.param, c.val);
            }
            return new Built(sb.toString(), params);
        }

        public record Clause(String fragment, String param, Object val) {}
        public record Built(String sql, Map<String, Object> params) {}
    }

    /**
     * 默认口径：草稿（status=0）不进报表（2026-09-16 从 stock/purchase/sales/subcontract 四个报表服务收敛；
     * 单头别名 {@code o}。finance 的钱流单头别名是 {@code t}，其本地拷贝保留）。
     *
     * <p>未审核单据不是经营事实。调用方显式传 status（含 status=0 查草稿、或「未审」facet）
     * 时按其口径走，不叠加本默认值。
     */
    public static void addApprovedByDefault(WhereBuilder w, Short status) {
        if (status != null) {
            w.add("o.status = :status", "status", status);
        } else {
            // 无具名参数的常量片段：WhereBuilder.build 对 param==null 的 Clause 只拼 SQL 不绑参。
            w.add("o.status <> 0", null, null);
        }
    }

    /**
     * 明细主过滤：单号/供应商/仓库/状态/日期/关键字（2026-09-16 从 purchase/subcontract 收敛，两份逐字一致；
     * sales 取 clientId 且关键字含客户名、production 取 goodsId，分歧版本留在原服务）。
     * 主表别名约定：头表 o、明细 i；单号列/日期列由调用方传列名。
     */
    public static void addCommonDocFilters(WhereBuilder w, String billNo, UUID supplierId, UUID warehouseId,
                                           Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                           String billNoCol, String dateCol) {
        if (billNo != null && !billNo.isBlank()) {
            w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        }
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        addApprovedByDefault(w, status);
        if (dateFrom != null) w.add(dateCol + " >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add(dateCol + " <= :dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank()) {
            w.add("(LOWER(" + billNoCol + ") LIKE LOWER(:kw)"
                            + " OR LOWER(COALESCE(i.goods_name_snapshot,'')) LIKE LOWER(:kw)"
                            + " OR LOWER(COALESCE(i.goods_code_snapshot,'')) LIKE LOWER(:kw)"
                            + " OR EXISTS (SELECT 1 FROM goods gg WHERE gg.id = i.goods_id"
                            + " AND LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw)))",
                    "kw", "%" + kw.toLowerCase() + "%");
        }
    }

    /**
     * 汇总关键字：单号模糊匹配（2026-09-16 从 production/purchase/subcontract 收敛，三份逐字一致；
     * sales 的版本额外匹配客户名，留在原服务）。
     */
    public static void addSummaryKw(WhereBuilder w, String kw, String billNoCol) {
        if (kw != null && !kw.isBlank()) w.add("LOWER(" + billNoCol + ") LIKE LOWER(:kw)", "kw", "%" + kw.toLowerCase() + "%");
    }

    /** 从全部查询参数里抽出列筛选（键以 "f." 前缀）。2026-09-16 从六个报表服务（facetsOfMap）与五个
     *  ReportController（facetsOf）收敛；统一用 LinkedHashMap 保插入序（原控制器用 HashMap，序本就不确定，
     *  facet 子句只做 AND，顺序不影响结果）。 */
    public static Map<String, String> facetsOf(Map<String, String> allParams) {
        Map<String, String> facets = new LinkedHashMap<>();
        if (allParams == null) return facets;
        for (Map.Entry<String, String> e : allParams.entrySet()) {
            if (e.getKey().startsWith("f.") && e.getValue() != null && !e.getValue().isBlank()) {
                facets.put(e.getKey().substring(2), e.getValue());
            }
        }
        return facets;
    }

    /** 2026-09-16 从六个报表服务收敛：导出参数解析（空/空白 → null）。 */
    public static UUID parseUuid(String s) { return (s == null || s.isBlank()) ? null : UUID.fromString(s); }

    /** 2026-09-16 从六个报表服务收敛：导出参数解析（空/空白 → null）。 */
    public static Short parseShort(String s) { return (s == null || s.isBlank()) ? null : Short.valueOf(s); }

    /** 2026-09-16 从六个报表服务收敛：导出参数解析（空/空白 → null）。 */
    public static LocalDate parseDate(String s) { return (s == null || s.isBlank()) ? null : LocalDate.parse(s); }

    /**
     * 循环分页(size=500)累积全部行；硬上限 2000 页(=百万行)防失控。列取首页 columns 映射为 ExportColumn。
     * 2026-09-16 从六个报表服务收敛（六份循环体逐字一致；各包 ReportTableResponse 是独立类型，
     * 经 total/exportColumns/rows 三个取数函数适配，exportColumns 返回 null 表示无列——与原
     * {@code r.columns() != null} 判断等价）。
     *
     * @param maxRows 导出行数上限 (系统设置 export_max_rows, 调用方经 ExportLimitPort 读取后传入;
     *                本类不依赖系统设置模块, 保持 common 不反向依赖 features)
     */
    public static <T> ExportPayload paginateAll(int maxRows,
                                                BiFunction<Integer, Integer, T> loader,
                                                ToLongFunction<T> total,
                                                Function<T, List<ExportColumn>> exportColumns,
                                                Function<T, List<Map<String, Object>>> rows) {
        final int size = 500;
        List<Map<String, Object>> all = new ArrayList<>();
        List<ExportColumn> cols = null;
        int page = 1;
        while (page <= 2000) {
            T r = loader.apply(page, size);
            if (page == 1 && total.applyAsLong(r) > maxRows) {
                // 导出行数上限 (系统设置 export_max_rows)：超限要求收窄筛选/分批，防 OOM。
                throw tooManyRows(maxRows);
            }
            if (cols == null) {
                List<ExportColumn> first = exportColumns.apply(r);
                if (first != null) cols = first;
            }
            List<Map<String, Object>> pageRows = rows.apply(r);
            all.addAll(pageRows);
            if (pageRows.size() < size) break;
            if ((long) all.size() >= total.applyAsLong(r)) break;
            page++;
        }
        return new ExportPayload(cols == null ? List.of() : cols, all, all.size());
    }
    /**
     * 主档导出的分页收集 (每页 100 行, 与列表接口的页大小上限一致): 首页 total 超过
     * {@code maxRows} 直接拒绝; 导出过程中行数增长越过上限同样拒绝, 不产出半截文件。
     * 2026-09-23 从货品/客户/供应商/账户/币种五份复制的循环收敛 (audit-retention-settings-11)。
     */
    public static <T> List<Map<String, Object>> collectPages(
            int maxRows,
            BiFunction<Integer, Integer, PageResponse<T>> loader,
            Function<T, Map<String, Object>> mapper) {
        final int size = 100;
        List<Map<String, Object>> rows = new ArrayList<>();
        for (int page = 1; ; page++) {
            PageResponse<T> r = loader.apply(page, size);
            if (page == 1 && r.getTotal() > maxRows) {
                throw tooManyRows(maxRows);
            }
            for (T item : r.getItems()) {
                rows.add(mapper.apply(item));
            }
            if (rows.size() > maxRows) {
                throw tooManyRows(maxRows);
            }
            if (r.getItems().size() < size || rows.size() >= r.getTotal()) {
                return rows;
            }
        }
    }

    private static ApiException tooManyRows(int maxRows) {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                "导出数据超过 " + maxRows + " 行上限 (系统设置「导出行数上限」)，请收窄筛选条件或分批导出");
    }
}
