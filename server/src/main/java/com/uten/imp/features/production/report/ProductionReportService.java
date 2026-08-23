package com.uten.imp.features.production.report;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.BiFunction;

/**
 * 生产报表查询（design §6.2）。
 *
 * <p>两类入口（服务端 JOIN 出"显示就绪"行 + 列 facet 表头筛选 + 分页，范式同采购/销售报表）：
 * <ol>
 *   <li><b>生产计划明细</b> {@link #planDetail} → production_plan_items JOIN production_plans
 *       + goods/material_categories/colors（货品/类别/颜色名称服务端解析）。一行=单里一样货品。</li>
 *   <li><b>生产计划汇总</b> {@link #planSummary} → production_plans JOIN employees
 *       （制单员/审核员名）。一行=一整张单（单据级，<b>不走 MV</b>）。</li>
 * </ol>
 *
 * <p>人员名：制单员/审核员 {@code COALESCE(em.full_name, p.*_name)}——
 * em 经 {@code *_legacy_id} OR-JOIN employees（HR 录入 legacy_id 后用真名），否则用迁移期冻结的老库
 * Sys_Operator.fname / B_Worker.Emp_Name（migrate 双表 COALESCE 取名，同委外范式）。
 * 跟单员/车间负责人在老库是 varchar 文本名，直接显示（非 ID，免 JOIN）。
 *
 * <p><b>null 参数类型坑</b>：可选过滤由 {@link WhereBuilder#add} 仅在值非空时追加（不传 null 进 SQL）；
 * 列 facet 绑定走 {@link #facetClause} 的显式 CAST（见 MEMORY「hibernate-native-query-null-param-type」）。
 *
 * <p>保留：{@link #monthly}（MV 上卷，未来月度分析）、{@link #dailyDetail}（日报 0 行结构留位）。
 */
@Service
@RequiredArgsConstructor
public class ProductionReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;
    private final SystemSettingsService settings;

    // ======================== 通用执行器 ========================

    /**
     * 跑一张报表：data + count + 各 facet。
     *
     * @param columns     列定义（顺序 = dataSelect 投影顺序）
     * @param dataSelect  "SELECT i.bill_no AS billNo, ..."（别名 = 列 key，顺序 = columns）
     * @param fromJoin    "FROM ... JOIN ..."（主表别名约定：明细 i + 头表 p；汇总 p）
     * @param mainWhere   主过滤（单号/货品/状态/日期/关键字）
     * @param orderBy     排序（不含 ORDER BY 关键字）
     * @param specs       可 facet 列
     * @param activeFacets 当前激活的列筛选（colKey → 值，NULL_FACET 表空值档）
     */
    @Transactional(readOnly = true)
    public ReportTableResponse execute(List<ReportColumn> columns, String dataSelect, String fromJoin,
                                       WhereBuilder mainWhere, String orderBy, List<FacetSpec> specs,
                                       Map<String, String> activeFacets, int page, int size,
                                       String sort, String order) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        List<WhereBuilder.Clause> facetClauses = new ArrayList<>();
        if (activeFacets != null) {
            for (Map.Entry<String, String> e : activeFacets.entrySet()) {
                FacetSpec spec = specs.stream().filter(s -> s.key().equals(e.getKey())).findFirst().orElse(null);
                if (spec != null && e.getValue() != null && !e.getValue().isBlank()) {
                    facetClauses.add(facetClause(spec, e.getValue()));
                }
            }
        }
        WhereBuilder.Built full = mainWhere.build(facetClauses);
        WhereBuilder.Built baseB = mainWhere.build(null);

        // data
        // 列排序：sort 必须命中 columns 的 key（白名单，防 SQL 注入）；命中则按投影别名排序，否则用默认 orderBy。
        var sortKeys = new java.util.HashSet<String>();
        for (ReportColumn c : columns) sortKeys.add(c.key());
        String effectiveOrderBy = ReportSort.resolveOrderBy(sort, order, orderBy, sortKeys);

        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql()
                + " ORDER BY " + effectiveOrderBy + " LIMIT :__limit OFFSET :__offset");
        full.params().forEach(dataQ::setParameter);
        dataQ.setParameter("__limit", safeSize);
        dataQ.setParameter("__offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < columns.size(); i++) m.put(columns.get(i).key(), norm(r[i]));
            items.add(m);
        }

        // count
        var countQ = em.createNativeQuery("SELECT COUNT(*) " + fromJoin + " " + full.sql());
        full.params().forEach(countQ::setParameter);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

        // facets（用主过滤 baseB，不含列自身筛选）
        Map<String, List<ReportFacet>> facets = new LinkedHashMap<>();
        for (FacetSpec spec : specs) {
            var fq = em.createNativeQuery("SELECT " + spec.selectExpr() + ", COUNT(*) AS cnt " + fromJoin + " "
                    + baseB.sql() + " GROUP BY " + spec.groupExpr() + " ORDER BY cnt DESC LIMIT 50");
            baseB.params().forEach(fq::setParameter);
            @SuppressWarnings("unchecked")
            List<Object[]> frs = fq.getResultList();
            List<ReportFacet> buckets = new ArrayList<>();
            for (Object[] fr : frs) {
                Object v = fr[0];
                String val = (v == null) ? ReportTableResponse.NULL_FACET : Objects.toString(v);
                String lbl = (v == null) ? "(空)" : (fr[1] == null ? null : fr[1].toString());
                long cnt = ((Number) fr[2]).longValue();
                buckets.add(new ReportFacet(val, lbl, cnt));
            }
            facets.put(spec.key(), buckets);
        }

        // 隐藏元数据列（key 以 "__" 开头，如行跳源头用的 __srcId）：不进返回的 columns（前端不渲染、
        // 导出 Excel 不含），但行 Map 已 put 其值（前端 onRowTap 可读 row['__srcId'] 跳对应单据编辑页）。
        List<ReportColumn> visible = columns.stream().filter(c -> !c.key().startsWith("__")).toList();
        return new ReportTableResponse(visible, items, facets, safePage, safeSize, total, totalPages);
    }

    private static Object norm(Object v) {
        if (v == null) return null;
        if (v instanceof java.sql.Date d) return d.toLocalDate().toString();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate().toString();
        if (v instanceof BigDecimal || v instanceof Boolean || v instanceof Number) return v;
        if (v instanceof UUID u) return u.toString();
        return v.toString();
    }

    private static WhereBuilder.Clause facetClause(FacetSpec spec, String value) {
        String p = "facet_" + spec.key();
        if (ReportTableResponse.NULL_FACET.equals(value)) {
            return new WhereBuilder.Clause("(" + spec.filterExpr() + ") IS NULL", null, null);
        }
        return switch (spec.filterType()) {
            case "uuid"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS uuid)", p, UUID.fromString(value));
            case "int"   -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS int)", p, Integer.valueOf(value));
            case "bool"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS boolean)", p, Boolean.valueOf(value));
            default      -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS text)", p, value);
        };
    }

    // ======================== 主过滤构造（公共） ========================

    /** 明细主过滤：单号/货品/状态/日期/关键字（关键字匹配 单号+货品名/编号/型号+生产流水号）。 */
    private static void addCommonDocFilters(WhereBuilder w, String billNo, UUID goodsId, Short status,
                                            LocalDate dateFrom, LocalDate dateTo, String kw,
                                            String billNoCol, String dateCol) {
        if (billNo != null && !billNo.isBlank()) {
            w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        }
        if (goodsId != null) w.add("i.goods_id = :goodsId", "goodsId", goodsId);
        if (status != null) w.add("p.status = :status", "status", status);
        if (dateFrom != null) w.add(dateCol + " >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add(dateCol + " <= :dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank()) {
            w.add("(LOWER(" + billNoCol + ") LIKE LOWER(:kw)"
                    + " OR LOWER(COALESCE(i.product_no,'')) LIKE LOWER(:kw)"
                    + " OR EXISTS (SELECT 1 FROM goods gg WHERE gg.id = i.goods_id"
                    + " AND (LOWER(gg.name) LIKE LOWER(:kw) OR LOWER(COALESCE(gg.code,'')) LIKE LOWER(:kw)"
                    + " OR LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw))))",
                    "kw", "%" + kw.toLowerCase() + "%");
        }
    }

    private static void addSummaryKw(WhereBuilder w, String kw, String billNoCol) {
        if (kw != null && !kw.isBlank()) w.add("LOWER(" + billNoCol + ") LIKE LOWER(:kw)", "kw", "%" + kw.toLowerCase() + "%");
    }

    // ======================== ① 生产计划明细（参数化分页，不走 MV） ========================

    /** 生产计划明细：按 单号/货品/状态/日期/关键字 过滤，服务端 JOIN 出货品/类别/颜色名称。 */
    @Transactional(readOnly = true)
    public ReportTableResponse planDetail(String billNo, UUID goodsId, Short status, LocalDate dateFrom,
                                          LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("workshop", "生产车间", 120),
                ReportColumn.text("seller", "跟单员", 100),
                ReportColumn.text("fStyle", "生产方式", 100),
                ReportColumn.date("shipmentDate", "出货日期"),
                ReportColumn.bool("approved", "是否审核"),
                ReportColumn.bool("closed", "是否完成"),
                ReportColumn.text("salesOrderNo", "销售订货单号", 130),
                ReportColumn.text("clientName", "客户名称", 140),
                ReportColumn.date("orderDate", "下订日期"),
                ReportColumn.date("deliveryDate", "交货日期"),
                ReportColumn.text("productNo", "生产流水号", 130),
                ReportColumn.text("categoryName", "类别", 100),
                ReportColumn.text("series", "系列", 90),
                ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("oqty", "订货数量"),
                ReportColumn.number("qty", "排产数量"),
                ReportColumn.date("planBeginDate", "计划开工日期"),
                ReportColumn.date("planEndDate", "计划完工日期"),
                ReportColumn.number("iqty", "完工数量"),
                ReportColumn.text("requestNote", "特殊要求", 140),
                ReportColumn.text("summary", "摘要", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳生产计划编辑页
        String dataSelect = """
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate",
                       p.workshop_name AS "workshop", p.seller_name AS "seller", p.f_style AS "fStyle",
                       p.delivery_date AS "shipmentDate", (p.status = 1) AS "approved", p.is_closed AS "closed",
                       i.sales_order_no AS "salesOrderNo", i.client_name AS "clientName",
                       i.order_date AS "orderDate", i.outbound_date AS "deliveryDate",
                       i.product_no AS "productNo", mc.name AS "categoryName", g.series AS "series",
                       g.code AS "goodsCode", g.model AS "model", i.customer_model AS "customerModel",
                       g.name AS "goodsName", g.spec AS "spec", col.name AS "colorName",
                       i.oqty AS "oqty", i.qty AS "qty",
                       i.plan_begin_date AS "planBeginDate", i.plan_end_date AS "planEndDate",
                       i.iqty AS "iqty", i.request_note AS "requestNote", i.remark AS "summary",
                       p.id AS "__srcId"
                """;
        String fromJoin = """
                FROM production_plan_items i
                JOIN production_plans p ON p.id = i.plan_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN material_categories mc ON mc.id = g.category_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(p.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, goodsId, status, dateFrom, dateTo, kw, "i.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                new FacetSpec("approved", "(p.status = 1) AS v, CASE WHEN (p.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(p.status = 1)", "p.status = 1", "bool"),
                new FacetSpec("closed", "p.is_closed AS v, CASE WHEN p.is_closed THEN '已完成' ELSE '未完成' END AS lbl", "p.is_closed", "p.is_closed", "bool"),
                new FacetSpec("workshop", "p.workshop_name AS v, p.workshop_name AS lbl", "p.workshop_name", "p.workshop_name", "text"),
                new FacetSpec("categoryName", "CAST(g.category_id AS text) AS v, mc.name AS lbl", "g.category_id, mc.name", "g.category_id", "uuid"));
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, i.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ② 生产计划汇总（单据级，一行一单，不走 MV） ========================

    /** 生产计划汇总：一行=一整张生产计划单（单据级）。制单员/审核员 COALESCE(employees, 冻结名)。 */
    @Transactional(readOnly = true)
    public ReportTableResponse planSummary(String billNo, Short status, LocalDate dateFrom, LocalDate dateTo,
                                           String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("fStyle", "生产方式", 100),
                ReportColumn.date("shipmentDate", "出货日期"),
                ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100),
                ReportColumn.text("remark", "备注", 180),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳生产计划编辑页
        String dataSelect = """
                SELECT p.bill_no AS "billNo", p.bill_date AS "billDate", p.f_style AS "fStyle",
                       p.delivery_date AS "shipmentDate",
                       COALESCE(em_mk.full_name, p.maker_name) AS "makerName",
                       COALESCE(em_ap.full_name, p.approver_name) AS "approverName",
                       p.remark AS "remark",
                       p.id AS "__srcId"
                """;
        String fromJoin = """
                FROM production_plans p
                LEFT JOIN employees em_mk ON em_mk.id = p.maker_id
                    OR (p.maker_id IS NULL AND em_mk.legacy_id = p.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id = p.approver_id
                    OR (p.approver_id IS NULL AND em_ap.legacy_id = p.approver_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(p.is_deleted,false)=false"
                // 汇总只显示父计划：拆分生成的子计划（subplan_links）不出现在汇总，明细报表仍全量
                + " AND p.id NOT IN (SELECT subplan_id FROM subplan_links WHERE is_deleted = false)");
        if (billNo != null && !billNo.isBlank()) w.add("p.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (status != null) w.add("p.status = :status", "status", status);
        if (dateFrom != null) w.add("p.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("p.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "p.bill_no");
        List<FacetSpec> specs = List.of(
                new FacetSpec("approved", "(p.status = 1) AS v, CASE WHEN (p.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(p.status = 1)", "p.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "p.bill_date DESC, p.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== 旧版 PPC-only 反查快照（仅保留迁移核对） ========================

    // ======================== 导出（加密 Excel） ========================

    /**
     * 导出某报表全量（不分页，循环 size=500 累积全部行），返回 ExportColumn + 行 Map。
     * 列定义映射 ReportColumn→ExportColumn（剥离 width）。report 取值与 GET 路径一致：
     * plan/detail / plan/summary。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(String report, Map<String, String> p, String sort, String order) {
        String billNo = p == null ? null : p.get("billNo");
        UUID goodsId = parseUuid(p == null ? null : p.get("goodsId"));
        Short status = parseShort(p == null ? null : p.get("status"));
        LocalDate dateFrom = parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = parseDate(p == null ? null : p.get("dateTo"));
        String kw = p == null ? null : p.get("keyword");
        Map<String, String> facets = facetsOfMap(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (report) {
            case "plan/detail"  -> (pg, sz) -> planDetail(billNo, goodsId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "plan/summary" -> (pg, sz) -> planSummary(billNo, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报表: " + report);
        };
        return paginateAll(loader);
    }

    /** 循环分页(size=500)累积全部行；硬上限 2000 页(=百万行)防失控。列取首页 columns 映射为 ExportColumn。 */
    private ExportPayload paginateAll(BiFunction<Integer, Integer, ReportTableResponse> loader) {
        final int size = 500;
        List<Map<String, Object>> all = new ArrayList<>();
        List<ExportColumn> cols = null;
        int page = 1;
        while (page <= 2000) {
            ReportTableResponse r = loader.apply(page, size);
            if (page == 1 && r.total() > settings.readInt("export_max_rows", 100000)) {
                // 大数据量导出内存安全上限：超 10 万行要求收窄筛选/分批，防 OOM。
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出数据超过 10 万行上限，请收窄筛选条件或分批导出");
            }
            if (cols == null && r.columns() != null) {
                cols = r.columns().stream()
                        .map(c -> new ExportColumn(c.key(), c.label(), c.type()))
                        .toList();
            }
            all.addAll(r.rows());
            if (r.rows().size() < size) break;
            if ((long) all.size() >= r.total()) break;
            page++;
        }
        return new ExportPayload(cols == null ? List.of() : cols, all, all.size());
    }

    private static Map<String, String> facetsOfMap(Map<String, String> p) {
        Map<String, String> facets = new LinkedHashMap<>();
        if (p == null) return facets;
        for (Map.Entry<String, String> e : p.entrySet()) {
            if (e.getKey().startsWith("f.") && e.getValue() != null && !e.getValue().isBlank()) {
                facets.put(e.getKey().substring(2), e.getValue());
            }
        }
        return facets;
    }

    private static UUID parseUuid(String s) { return (s == null || s.isBlank()) ? null : UUID.fromString(s); }
    private static Short parseShort(String s) { return (s == null || s.isBlank()) ? null : Short.valueOf(s); }
    private static LocalDate parseDate(String s) { return (s == null || s.isBlank()) ? null : LocalDate.parse(s); }

    // ======================== 保留：月度汇总（MV 上卷，未来月度分析用） ========================

    /** 月度汇总：按 docType(PLAN/DAILY) + 日期范围（ym）过滤，按 货品 上卷（保留入口，未挂前端）。 */
    @Transactional(readOnly = true)
    public List<MonthlySummaryRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, client_id,
                       SUM(plan_qty_sum)      AS plan_qty,
                       SUM(order_qty_sum)     AS order_qty,
                       SUM(finished_qty_sum)  AS finished_qty,
                       SUM(inbound_qty_sum)   AS inbound_qty,
                       SUM(line_cnt)          AS lines
                FROM production_monthly_mv
                WHERE (CAST(:docType AS text) IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                GROUP BY doc_type, ym, goods_id, client_id
                ORDER BY ym DESC, plan_qty DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("docType", docType);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new MonthlySummaryRow(
                (String) r[0],
                NativeValueConverters.toLocalDate(r[1]),
                (UUID) r[2],
                NIL.equals(r[3]) ? null : (UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                (BigDecimal) r[6],
                (BigDecimal) r[7],
                ((Number) r[8]).longValue()
        )).toList();
    }

    // ======================== 保留：生产日报明细（本期 0 行，结构留位） ========================

    /** 生产日报明细：参数化分页，<b>本期 0 行</b>（F_DateReport 老库从未启用，design §3.4）。保留入口未挂前端。 */
    @Transactional(readOnly = true)
    public List<DailyDetailRow> dailyDetail(LocalDate dateFrom, LocalDate dateTo, UUID goodsId,
                                            Short status, String billNo, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        var q = em.createNativeQuery("""
                SELECT i.id, i.bill_no, i.bill_date, i.report_id, i.line_no,
                       i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                       i.qty, i.price, i.total, i.stotal,
                       i.sales_order_item_id, i.sales_order_no,
                       i.plan_item_id, i.plan_no, i.outbound_no, i.outbound_qty, i.order_qty,
                       i.step_legacy_id, i.order_date, i.boxes, i.per_box_qty, i.weight,
                       i.client_name, h.status, i.legacy_id, i.remark
                FROM production_daily_report_items i
                JOIN production_daily_reports h ON h.id = i.report_id
                WHERE COALESCE(i.is_deleted, false) = false
                  AND COALESCE(h.is_deleted, false) = false
                  AND (CAST(:from AS date) IS NULL OR i.bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR i.bill_date <= :to)
                  AND (CAST(:goodsId AS uuid) IS NULL OR i.goods_id = :goodsId)
                  AND (CAST(:status AS smallint) IS NULL OR h.status   = :status)
                  AND (CAST(:billNo AS text) IS NULL OR i.bill_no  = :billNo)
                ORDER BY i.bill_date DESC, i.line_no ASC
                LIMIT :limit OFFSET :offset
                """);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("goodsId", goodsId);
        q.setParameter("status", status);
        q.setParameter("billNo", billNo);
        q.setParameter("limit", safeSize);
        q.setParameter("offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new DailyDetailRow(
                (UUID) r[0],
                (String) r[1],
                NativeValueConverters.toLocalDate(r[2]),
                (UUID) r[3],
                (Integer) r[4],
                (UUID) r[5],
                (UUID) r[6],
                (UUID) r[7],
                (BigDecimal) r[8],
                (BigDecimal) r[9],
                (BigDecimal) r[10],
                (BigDecimal) r[11],
                (BigDecimal) r[12],
                (UUID) r[13],
                (String) r[14],
                (UUID) r[15],
                (String) r[16],
                (String) r[17],
                (BigDecimal) r[18],
                (BigDecimal) r[19],
                (Integer) r[20],
                r[21] == null ? null : NativeValueConverters.toLocalDate(r[21]),
                (BigDecimal) r[22],
                (BigDecimal) r[23],
                (BigDecimal) r[24],
                (String) r[25],
                (Short) r[26],
                (Integer) r[27],
                (String) r[28]
        )).toList();
    }

    // ======================== 内部结构 ========================

    /** 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型。 */
    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {}

    /** WHERE 构造器：base + 若干 AND 子句（带参数）。 */
    static final class WhereBuilder {
        private final String base;
        private final List<Clause> clauses = new ArrayList<>();

        WhereBuilder(String base) { this.base = base; }

        void add(String fragment, String param, Object val) { clauses.add(new Clause(fragment, param, val)); }

        Built build(List<Clause> extra) {
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

        record Clause(String fragment, String param, Object val) {}
        record Built(String sql, Map<String, Object> params) {}
    }
}
