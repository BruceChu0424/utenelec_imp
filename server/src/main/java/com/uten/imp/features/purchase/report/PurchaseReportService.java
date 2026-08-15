package com.uten.imp.features.purchase.report;

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
 * 采购报表查询（采购管理 / 采购报表）。
 *
 * <p>三类入口：
 * <ol>
 *   <li>{@link #detail}/{@link #summary} 9 张报表：催料单 + 申请/订货/收货/退货 各明细/汇总。
 *       <b>服务端 JOIN 出"显示就绪"行</b>（供应商/仓库/货品/颜色/单位/类别/人员名均已解析），
 *       支持日期/供应商/仓库/状态/关键字过滤 + 关键列 facet 表头筛选 + 分页。</li>
 *   <li>{@link #monthly} 月度汇总（MV 上卷，保留）。</li>
 *   <li>{@link #pending} 待交货订货汇总（视图，保留）。</li>
 * </ol>
 *
 * <p>人员名两类来源（与老库视图口径一致）：员工类（申请人/采购员/收货人= B_Worker）走
 * {@code LEFT JOIN employees ... ON id = *_id}，current UUID 为空时才回退 legacy_id；
 * 账号类（制单员/审核员 = Sys_Operator 登录账号，非员工档案）迁移时冻结进 {@code maker_name/approver_name}
 * 文本列，报表 {@code COALESCE(employees 真名, 冻结名)}。
 *
 * <p>部门：申请单优先 {@code department_id -> departments.id}；仅 UUID 为空时才以
 * {@code department_legacy_id}（老库 StepID）回退 {@code legacy_departments} 冻结名称。
 *
 * <p>结帐方式：{@code settlement_style_legacy} 原值，按 {@link PurchaseSettlementStyle} 字典渲染
 * （字典=老库 B_PStyle：1现金/2提货/3代付/4支票/6月结/7垫付/8汇款/10代收）。
 *
 * <p>编号：收货/退货明细按老视图口径渲染为「货品编号-颜色编号」（颜色编号为空则不加，如 280501084-3）。
 *
 * <p>_null 参数类型坑_：所有可选过滤用 {@code CAST(:param AS 类型) IS NULL OR ...} 或显式 CAST 绑定（见 MEMORY）。
 */
@Service
@RequiredArgsConstructor
public class PurchaseReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;
    private final SystemSettingsService settings;

    // ======================== 通用执行器 ========================

    /**
     * 跑一张报表：data + count + 各 facet。
     *
     * @param columns     列定义（顺序 = dataSelect 投影顺序）
     * @param dataSelect  "SELECT o.bill_no AS billNo, ..."（别名 = 列 key，顺序 = columns）
     * @param fromJoin    "FROM ... JOIN ..."（主表别名约定：主表 o、明细 i）
     * @param mainWhere   主过滤（日期/供应商/仓库/状态/关键字）
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

        // 列排序：sort 必须命中 columns 的 key（白名单，防 SQL 注入）；命中则按投影别名排序，否则用默认 orderBy。
        var sortKeys = new java.util.HashSet<String>();
        for (ReportColumn c : columns) sortKeys.add(c.key());
        String effectiveOrderBy = ReportSort.resolveOrderBy(sort, order, orderBy, sortKeys);

        // data
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
            for (int i = 0; i < columns.size(); i++) m.put(columns.get(i).key(), norm(r[i], columns.get(i)));
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
                    + baseB.sql() + " GROUP BY " + spec.groupExpr() + " ORDER BY " + spec.orderExpr() + " LIMIT 50");
            baseB.params().forEach(fq::setParameter);
            @SuppressWarnings("unchecked")
            List<Object[]> frs = fq.getResultList();
            List<ReportFacet> buckets = new ArrayList<>();
            for (Object[] fr : frs) {
                Object v = fr[0];
                String val = (v == null) ? ReportTableResponse.NULL_FACET : Objects.toString(v);
                String lbl = (v == null) ? "(空)" : (fr[1] == null ? null : fr[1].toString());
                if ("style".equals(spec.filterType()) && v != null) {
                    lbl = PurchaseSettlementStyle.label(toInt(v));
                }
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

    private static int toInt(Object v) {
        if (v instanceof Number n) return n.intValue();
        try { return Integer.parseInt(Objects.toString(v)); } catch (NumberFormatException e) { return 0; }
    }

    private static Object norm(Object v, ReportColumn col) {
        if (v == null) return null;
        if ("style".equals(col.type())) return PurchaseSettlementStyle.label(toInt(v));
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
            case "int", "style" -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS int)", p, Integer.valueOf(value));
            case "bool"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS boolean)", p, Boolean.valueOf(value));
            case "date"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS date)", p, LocalDate.parse(value));
            default      -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS text)", p, value);
        };
    }

    // ======================== 主过滤构造（公共） ========================

    private static void addCommonDocFilters(WhereBuilder w, String billNo, UUID supplierId, UUID warehouseId,
                                            Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                            String billNoCol, String dateCol) {
        if (billNo != null && !billNo.isBlank()) {
            w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        }
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
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

    private static void addSummaryKw(WhereBuilder w, String kw, String billNoCol) {
        if (kw != null && !kw.isBlank()) w.add("LOWER(" + billNoCol + ") LIKE LOWER(:kw)", "kw", "%" + kw.toLowerCase() + "%");
    }

    // ======================== ① 采购催料单 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse expediting(String billNo, UUID supplierId, LocalDate dateFrom, LocalDate dateTo,
                                          String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160),
                ReportColumn.date("deliverDate", "交货日期"),
                ReportColumn.text("finishedProductName", "产成品名称", 140),
                ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 150),
                ReportColumn.text("colorName", "颜色", 90),
                ReportColumn.number("qty", "数量"),
                ReportColumn.number("receivedQty", "收货数量"),
                ReportColumn.number("unreceivedQty", "未收数量"),
                ReportColumn.number("stockQty", "库存数量"),
                ReportColumn.number("safeStock", "安全库存"),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳采购订货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName",
                       o.deliver_date AS "deliverDate", NULL AS "finishedProductName",
                       i.goods_name_snapshot AS "goodsName", g.spec AS "spec", col.name AS "colorName",
                       i.qty AS "qty", i.received_qty AS "receivedQty",
                       (i.qty - COALESCE(i.received_qty,0)) AS "unreceivedQty",
                       COALESCE(sb.stock_qty,0) AS "stockQty", g.min_qty AS "safeStock",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_order_items i
                JOIN purchase_orders o ON o.id = i.order_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN (SELECT goods_id, SUM(qty) AS stock_qty FROM stock_balances GROUP BY goods_id) sb ON sb.goods_id = i.goods_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false AND (i.qty - COALESCE(i.received_qty,0)) > 0");
        addCommonDocFilters(w, billNo, supplierId, null, null, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(),
                // 开单日期表头 autofilter：按日期降序（近期在上，与表格默认排序一致），空值排末尾。
                new FacetSpec("billDate", "o.bill_date AS v, TO_CHAR(o.bill_date, 'YYYY-MM-DD') AS lbl",
                        "o.bill_date", "o.bill_date", "date", "v DESC NULLS LAST"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ② 采购申请明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse requestDetail(String billNo, Short status, LocalDate dateFrom, LocalDate dateTo,
                                             String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.date("deliverDate", "交货日期"), ReportColumn.text("applicantName", "申购人", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.bool("closed", "是否完成"), ReportColumn.bool("stopped", "是否中止"),
                ReportColumn.text("productionNo", "生产单号", 120), ReportColumn.text("departmentName", "部门", 100),
                ReportColumn.text("series", "系列", 90), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("supplierName", "供应商", 140),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("categoryName", "类别", 100),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("material", "材质", 90),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("qty", "数量"), ReportColumn.text("unitName", "单位", 70),
                ReportColumn.money("price", "单价"), ReportColumn.money("amount", "金额"),
                ReportColumn.number("orderedQty", "采订数量"), ReportColumn.text("purchaseOrderNo", "采购订货单号", 130),
                ReportColumn.text("salesOrderNo", "销售订货单号", 130), ReportColumn.text("productionPlanNo", "生产计划单号", 130),
                ReportColumn.money("laborCost", "人工费"), ReportColumn.text("purchaseReply", "采购回复", 140),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", i.deliver_date AS "deliverDate",
                       em_app.full_name AS "applicantName", o.total_local AS "totalAmount",
                       (o.status = 1) AS "approved", o.is_closed AS "closed", o.is_stopped AS "stopped",
                       i.production_no AS "productionNo", COALESCE(dept.name, legacy_dept.name) AS "departmentName",
                       g.series AS "series", i.goods_code_snapshot AS "goodsCode", g.model AS "model",
                       gsup.name AS "supplierName", g.c_number AS "customerModel", mc.name AS "categoryName",
                       i.goods_name_snapshot AS "goodsName", g.material AS "material", g.spec AS "spec", col.name AS "colorName",
                       i.qty AS "qty", un.name AS "unitName", i.price AS "price", i.amount_original AS "amount",
                       i.ordered_qty AS "orderedQty", i.purchase_order_no AS "purchaseOrderNo",
                       i.sales_order_no AS "salesOrderNo", i.production_plan_no AS "productionPlanNo",
                       g.work_e AS "laborCost", i.purchase_reply AS "purchaseReply",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_request_items i
                JOIN purchase_requests o ON o.id = i.request_id
                LEFT JOIN employees em_app ON em_app.id = o.applicant_id
                    OR (o.applicant_id IS NULL AND em_app.legacy_id = o.applicant_legacy_id)
                LEFT JOIN departments dept ON dept.id = o.department_id
                LEFT JOIN legacy_departments legacy_dept
                    ON o.department_id IS NULL
                   AND legacy_dept.legacy_id = o.department_legacy_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units un ON un.id = i.unit_id
                LEFT JOIN material_categories mc ON mc.id = g.category_id
                LEFT JOIN suppliers gsup
                  ON (gsup.id = g.default_supplier_id
                      OR (g.default_supplier_id IS NULL
                          AND gsup.legacy_id = NULLIF(g.vend_legacy_id, 0)))
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, null, null, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"),
                new FacetSpec("closed", "o.is_closed AS v, CASE WHEN o.is_closed THEN '已完成' ELSE '未完成' END AS lbl", "o.is_closed", "o.is_closed", "bool"),
                new FacetSpec("stopped", "o.is_stopped AS v, CASE WHEN o.is_stopped THEN '已中止' ELSE '未中止' END AS lbl", "o.is_stopped", "o.is_stopped", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ③ 采购申请汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse requestSummary(String billNo, Short status, LocalDate dateFrom, LocalDate dateTo,
                                              String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("applicantName", "申购人", 100), ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("approverName", "审核员", 100), ReportColumn.money("totalAmount", "总额"),
                ReportColumn.text("remark", "备注", 180),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate",
                       em_app.full_name AS "applicantName",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       COALESCE(em_ap.full_name, o.approver_name) AS "approverName",
                       o.total_local AS "totalAmount", o.remark AS "remark",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_requests o
                LEFT JOIN employees em_app ON em_app.id = o.applicant_id
                    OR (o.applicant_id IS NULL AND em_app.legacy_id = o.applicant_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                    OR (o.maker_id IS NULL AND em_mk.legacy_id = o.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id = o.approver_id
                    OR (o.approver_id IS NULL AND em_ap.legacy_id = o.approver_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", List.of(), facets, page, size, sort, order);
    }

    // ======================== ④ 采购订货明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse orderDetail(String billNo, UUID supplierId, Short status, LocalDate dateFrom,
                                           LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160), ReportColumn.date("deliverDate", "交货日期"),
                ReportColumn.text("purchaserName", "采购员", 100),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.bool("closed", "是否完成"), ReportColumn.bool("stopped", "是否中止"),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("material", "材质", 90), ReportColumn.number("weight", "重量"),
                ReportColumn.number("qty", "订货数量"), ReportColumn.money("price", "单价"),
                ReportColumn.money("amount", "金额"), ReportColumn.number("receivedQty", "收货数量"),
                ReportColumn.number("returnedQty", "退货数量"),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName",
                       o.deliver_date AS "deliverDate", em_pur.full_name AS "purchaserName",
                       o.settlement_style_legacy AS "settlementStyle", o.total_local AS "totalAmount",
                       (o.status = 1) AS "approved", o.is_closed AS "closed", o.is_stopped AS "stopped",
                       i.goods_code_snapshot AS "goodsCode", g.model AS "model", g.c_number AS "customerModel",
                       i.goods_name_snapshot AS "goodsName",
                       g.spec AS "spec", col.name AS "colorName", g.material AS "material", i.weight AS "weight",
                       i.qty AS "qty", i.price AS "price", i.amount_original AS "amount",
                       i.received_qty AS "receivedQty", i.returned_qty AS "returnedQty",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_order_items i
                JOIN purchase_orders o ON o.id = i.order_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN employees em_pur ON em_pur.id = o.purchaser_id
                    OR (o.purchaser_id IS NULL AND em_pur.legacy_id = o.purchaser_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, null, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"),
                new FacetSpec("closed", "o.is_closed AS v, CASE WHEN o.is_closed THEN '已完成' ELSE '未完成' END AS lbl", "o.is_closed", "o.is_closed", "bool"),
                new FacetSpec("stopped", "o.is_stopped AS v, CASE WHEN o.is_stopped THEN '已中止' ELSE '未中止' END AS lbl", "o.is_stopped", "o.is_stopped", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ⑤ 采购订货汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse orderSummary(String billNo, UUID supplierId, Short status, LocalDate dateFrom,
                                            LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160), ReportColumn.date("deliverDate", "交货日期"),
                ReportColumn.text("purchaserName", "采购员", 100),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName",
                       o.deliver_date AS "deliverDate", em_pur.full_name AS "purchaserName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_orders o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN employees em_pur ON em_pur.id = o.purchaser_id
                    OR (o.purchaser_id IS NULL AND em_pur.legacy_id = o.purchaser_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                    OR (o.maker_id IS NULL AND em_mk.legacy_id = o.maker_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(
                facetSupplier(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== ⑥ 采购收货明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse receiptDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String kw,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("receiverName", "收货人", 100), ReportColumn.text("purchaserName", "采购员", 100),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("series", "系列", 90), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("material", "材质", 90), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("weight", "重量"), ReportColumn.number("orderQty", "订货数量"),
                ReportColumn.number("qty", "数量"), ReportColumn.number("giftQty", "备品数"),
                ReportColumn.money("price", "单价"),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       em_rec.full_name AS "receiverName",
                       COALESCE(em_sman.full_name, em_pur.full_name) AS "purchaserName",
                       o.settlement_style_legacy AS "settlementStyle", o.total_local AS "totalAmount",
                       (o.status = 1) AS "approved",
                       g.series AS "series",
                       (i.goods_code_snapshot || CASE WHEN NULLIF(BTRIM(COALESCE(col.code, '')), '') IS NOT NULL THEN '-' || BTRIM(col.code) ELSE '' END) AS "goodsCode",
                       g.model AS "model", g.c_number AS "customerModel",
                       i.goods_name_snapshot AS "goodsName", g.spec AS "spec", g.material AS "material", col.name AS "colorName",
                       i.weight AS "weight", oi.qty AS "orderQty", i.qty AS "qty", i.gift_qty AS "giftQty", i.price AS "price",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_receipt_items i
                JOIN purchase_receipts o ON o.id = i.receipt_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_rec ON em_rec.id = o.receiver_id
                    OR (o.receiver_id IS NULL AND em_rec.legacy_id = o.receiver_legacy_id)
                LEFT JOIN employees em_sman ON em_sman.id = o.purchaser_id
                    OR (o.purchaser_id IS NULL AND em_sman.legacy_id = o.purchaser_legacy_id)
                LEFT JOIN purchase_order_items oi ON oi.id = i.order_item_id
                LEFT JOIN purchase_orders po ON po.id = oi.order_id
                LEFT JOIN employees em_pur ON em_pur.id = po.purchaser_id
                    OR (po.purchaser_id IS NULL AND em_pur.legacy_id = po.purchaser_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(),
                facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ⑦ 采购收货汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse receiptSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                              LocalDate dateFrom, LocalDate dateTo, String kw,
                                              Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("receiverName", "收货人", 100),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       em_rec.full_name AS "receiverName", o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_receipts o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_rec ON em_rec.id = o.receiver_id
                    OR (o.receiver_id IS NULL AND em_rec.legacy_id = o.receiver_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                    OR (o.maker_id IS NULL AND em_mk.legacy_id = o.maker_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== ⑧ 采购退货明细（单号合并开单日期、无围数） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse returnDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                            LocalDate dateFrom, LocalDate dateTo, String kw,
                                            Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 200), ReportColumn.text("supplierName", "供应商", 160),
                ReportColumn.text("warehouseName", "仓库", 120),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("series", "系列", 90), ReportColumn.text("goodsCode", "编号", 120),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("material", "材质", 90), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("weight", "重量"), ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"), ReportColumn.money("amount", "金额"),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT (o.bill_no || ' ' || TO_CHAR(o.bill_date, 'YYYY-MM-DD')) AS "billNo",
                       sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle", o.total_local AS "totalAmount",
                       (o.status = 1) AS "approved",
                       g.series AS "series",
                       (i.goods_code_snapshot || CASE WHEN NULLIF(BTRIM(COALESCE(col.code, '')), '') IS NOT NULL THEN '-' || BTRIM(col.code) ELSE '' END) AS "goodsCode",
                       g.model AS "model", g.c_number AS "customerModel",
                       i.goods_name_snapshot AS "goodsName", g.spec AS "spec", g.material AS "material", col.name AS "colorName",
                       i.weight AS "weight", i.qty AS "qty", i.price AS "price", i.amount_original AS "amount",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_return_items i
                JOIN purchase_returns o ON o.id = i.return_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ⑨ 采购退货汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse returnSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String kw,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "供应商", 160), ReportColumn.text("warehouseName", "仓库", 120),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("makerName", "制单员", 100), ReportColumn.text("approverName", "审核员", 100),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       COALESCE(em_ap.full_name, o.approver_name) AS "approverName",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM purchase_returns o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                    OR (o.maker_id IS NULL AND em_mk.legacy_id = o.maker_legacy_id)
                LEFT JOIN employees em_ap ON em_ap.id = o.approver_id
                    OR (o.approver_id IS NULL AND em_ap.legacy_id = o.approver_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== facet 复用 ========================

    private static FacetSpec facetSupplier() {
        return new FacetSpec("supplierName", "CAST(sup.id AS text) AS v, sup.name AS lbl", "sup.id, sup.name", "o.supplier_id", "uuid");
    }

    private static FacetSpec facetWarehouse() {
        return new FacetSpec("warehouseName", "CAST(wh.id AS text) AS v, wh.name AS lbl", "wh.id, wh.name", "o.warehouse_id", "uuid");
    }

    // ======================== 导出（加密 Excel） ========================

    /**
     * 导出某报表全量（不分页，循环 size=500 累积全部行），返回 ExportColumn + 行 Map。
     * 列定义映射 ReportColumn→ExportColumn（剥离 width）。report 取值与 GET 路径一致：
     * expediting / {request|order|receipt|return}/{detail|summary}。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(String report, Map<String, String> p, String sort, String order) {
        String billNo = p == null ? null : p.get("billNo");
        UUID supplierId = parseUuid(p == null ? null : p.get("supplierId"));
        UUID warehouseId = parseUuid(p == null ? null : p.get("warehouseId"));
        Short status = parseShort(p == null ? null : p.get("status"));
        LocalDate dateFrom = parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = parseDate(p == null ? null : p.get("dateTo"));
        String kw = p == null ? null : p.get("keyword");
        Map<String, String> facets = facetsOfMap(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (report) {
            case "expediting"      -> (pg, sz) -> expediting(billNo, supplierId, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "request/detail"  -> (pg, sz) -> requestDetail(billNo, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "request/summary" -> (pg, sz) -> requestSummary(billNo, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "order/detail"    -> (pg, sz) -> orderDetail(billNo, supplierId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "order/summary"   -> (pg, sz) -> orderSummary(billNo, supplierId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "receipt/detail"  -> (pg, sz) -> receiptDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "receipt/summary" -> (pg, sz) -> receiptSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "return/detail"   -> (pg, sz) -> returnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "return/summary"  -> (pg, sz) -> returnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
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

    // ======================== 保留：月度汇总（MV）+ 待交货（视图） ========================

    @Transactional(readOnly = true)
    public List<MonthlySummaryRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, supplier_id,
                       SUM(qty_sum) AS qty, SUM(amt_local) AS amt, SUM(line_cnt) AS lines
                FROM purchase_monthly_mv
                WHERE (CAST(:docType AS text) IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                GROUP BY doc_type, ym, goods_id, supplier_id
                ORDER BY amt DESC NULLS LAST
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
                ((java.sql.Date) r[1]).toLocalDate(),
                (java.util.UUID) r[2],
                NIL.equals(r[3]) ? null : (java.util.UUID) r[3],
                (BigDecimal) r[4],
                (BigDecimal) r[5],
                ((Number) r[6]).longValue()
        )).toList();
    }

    @Transactional(readOnly = true)
    public List<PendingRow> pending(int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var q = em.createNativeQuery("""
                SELECT goods_id, color_id, pending_qty, pending_amt
                FROM purchase_order_pending_v
                ORDER BY pending_qty DESC
                LIMIT :limit
                """);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new PendingRow(
                (java.util.UUID) r[0],
                (java.util.UUID) r[1],
                (BigDecimal) r[2],
                (BigDecimal) r[3]
        )).toList();
    }

    // ======================== 内部结构 ========================

    /** 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型。 */
    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType, String orderExpr) {
        /** 兼容旧调用：默认按命中数倒序（旧行为）。日期等列可显式传 orderExpr 按值排序。 */
        FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {
            this(key, selectExpr, groupExpr, filterExpr, filterType, "cnt DESC");
        }
    }

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
