package com.uten.imp.features.subcontract.report;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.security.CommercialPriceVisibility;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
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
 * 委外报表查询（委外管理 / 委外报表）。
 *
 * <p>三类入口：
 * <ol>
 *   <li>{@link #execute}/{@link #receiptDetail} 等 8 张：进仓/退货/材料出/材料退 各明细+汇总。
 *       <b>服务端 JOIN 出"显示就绪"行</b>（委外商/仓库/货品/颜色/单位/人员名/结帐方式均已解析），
 *       支持日期/委外商/仓库/状态/关键字过滤 + 关键列 facet 表头筛选 + 分页。</li>
 *   <li>{@link #inOutStatus}：委外出入状况表（按 委外商×货品×颜色 汇总发胚/收货/退成品/退原胚/退不良品
 *       + 期初/期末结存 + 订货数量 + 单价/金额）。</li>
 *   <li>{@link #monthly}：月度汇总（MV 上卷，保留兜底；前端不再暴露入口）。</li>
 * </ol>
 *
 * <p>人员名（Option A，见迁移计划）：
 * <ul>
 *   <li>收货人(receiver)/经办人(operator)：老库 B_Worker → employees stub（legacy_id=B_Worker.ID）。
 *       报表优先走 sender_id/worker_id；仅 current UUID 为空时按 *_legacy_id 回退。</li>
 *   <li>制单员(maker)/审核员(approver)：老库 Sys_Operator → 迁移冻结 o.*_name 文本；新单据走 *_id→employees。
 *       报表 COALESCE(em.full_name, o.*_name)，em 走 *_id。</li>
 * </ul>
 *
 * <p>结帐方式：{@code settlement_style_legacy}（B_PStyle.ID），按 {@link SubcontractSettlementStyle} 字典渲染。
 *
 * <p>结构/执行器与 {@code PurchaseReportService} 同构（复制，避免跨 feature 依赖）。
 * _null 参数类型坑_：可选过滤用 {@code CAST(:param AS 类型) IS NULL OR ...}（见 MEMORY）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    private final EntityManager em;
    private final SystemSettingsService settings;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    // ======================== 通用执行器（8 张明细/汇总共用） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse execute(List<ReportColumn> columns, String dataSelect, String fromJoin,
                                       WhereBuilder mainWhere, String orderBy, List<FacetSpec> specs,
                                       Map<String, String> activeFacets, int page, int size,
                                       String sort, String order) {
        boolean priceMasked = subcontractPriceMasked();
        List<ReportColumn> safeColumns = responseColumns(columns, priceMasked);
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        List<WhereBuilder.Clause> facetClauses = new ArrayList<>();
        if (activeFacets != null) {
            for (Map.Entry<String, String> e : activeFacets.entrySet()) {
                FacetSpec spec = specs.stream().filter(s -> s.key().equals(e.getKey())).findFirst().orElse(null);
                if (spec != null && (!priceMasked || !isCommercialKey(spec.key()))
                        && e.getValue() != null && !e.getValue().isBlank()) {
                    facetClauses.add(facetClause(spec, e.getValue()));
                }
            }
        }
        WhereBuilder.Built full = mainWhere.build(facetClauses);
        WhereBuilder.Built baseB = mainWhere.build(null);

        // 列排序：sort 必须命中 columns 的 key（白名单，防 SQL 注入）；命中则按投影别名排序，否则用默认 orderBy。
        var sortKeys = new java.util.HashSet<String>();
        for (ReportColumn c : safeColumns) sortKeys.add(c.key());
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
            items.add(responseRow(columns, r, priceMasked));
        }

        var countQ = em.createNativeQuery("SELECT COUNT(*) " + fromJoin + " " + full.sql());
        full.params().forEach(countQ::setParameter);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

        Map<String, List<ReportFacet>> facets = new LinkedHashMap<>();
        for (FacetSpec spec : specs) {
            if (priceMasked && isCommercialKey(spec.key())) continue;
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
                if ("style".equals(spec.filterType()) && v != null) {
                    lbl = SubcontractSettlementStyle.label(toInt(v));
                }
                long cnt = ((Number) fr[2]).longValue();
                buckets.add(new ReportFacet(val, lbl, cnt));
            }
            facets.put(spec.key(), buckets);
        }

        // 隐藏元数据列（key 以 "__" 开头，如行跳源头用的 __srcId）：不进返回的 columns（前端不渲染、
        // 导出 Excel 不含），但行 Map 已 put 其值（前端 onRowTap 可读 row['__srcId'] 跳对应单据编辑页）。
        List<ReportColumn> visible = safeColumns.stream().filter(c -> !c.key().startsWith("__")).toList();
        return new ReportTableResponse(visible, items, facets, safePage, safeSize, total, totalPages);
    }

    private boolean subcontractPriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewSubcontractReport();
    }

    static List<ReportColumn> responseColumns(List<ReportColumn> columns, boolean priceMasked) {
        return priceMasked
                ? columns.stream().filter(c -> !isCommercialColumn(c)).toList()
                : columns;
    }

    static Map<String, Object> responseRow(
            List<ReportColumn> columns, Object[] row, boolean priceMasked) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int i = 0; i < columns.size(); i++) {
            ReportColumn column = columns.get(i);
            if (!priceMasked || !isCommercialColumn(column)) {
                result.put(column.key(), norm(row[i], column));
            }
        }
        return result;
    }

    static boolean isCommercialColumn(ReportColumn column) {
        return "money".equals(column.type()) || isCommercialKey(column.key());
    }

    static boolean isCommercialKey(String key) {
        return "settlementStyle".equals(key);
    }

    private static int toInt(Object v) {
        if (v instanceof Number n) return n.intValue();
        try { return Integer.parseInt(Objects.toString(v)); } catch (NumberFormatException e) { return 0; }
    }

    private static Object norm(Object v, ReportColumn col) {
        if (v == null) return null;
        if ("style".equals(col.type())) return SubcontractSettlementStyle.label(toInt(v));
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

    // ======================== ① 委外进仓明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse receiptDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String kw,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("receiverName", "收货人", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("weight", "重量"), ReportColumn.number("girth", "围数"),
                ReportColumn.number("qty", "数量"), ReportColumn.text("unitName", "单位", 70),
                ReportColumn.text("step", "工序", 80),
                ReportColumn.money("price", "单价"), ReportColumn.money("amount", "金额"),
                ReportColumn.number("returnedQty", "退货数量"), ReportColumn.money("returnedAmount", "退货金额"),
                ReportColumn.text("returnNo", "委外退货单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外进仓单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_rec.full_name, o.receiver_name) AS "receiverName",
                       o.total_local AS "totalAmount", (o.status = 1) AS "approved",
                       i.goods_code_snapshot AS "goodsCode", g.model AS "model", g.c_number AS "customerModel", i.goods_name_snapshot AS "goodsName",
                       g.spec AS "spec", col.name AS "colorName", i.weight AS "weight", i.girth_qty AS "girth",
                       i.qty AS "qty", un.name AS "unitName", NULL AS "step",
                       i.price AS "price", i.amount_local AS "amount",
                       i.returned_qty AS "returnedQty", i.return_amount AS "returnedAmount",
                       i.return_no AS "returnNo", i.order_no AS "orderNo",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_receipt_items i
                JOIN subcontract_receipts o ON o.id = i.receipt_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_rec ON em_rec.id = o.sender_id
                    OR (o.sender_id IS NULL AND em_rec.legacy_id = o.receiver_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units un ON un.id = i.unit_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ② 委外进仓汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse receiptSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                              LocalDate dateFrom, LocalDate dateTo, String kw,
                                              Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("receiverName", "收货人", 100), ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_rec.full_name, o.receiver_name) AS "receiverName",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_receipts o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_rec ON em_rec.id = o.sender_id
                    OR (o.sender_id IS NULL AND em_rec.legacy_id = o.receiver_legacy_id)
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
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

    // ======================== ③ 委外退货明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse returnDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                            LocalDate dateFrom, LocalDate dateTo, String kw,
                                            Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.text("makerName", "制单员", 100),
                ReportColumn.bool("approved", "是否审核"), ReportColumn.money("totalAmount", "总额"),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("weight", "重量"), ReportColumn.number("girth", "围数"),
                ReportColumn.number("qty", "数量"), ReportColumn.text("unitName", "单位", 70),
                ReportColumn.text("step", "工序", 80),
                ReportColumn.money("price", "单价"), ReportColumn.money("amount", "金额"),
                ReportColumn.text("receiptNo", "委外进仓单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外退货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       (o.status = 1) AS "approved", o.total_local AS "totalAmount",
                       i.goods_code_snapshot AS "goodsCode", g.model AS "model", g.c_number AS "customerModel", i.goods_name_snapshot AS "goodsName",
                       g.spec AS "spec", col.name AS "colorName", i.weight AS "weight", i.girth_qty AS "girth",
                       i.qty AS "qty", un.name AS "unitName", NULL AS "step",
                       i.price AS "price", i.amount_local AS "amount", i.receipt_no AS "receiptNo",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_return_items i
                JOIN subcontract_returns o ON o.id = i.return_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units un ON un.id = i.unit_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("settlementStyle", "o.settlement_style_legacy AS v, CAST(o.settlement_style_legacy AS text) AS lbl", "o.settlement_style_legacy", "o.settlement_style_legacy", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ④ 委外退货汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse returnSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String kw,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 150), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
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
                FROM subcontract_returns o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
                LEFT JOIN employees em_ap ON em_ap.id = o.approver_id
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

    // ======================== ⑤ 委外材料出仓明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse materialIssueDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                                   LocalDate dateFrom, LocalDate dateTo, String kw,
                                                   Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("operatorName", "经办人", 100), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("unitName", "单位", 70), ReportColumn.number("weight", "重量"),
                ReportColumn.number("boxQty", "胶箱数量"), ReportColumn.number("qty", "数量"),
                ReportColumn.number("returnedQty", "退货数量"),
                ReportColumn.text("returnNo", "材料退货单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外发料单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       i.goods_code_snapshot AS "goodsCode", g.model AS "model", g.c_number AS "customerModel", i.goods_name_snapshot AS "goodsName",
                       g.spec AS "spec", col.name AS "colorName", un.name AS "unitName", i.weight AS "weight",
                       i.box_qty AS "boxQty", i.qty AS "qty", i.returned_qty AS "returnedQty",
                       i.return_no AS "returnNo", i.order_no AS "orderNo",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_material_issue_items i
                JOIN subcontract_material_issues o ON o.id = i.issue_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_op ON em_op.id = o.worker_id
                    OR (o.worker_id IS NULL AND em_op.legacy_id = o.operator_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units un ON un.id = i.unit_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ⑥ 委外材料出仓汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse materialIssueSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, String kw,
                                                    Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.number("docSeq", "编号", 70), ReportColumn.text("billNo", "单号", 150),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("operatorName", "经办人", 100), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT ROW_NUMBER() OVER (ORDER BY o.bill_date DESC, o.bill_no) AS "docSeq",
                       o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_material_issues o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_op ON em_op.id = o.worker_id
                    OR (o.worker_id IS NULL AND em_op.legacy_id = o.operator_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(facetSupplier(), facetWarehouse());
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== ⑦ 委外材料退货明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse materialReturnDetail(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, String kw,
                                                    Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("operatorName", "经办人", 100), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100), ReportColumn.text("goodsName", "货品名称", 180),
                ReportColumn.text("spec", "规格", 140), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("unitName", "单位", 70), ReportColumn.number("weight", "重量"),
                ReportColumn.number("girth", "围数"), ReportColumn.number("qty", "数量"),
                ReportColumn.text("issueNo", "材料出仓单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外材料退货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       i.goods_code_snapshot AS "goodsCode", g.model AS "model", g.c_number AS "customerModel", i.goods_name_snapshot AS "goodsName",
                       g.spec AS "spec", col.name AS "colorName", un.name AS "unitName", i.weight AS "weight",
                       i.girth_qty AS "girth", i.qty AS "qty", i.issue_no AS "issueNo", i.order_no AS "orderNo",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_material_return_items i
                JOIN subcontract_material_returns o ON o.id = i.material_return_id
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_op ON em_op.id = o.worker_id
                    OR (o.worker_id IS NULL AND em_op.legacy_id = o.operator_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units un ON un.id = i.unit_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetSupplier(), facetWarehouse(),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== ⑧ 委外材料退货汇总 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse materialReturnSummary(String billNo, UUID supplierId, UUID warehouseId, Short status,
                                                     LocalDate dateFrom, LocalDate dateTo, String kw,
                                                     Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.number("docSeq", "编号", 70), ReportColumn.text("billNo", "单号", 150),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("operatorName", "经办人", 100), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("__srcId", ""));
        String dataSelect = """
                SELECT ROW_NUMBER() OVER (ORDER BY o.bill_date DESC, o.bill_no) AS "docSeq",
                       o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM subcontract_material_returns o
                LEFT JOIN suppliers sup ON sup.id = o.supplier_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_op ON em_op.id = o.worker_id
                    OR (o.worker_id IS NULL AND em_op.legacy_id = o.operator_legacy_id)
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (supplierId != null) w.add("o.supplier_id = :supplierId", "supplierId", supplierId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(facetSupplier(), facetWarehouse());
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== ⑨ 委外出入状况表（综合 · 按 委外商×货品×颜色 聚合） ========================

    /**
     * 列：加工单位/品名及规格/型号/系列/编号/颜色/期初结存/订货数量/发胚(15)/退成品(18)/
     * 退原胚(16)/退不良品(19)/收货(17)/单价/金额/期末结存。
     *
     * <p>实现：直接聚合 5 类源明细（不依赖 stock_movements——迁移未回填流水，源明细对迁移数据立即可见）：
     * 收货=进仓(+in)、退成品=退货(-out)、发胚=发料(-out)、退原胚=材料退(+in)、退不良品=损耗(-out)。
     * 期初=dateFrom 前 signed 累计；期末=期初+期内净流；订货=期内 subcontract_order_items.qty；
     * 单价=期内收货均价；金额=期内收货额。
     */
    @Transactional(readOnly = true)
    public ReportTableResponse inOutStatus(UUID supplierId, LocalDate dateFrom, LocalDate dateTo, String kw,
                                           int page, int size) {
        boolean priceMasked = subcontractPriceMasked();
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        List<ReportColumn> cols = List.of(
                ReportColumn.text("supplierName", "加工单位", 160),
                ReportColumn.text("goodsDesc", "品名及规格", 200),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("series", "系列", 90),
                ReportColumn.text("goodsCode", "编号", 110), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("openingQty", "期初结存"), ReportColumn.number("orderQty", "订货数量"),
                ReportColumn.number("issueQty", "发胚数量"), ReportColumn.number("returnQty", "退成品"),
                ReportColumn.number("mReturnQty", "退原胚"), ReportColumn.number("wasteQty", "退不良品"),
                ReportColumn.number("receiptQty", "收货数量"),
                ReportColumn.money("price", "单价"), ReportColumn.money("amount", "金额"),
                ReportColumn.number("closingQty", "期末结存"));
        List<ReportColumn> safeCols = responseColumns(cols, priceMasked);

        // flow：5 类源明细 UNION，带 signed_qty（方向）+ movement_type + 日期 + 单价/金额
        String sql = """
                WITH flow AS (
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date AS d, i.qty AS signed_qty, 17 AS mt, i.price, i.amount_local AS amt
                    FROM subcontract_receipt_items i JOIN subcontract_receipts o ON o.id = i.receipt_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 18, i.price, i.amount_local
                    FROM subcontract_return_items i JOIN subcontract_returns o ON o.id = i.return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 15, NULL, i.amount_local
                    FROM subcontract_material_issue_items i JOIN subcontract_material_issues o ON o.id = i.issue_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, i.qty, 16, NULL, i.amount_local
                    FROM subcontract_material_return_items i JOIN subcontract_material_returns o ON o.id = i.material_return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 19, NULL, i.amount_local
                    FROM subcontract_waste_items i JOIN subcontract_wastes o ON o.id = i.waste_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                ),
                agg AS (
                    SELECT supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id,
                           COALESCE(SUM(CASE WHEN d < CAST(:from AS date) THEN signed_qty ELSE 0 END),0) AS opening,
                           COALESCE(SUM(CASE WHEN mt=15 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS issue_qty,
                           COALESCE(SUM(CASE WHEN mt=16 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS m_return_qty,
                           COALESCE(SUM(CASE WHEN mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS receipt_qty,
                           COALESCE(SUM(CASE WHEN mt=18 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS return_qty,
                           COALESCE(SUM(CASE WHEN mt=19 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS waste_qty,
                           COALESCE(SUM(CASE WHEN d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN signed_qty ELSE 0 END),0) AS net_qty,
                           AVG(CASE WHEN mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN price END) AS price,
                           COALESCE(SUM(CASE WHEN mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN amt ELSE 0 END),0) AS amount
                    FROM flow
                    WHERE (CAST(:supplierId AS uuid) IS NULL OR supplier_id = :supplierId)
                    GROUP BY supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id
                ),
                ord AS (
                    SELECT o.supplier_id, oi.goods_id, oi.goods_code_snapshot, oi.goods_name_snapshot,
                           oi.color_id, SUM(oi.qty) AS order_qty
                    FROM subcontract_order_items oi JOIN subcontract_orders o ON o.id = oi.order_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1
                      AND oi.bill_date >= CAST(:from AS date) AND oi.bill_date <= CAST(:to AS date)
                    GROUP BY o.supplier_id, oi.goods_id, oi.goods_code_snapshot,
                             oi.goods_name_snapshot, oi.color_id
                )
                SELECT sup.name AS supplierName,
                       a.goods_name_snapshot || COALESCE(' ' || gg.spec, '') AS goodsDesc,
                       gg.model AS model, gg.series AS series, a.goods_code_snapshot AS goodsCode, col.name AS colorName,
                       a.opening AS openingQty, COALESCE(od.order_qty, 0) AS orderQty,
                       a.issue_qty AS issueQty, a.return_qty AS returnQty, a.m_return_qty AS mReturnQty,
                       a.waste_qty AS wasteQty, a.receipt_qty AS receiptQty,
                       a.price AS price, a.amount AS amount,
                       a.opening + a.net_qty AS closingQty
                FROM agg a
                LEFT JOIN suppliers sup ON sup.id = a.supplier_id
                LEFT JOIN goods gg ON gg.id = a.goods_id
                LEFT JOIN colors col ON col.id = a.color_id
                LEFT JOIN ord od ON od.supplier_id = a.supplier_id AND od.goods_id = a.goods_id
                     AND od.goods_code_snapshot IS NOT DISTINCT FROM a.goods_code_snapshot
                     AND od.goods_name_snapshot IS NOT DISTINCT FROM a.goods_name_snapshot
                     AND COALESCE(od.color_id,'00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(a.color_id,'00000000-0000-0000-0000-000000000000'::uuid)
                WHERE (CAST(:kw AS text) IS NULL
                       OR LOWER(COALESCE(a.goods_name_snapshot,'')) LIKE LOWER(:kw)
                       OR LOWER(COALESCE(a.goods_code_snapshot,'')) LIKE LOWER(:kw)
                       OR LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw))
                ORDER BY supplierName NULLS LAST, goodsDesc
                LIMIT :__limit OFFSET :__offset
                """;
        var q = em.createNativeQuery(sql);
        q.setParameter("supplierId", supplierId);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("kw", (kw == null || kw.isBlank()) ? null : "%" + kw.toLowerCase() + "%");
        q.setParameter("__limit", safeSize);
        q.setParameter("__offset", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            items.add(responseRow(cols, r, priceMasked));
        }

        String countSql = """
                WITH flow AS (
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date AS d, i.qty AS signed_qty, 17 AS mt
                    FROM subcontract_receipt_items i JOIN subcontract_receipts o ON o.id = i.receipt_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 18
                    FROM subcontract_return_items i JOIN subcontract_returns o ON o.id = i.return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 15
                    FROM subcontract_material_issue_items i JOIN subcontract_material_issues o ON o.id = i.issue_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, i.qty, 16
                    FROM subcontract_material_return_items i JOIN subcontract_material_returns o ON o.id = i.material_return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -i.qty, 19
                    FROM subcontract_waste_items i JOIN subcontract_wastes o ON o.id = i.waste_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                ),
                agg AS (
                    SELECT supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id
                    FROM flow
                    WHERE (CAST(:supplierId AS uuid) IS NULL OR supplier_id = :supplierId)
                    GROUP BY supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id
                )
                SELECT COUNT(*) FROM agg a
                LEFT JOIN goods gg ON gg.id = a.goods_id
                WHERE (CAST(:kw AS text) IS NULL
                       OR LOWER(COALESCE(a.goods_name_snapshot,'')) LIKE LOWER(:kw)
                       OR LOWER(COALESCE(a.goods_code_snapshot,'')) LIKE LOWER(:kw)
                       OR LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw))
                """;
        var cq = em.createNativeQuery(countSql);
        cq.setParameter("supplierId", supplierId);
        cq.setParameter("kw", (kw == null || kw.isBlank()) ? null : "%" + kw.toLowerCase() + "%");
        long total = ((Number) cq.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

        return new ReportTableResponse(safeCols, items, Map.of(), safePage, safeSize, total, totalPages);
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
     * {RECEIPT|RETURN|MATERIAL_ISSUE|MATERIAL_RETURN}/{detail|summary} 或独立 in-out-status。
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
            case "RECEIPT/detail"         -> (pg, sz) -> receiptDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "RECEIPT/summary"        -> (pg, sz) -> receiptSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "RETURN/detail"          -> (pg, sz) -> returnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "RETURN/summary"         -> (pg, sz) -> returnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "MATERIAL_ISSUE/detail"  -> (pg, sz) -> materialIssueDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "MATERIAL_ISSUE/summary" -> (pg, sz) -> materialIssueSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "MATERIAL_RETURN/detail" -> (pg, sz) -> materialReturnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "MATERIAL_RETURN/summary"-> (pg, sz) -> materialReturnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            // 出入状况表综合聚合，不接受 sort/facets；忽略 sort/order 参数（无注入风险）。
            case "in-out-status"          -> (pg, sz) -> inOutStatus(supplierId, dateFrom, dateTo, kw, pg, sz);
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

    // ======================== 保留：月度汇总（MV，前端不再暴露入口） ========================

    @Transactional(readOnly = true)
    public List<SubcontractMonthlyRow> monthly(String docType, LocalDate dateFrom, LocalDate dateTo, int limit) {
        boolean priceMasked = subcontractPriceMasked();
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, goods_code_snapshot, goods_name_snapshot, supplier_id,
                       SUM(qty_sum) AS qty, SUM(amt_local) AS amt, SUM(line_cnt) AS lines
                FROM subcontract_monthly_mv
                WHERE (CAST(:docType AS text) IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                GROUP BY doc_type, ym, goods_id, goods_code_snapshot, goods_name_snapshot, supplier_id
                ORDER BY %s
                LIMIT :limit
                """.formatted(priceMasked
                ? "ym DESC, doc_type, goods_id"
                : "amt DESC NULLS LAST"));
        q.setParameter("docType", docType);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> monthlyRow(r, priceMasked)).toList();
    }

    static SubcontractMonthlyRow monthlyRow(Object[] r, boolean priceMasked) {
        return new SubcontractMonthlyRow(
                (String) r[0],
                NativeValueConverters.toLocalDate(r[1]),
                (java.util.UUID) r[2],
                (String) r[3],
                (String) r[4],
                NIL.equals(r[5]) ? null : (java.util.UUID) r[5],
                (BigDecimal) r[6],
                priceMasked ? null : (BigDecimal) r[7],
                ((Number) r[8]).longValue(),
                priceMasked
        );
    }

    // ======================== 内部结构 ========================

    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {}

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
