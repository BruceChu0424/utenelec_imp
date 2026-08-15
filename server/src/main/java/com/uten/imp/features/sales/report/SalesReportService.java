package com.uten.imp.features.sales.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
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
 * 销售报表查询（销售管理 / 销售报表）。
 *
 * <p>三类入口（与采购 PurchaseReportService 同型，本类为销售包内独立实现）：
 * <ol>
 *   <li>{@link #detail}/{@link #summary} 8 张报表：订货/出货/退货/其它出货 各明细/汇总。
 *       <b>服务端 JOIN 出"显示就绪"行</b>（客户/仓库/货品/颜色/类别/人员名/总监均已解析），
 *       支持日期/客户/仓库/状态/关键字过滤 + 关键列 facet 表头筛选 + 分页。**报价无报表**（不在 docType 内）。</li>
 *   <li>{@link #monthly} 月度汇总（sales_monthly_mv 上卷，保留）。**迁末已刷新**（migrate_sales.sql 调 refresh_sales_monthly_mv）。</li>
 *   <li>{@link #pending} 待交货订货汇总（sales_order_pending_v，保留）。</li>
 * </ol>
 *
 * <p>明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
 *
 * <p>人员名：历史单据 {@code *_legacy_id} 保留，但 {@code employees.legacy_id} 尚未录入 → 暂显空；
 * current UUID 优先关联员工；仅 UUID 为空时按 legacy_id 回退，避免双命中重复报表行。
 *
 * <p>总监：LEFT JOIN {@code client_director_v}（视图，client_categories 上溯 level=0 根 name）。
 *
 * <p>结帐方式：{@code payment_style_id} 原值（INT），按 {@link SalesSettlementStyle} 字典渲染。
 *
 * <p>_null 参数类型坑_：可选过滤用 {@code CAST(:param AS 类型) IS NULL OR ...}（见 MEMORY）。
 */
@Service
@RequiredArgsConstructor
public class SalesReportService {

    private static final UUID NIL = UUID.fromString("00000000-0000-0000-0000-000000000000");

    public static final String DOC_ORDER = "ORDER";
    public static final String DOC_SHIPMENT = "SHIPMENT";
    public static final String DOC_OTHER_SHIPMENT = "OTHER_SHIPMENT";
    public static final String DOC_RETURN = "RETURN";

    private static final String DEAL_EXPR =
            "CASE WHEN COALESCE(i.discount,0) > 0 AND COALESCE(i.discount,0) < 1 THEN i.amount_local * i.discount ELSE i.amount_local END";

    private final EntityManager em;
    private final SystemSettingsService settings;
    private final com.uten.imp.features.sales.order.SalesPriceMasker priceMasker;
    private final SalesDocumentAccessPolicy accessPolicy;

    /** 订货报表价格列（SOP §三8 脱敏键集合：明细金额族）。 */
    private static final List<String> ORDER_PRICE_KEYS =
            List.of("totalAmount", "machiningPrice", "price", "discount", "amount");

    /** 价格脱敏：无 sales_order:price:view 时把订货明细报表的价格列置 null（导出同口径——导出走本方法分页累积）。 */
    private void maskOrderPricesIfNeeded(ReportTableResponse r) {
        if (priceMasker.canView()) return;
        for (Map<String, Object> row : r.rows()) {
            for (String k : ORDER_PRICE_KEYS) {
                if (row.containsKey(k)) row.put(k, null);
            }
        }
    }

    // ======================== 通用执行器（与采购同型） ========================

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
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

        var countQ = em.createNativeQuery("SELECT COUNT(*) " + fromJoin + " " + full.sql());
        full.params().forEach(countQ::setParameter);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);

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
                if ("style".equals(spec.filterType()) && v != null) {
                    lbl = SalesSettlementStyle.label(toInt(v));
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
        if ("style".equals(col.type())) return SalesSettlementStyle.label(toInt(v));
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

    // ======================== 主过滤（公共） ========================

    private static void addCommonDocFilters(WhereBuilder w, String billNo, UUID clientId, UUID warehouseId,
                                            Short status, LocalDate dateFrom, LocalDate dateTo, String kw,
                                            String billNoCol, String dateCol) {
        if (billNo != null && !billNo.isBlank()) w.add(billNoCol + " LIKE :billNo", "billNo", "%" + billNo + "%");
        if (clientId != null) w.add("o.client_id = :clientId", "clientId", clientId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add(dateCol + " >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add(dateCol + " <= :dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank()) {
            w.add("(LOWER(" + billNoCol + ") LIKE LOWER(:kw) OR LOWER(COALESCE(c.name,'')) LIKE LOWER(:kw) OR LOWER(COALESCE(i.goods_name_snapshot,'')) LIKE LOWER(:kw) OR LOWER(COALESCE(i.goods_code_snapshot,'')) LIKE LOWER(:kw) OR EXISTS (SELECT 1 FROM goods gg WHERE gg.id = i.goods_id AND LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw)))",
                    "kw", "%" + kw.toLowerCase() + "%");
        }
    }

    /** 汇总关键字：客户名 / 单号 模糊匹配（汇总表按客户聚合，搜客户为主）。 */
    private static void addSummaryKw(WhereBuilder w, String kw, String billNoCol) {
        if (kw != null && !kw.isBlank())
            w.add("(LOWER(COALESCE(c.name,'')) LIKE LOWER(:kw) OR LOWER(" + billNoCol + ") LIKE LOWER(:kw))",
                    "kw", "%" + kw.toLowerCase() + "%");
    }

    private void addOwnerReadFilter(WhereBuilder where, String ownerColumn, String parameterName) {
        var scope = accessPolicy.nativeReadScope(ownerColumn, parameterName);
        where.add(scope.predicate(), scope.parameterName(), scope.owners());
    }

    // ======================== 明细报表（按 docType 派发） ========================

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse detail(String docType, String billNo, UUID clientId, UUID warehouseId, Short status,
                                      LocalDate dateFrom, LocalDate dateTo, String kw,
                                      Map<String, String> facets, int page, int size, String sort, String order) {
        return detail(docType, billNo, clientId, null, warehouseId, status,
                dateFrom, dateTo, kw, facets, page, size, sort, order);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse detail(String docType, String billNo, UUID clientId, UUID currencyId,
                                      UUID warehouseId, Short status, LocalDate dateFrom,
                                      LocalDate dateTo, String kw, Map<String, String> facets,
                                      int page, int size, String sort, String order) {
        String dt = normalizeDocType(docType);
        return switch (dt) {
            case DOC_ORDER -> orderDetail(billNo, clientId, currencyId, status,
                    dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_SHIPMENT -> shipmentDetail(billNo, clientId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_RETURN -> returnDetail(billNo, clientId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_OTHER_SHIPMENT -> otherShipmentDetail(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            default -> throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + dt);
        };
    }

    // ----- 销售订货明细 -----
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse orderDetail(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                           LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        return orderDetail(billNo, clientId, null, status, dateFrom, dateTo,
                kw, facets, page, size, sort, order);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse orderDetail(String billNo, UUID clientId, UUID currencyId,
                                           Short status, LocalDate dateFrom, LocalDate dateTo,
                                           String kw, Map<String, String> facets, int page,
                                           int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户", 160), ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.text("region", "区域", 100),
                ReportColumn.text("contractNo", "合同编号", 130), ReportColumn.money("totalAmount", "总额"),
                ReportColumn.bool("closed", "是否完成"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("series", "系列", 90), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("clientOrderNo", "客户订单号", 120),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("spec", "规格", 140),
                ReportColumn.number("circumference", "围数"), ReportColumn.money("machiningPrice", "机加价"),
                ReportColumn.money("price", "单价"), ReportColumn.number("discount", "折扣"),
                ReportColumn.money("amount", "金额"), ReportColumn.number("inboundQty", "进仓数量"),
                ReportColumn.number("shippedQty", "发货数量"), ReportColumn.number("pendingQty", "未发数量"),
                ReportColumn.number("stockQty", "库存数量"), ReportColumn.text("inNo", "成品进仓单号", 140),
                ReportColumn.text("outNo", "销售出货单号", 140),
                ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳销售订货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", i.bill_date AS "billDate", c.name AS "clientName",
                       currency.code AS "currencyCode", c.region AS "region",
                       o.contract_no AS "contractNo", o.total_original AS "totalAmount",
                       o.is_closed AS "closed", (o.status = 1) AS "approved",
                       g.series AS "series", i.goods_code_snapshot AS "goodsCode", g.model AS "model",
                       i.client_no AS "clientOrderNo", i.goods_name_snapshot AS "goodsName", g.spec AS "spec",
                       i.circumference AS "circumference", i.machining_price AS "machiningPrice",
                       i.price AS "price", i.discount AS "discount", i.amount_original AS "amount",
                       i.inbound_qty AS "inboundQty", i.shipped_qty AS "shippedQty",
                       (i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) AS "pendingQty",
                       COALESCE(sb.stock_qty, 0) AS "stockQty", i.in_no AS "inNo", i.out_no AS "outNo",
                       i.remark AS "remark", o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN currencies currency ON currency.id = o.currency_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN (SELECT goods_id, SUM(qty) AS stock_qty FROM stock_balances GROUP BY goods_id) sb ON sb.goods_id = i.goods_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addOwnerReadFilter(w, "o.owner_employee_id", "salesOwners");
        addCommonDocFilters(w, billNo, clientId, null, status, dateFrom, dateTo, kw, "i.bill_no", "i.bill_date");
        if (currencyId != null) {
            w.add("o.currency_id=:currencyId", "currencyId", currencyId);
        }
        List<FacetSpec> specs = List.of(
                facetClient(),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"),
                new FacetSpec("closed", "o.is_closed AS v, CASE WHEN o.is_closed THEN '已完成' ELSE '未完成' END AS lbl", "o.is_closed", "o.is_closed", "bool"));
        ReportTableResponse r = execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, i.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
        maskOrderPricesIfNeeded(r); // 价格脱敏（SOP §三8）：无权限者价格列置 null，导出同口径
        return r;
    }

    // ----- 销售出货明细 -----
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse shipmentDetail(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                              LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "开单日期"), ReportColumn.text("clientName", "客户", 160),
                ReportColumn.text("region", "区域", 100),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.bool("approved", "是否审核"), ReportColumn.text("series", "系列", 90),
                ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"), ReportColumn.number("discount", "折扣"),
                ReportColumn.money("amount", "金额"), ReportColumn.money("dealAmount", "成交金额"),
                ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳销售出货单编辑页
        String dataSelect = """
                SELECT i.bill_date AS "billDate", c.name AS "clientName", c.region AS "region",
                       o.payment_style_id AS "settlementStyle", (o.status = 1) AS "approved",
                       g.series AS "series", i.goods_code_snapshot AS "goodsCode",
                       i.goods_name_snapshot AS "goodsName", i.qty AS "qty", i.price AS "price",
                       i.discount AS "discount", i.amount_local AS "amount",
                       """ + DEAL_EXPR + " AS \"dealAmount\", i.remark AS \"remark\", o.id AS \"__srcId\"";
        String fromJoin = """
                FROM sales_shipment_items i
                JOIN sales_shipments o ON o.id = i.shipment_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN goods g ON g.id = i.goods_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addOwnerReadFilter(w, "o.owner_employee_id", "salesOwners");
        addCommonDocFilters(w, billNo, clientId, null, status, dateFrom, dateTo, kw, "i.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetClient(),
                new FacetSpec("settlementStyle", "o.payment_style_id AS v, CAST(o.payment_style_id AS text) AS lbl", "o.payment_style_id", "o.payment_style_id", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, i.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ----- 销售退货明细 -----
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse returnDetail(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                            LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户", 160), ReportColumn.text("sellerName", "业务员", 100),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("director", "总监", 110),
                ReportColumn.bool("approved", "是否审核"), ReportColumn.text("series", "系列", 90),
                ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.number("qty", "数量"), ReportColumn.money("price", "单价"),
                ReportColumn.money("amount", "金额"), ReportColumn.number("discount", "折扣"),
                ReportColumn.money("dealAmount", "成交金额"), ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳销售退货单编辑页
        String dataSelect = """
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate", c.name AS "clientName",
                       em_sel.full_name AS "sellerName", c.region AS "region", d.director AS "director",
                       (o.status = 1) AS "approved", g.series AS "series",
                       i.goods_code_snapshot AS "goodsCode", i.goods_name_snapshot AS "goodsName",
                       col.name AS "colorName", i.qty AS "qty", i.price AS "price", i.amount_local AS "amount",
                       i.discount AS "discount",
                       """ + DEAL_EXPR + " AS \"dealAmount\", i.remark AS \"remark\", o.id AS \"__srcId\"";
        String fromJoin = """
                FROM sales_return_items i
                JOIN sales_returns o ON o.id = i.return_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN client_director_v d ON d.client_id = o.client_id
                LEFT JOIN employees em_sel ON em_sel.id = o.seller_id
                    OR (o.seller_id IS NULL AND em_sel.legacy_id = o.seller_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addOwnerReadFilter(w, "o.owner_employee_id", "salesOwners");
        addCommonDocFilters(w, billNo, clientId, null, status, dateFrom, dateTo, kw, "i.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetClient(),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, i.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ----- 其它出货明细 -----
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse otherShipmentDetail(String billNo, UUID clientId, UUID warehouseId, Short status,
                                                   LocalDate dateFrom, LocalDate dateTo, String kw,
                                                   Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("clientName", "客户", 160), ReportColumn.text("director", "总监", 110),
                ReportColumn.text("region", "区域", 100), ReportColumn.text("warehouseName", "仓库", 120),
                ReportColumn.text("categoryName", "单类", 100), ReportColumn.number("parcelCount", "总件数"),
                ReportColumn.text("senderName", "送货人", 100), ReportColumn.text("shipAddr", "送货地址", 160),
                new ReportColumn("settlementStyle", "结帐方式", "style", 100),
                ReportColumn.money("totalAmount", "总额"), ReportColumn.bool("approved", "是否审核"),
                ReportColumn.text("series", "系列", 90), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("colorName", "颜色", 80), ReportColumn.number("cartonCount", "箱数"),
                ReportColumn.number("parcelQty", "把/箱"), ReportColumn.number("weight", "重量"),
                ReportColumn.number("circumference", "围"), ReportColumn.number("qty", "数量"),
                ReportColumn.money("materialPrice", "材料价"), ReportColumn.money("dieCastPrice", "压铸价"),
                ReportColumn.money("machiningPrice", "机加价"), ReportColumn.money("price", "单价"),
                ReportColumn.money("amount", "金额"), ReportColumn.number("returnedQty", "退货数量"),
                ReportColumn.money("returnedAmount", "退货金额"), ReportColumn.number("discount", "折扣"),
                ReportColumn.money("actualAmount", "实际金额"),
                ReportColumn.text("remark", "备注", 160),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳其它出货单编辑页
        String dataSelect = """
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate", c.name AS "clientName", d.director AS "director",
                       c.region AS "region", wh.name AS "warehouseName", cc.name AS "categoryName",
                       o.parcel_count AS "parcelCount", em_snd.full_name AS "senderName", o.ship_addr AS "shipAddr",
                       o.payment_style_id AS "settlementStyle", o.total_local AS "totalAmount",
                       (o.status = 1) AS "approved", g.series AS "series", i.goods_code_snapshot AS "goodsCode", g.model AS "model",
                       i.client_model AS "customerModel", i.goods_name_snapshot AS "goodsName", g.spec AS "spec",
                       col.name AS "colorName", i.carton_count AS "cartonCount", i.parcel_qty AS "parcelQty",
                       i.weight AS "weight", i.circumference AS "circumference", i.qty AS "qty",
                       i.material_price AS "materialPrice", i.die_cast_price AS "dieCastPrice",
                       i.machining_price AS "machiningPrice", i.price AS "price", i.amount_local AS "amount",
                       i.returned_qty AS "returnedQty", i.returned_amount AS "returnedAmount", i.discount AS "discount",
                       (i.amount_local - COALESCE(i.returned_amount,0)) AS "actualAmount",
                       i.remark AS "remark", o.id AS "__srcId"
                """;
        String fromJoin = """
                FROM sales_other_shipment_items i
                JOIN sales_other_shipments o ON o.id = i.shipment_id
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN client_director_v d ON d.client_id = o.client_id
                LEFT JOIN client_categories cc ON cc.id = c.category_id
                LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
                LEFT JOIN employees em_snd ON em_snd.id = o.sender_id
                    OR (o.sender_id IS NULL AND em_snd.legacy_id = o.sender_legacy_id)
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        addOwnerReadFilter(w, "o.owner_employee_id", "salesOwners");
        addCommonDocFilters(w, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, "i.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetClient(), facetWarehouse("warehouseName"),
                new FacetSpec("settlementStyle", "o.payment_style_id AS v, CAST(o.payment_style_id AS text) AS lbl", "o.payment_style_id", "o.payment_style_id", "style"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl", "(o.status = 1)", "o.status = 1", "bool"));
        return execute(cols, dataSelect, fromJoin, w, "i.bill_date DESC, i.bill_no, i.line_no NULLS LAST", specs, facets, page, size, sort, order);
    }

    // ======================== 汇总报表（按 docType 派发；一行一客户） ========================
    //
    // 口径：日期范围内按客户聚合 —— 每个客户一行，单据数/数量/金额全部加总（无单号/开单日期等
    // 单行字段）。行点击钻取该客户本期明细（前端调 detail 端点 + clientId），故行带隐藏 __clientId。
    // 实现：内层子查询按 client_id GROUP BY 聚合（过滤条件下推到子查询），外层派生表 t 走通用
    // execute（COUNT(*)=客户数、列排序按别名、facet 走 t."__clientId"）。

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse summary(String docType, String billNo, UUID clientId, UUID warehouseId, Short status,
                                       LocalDate dateFrom, LocalDate dateTo, String kw,
                                       Map<String, String> facets, int page, int size, String sort, String order) {
        String dt = normalizeDocType(docType);
        return switch (dt) {
            case DOC_ORDER -> orderSummary(billNo, clientId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_SHIPMENT -> shipmentSummary(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_RETURN -> returnSummary(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            case DOC_OTHER_SHIPMENT -> otherShipmentSummary(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, page, size, sort, order);
            default -> throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + dt);
        };
    }

    /** 客户汇总子查询过滤（下推到聚合子查询内；别名 o=单头、c=客户）。 */
    private static WhereBuilder summaryInnerWhere(String billNo, UUID clientId, UUID warehouseId,
                                                  Short status, LocalDate dateFrom, LocalDate dateTo, String kw) {
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(o.is_deleted,false)=false");
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (clientId != null) w.add("o.client_id = :clientId", "clientId", clientId);
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        addSummaryKw(w, kw, "o.bill_no");
        return w;
    }

    /** 汇总外层 facet（客户列）：值=客户 UUID，label=客户名；空客户走 __null__ 档。 */
    private static FacetSpec facetClientSummary() {
        return new FacetSpec("clientName",
                "CAST(t.\"__clientId\" AS text) AS v, t.\"clientName\" AS lbl",
                "t.\"__clientId\", t.\"clientName\"", "t.\"__clientId\"", "uuid");
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse orderSummary(String billNo, UUID clientId, Short status, LocalDate dateFrom,
                                            LocalDate dateTo, String kw, Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户", 200), ReportColumn.text("region", "区域", 100),
                ReportColumn.text("currencyCode", "币别", 80),
                ReportColumn.text("categoryName", "单类", 110), ReportColumn.number("docCount", "单据数"),
                ReportColumn.number("totalQty", "数量合计"), ReportColumn.money("totalAmount", "订货总额"),
                ReportColumn.text("__clientId", ""),
                ReportColumn.text("__currencyId", ""));  // 隐藏：下钻必须同时限定客户与币种
        String dataSelect = """
                SELECT t."clientName", t."region", t."currencyCode", t."categoryName",
                       t."docCount", t."totalQty", t."totalAmount",
                       t."__clientId", t."__currencyId"
                """;
        WhereBuilder innerW = summaryInnerWhere(billNo, clientId, null, status, dateFrom, dateTo, kw);
        addOwnerReadFilter(innerW, "o.owner_employee_id", "salesOwners");
        WhereBuilder.Built inner = innerW.build(null);
        String fromJoin = """
                FROM (
                  SELECT o.client_id AS "__clientId", o.currency_id AS "__currencyId",
                         COALESCE(MAX(c.name), '(未指定客户)') AS "clientName",
                         MAX(c.region) AS "region", MAX(currency.code) AS "currencyCode",
                         MAX(cc.name) AS "categoryName",
                         COUNT(o.id) AS "docCount",
                         COALESCE(SUM(x.qty), 0) AS "totalQty", COALESCE(SUM(x.amount), 0) AS "totalAmount"
                  FROM sales_orders o
                  LEFT JOIN clients c ON c.id = o.client_id
                  LEFT JOIN client_categories cc ON cc.id = c.category_id
                  LEFT JOIN currencies currency ON currency.id = o.currency_id
                  LEFT JOIN (SELECT order_id, SUM(qty) AS qty, SUM(amount_original) AS amount
                             FROM sales_order_items WHERE COALESCE(is_deleted,false)=false GROUP BY order_id) x
                    ON x.order_id = o.id
                  """ + " " + inner.sql() + " " + """
                  GROUP BY o.client_id, o.currency_id
                ) t
                """;
        WhereBuilder outer = new WhereBuilder("WHERE 1=1");
        // 内层参数直接挂到外层（参数名同源，execute 统一 setParameter）。
        inner.params().forEach((k, v) -> outer.add("1=1", k, v));
        ReportTableResponse r = execute(cols, dataSelect, fromJoin, outer, "\"totalAmount\" DESC, \"clientName\"",
                List.of(facetClientSummary()), facets, page, size, sort, order);
        maskOrderPricesIfNeeded(r); // 价格脱敏（SOP §三8）：订货总额同明细口径置 null
        return r;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse shipmentSummary(String billNo, UUID clientId, UUID warehouseId, Short status,
                                               LocalDate dateFrom, LocalDate dateTo, String kw,
                                               Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户", 200), ReportColumn.text("region", "区域", 100),
                ReportColumn.text("categoryName", "单类", 110), ReportColumn.number("docCount", "单据数"),
                ReportColumn.number("totalQty", "数量合计"), ReportColumn.money("totalAmount", "金额合计"),
                ReportColumn.money("dealAmount", "成交金额合计"),
                ReportColumn.text("__clientId", ""));  // 隐藏：行点击钻取该客户明细
        String dataSelect = """
                SELECT t."clientName", t."region", t."categoryName", t."docCount", t."totalQty", t."totalAmount",
                       t."dealAmount", t."__clientId"
                """;
        WhereBuilder innerW = summaryInnerWhere(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw);
        addOwnerReadFilter(innerW, "o.owner_employee_id", "salesOwners");
        WhereBuilder.Built inner = innerW.build(null);
        String fromJoin = """
                FROM (
                  SELECT o.client_id AS "__clientId",
                         COALESCE(MAX(c.name), '(未指定客户)') AS "clientName",
                         MAX(c.region) AS "region", MAX(cc.name) AS "categoryName",
                         COUNT(o.id) AS "docCount",
                         COALESCE(SUM(x.qty), 0) AS "totalQty", COALESCE(SUM(x.amount), 0) AS "totalAmount",
                         COALESCE(SUM(x.deal), 0) AS "dealAmount"
                  FROM sales_shipments o
                  LEFT JOIN clients c ON c.id = o.client_id
                  LEFT JOIN client_categories cc ON cc.id = c.category_id
                  LEFT JOIN (SELECT shipment_id, SUM(qty) AS qty, SUM(amount_local) AS amount,
                                    SUM(CASE WHEN COALESCE(discount,0) > 0 AND COALESCE(discount,0) < 1
                                             THEN amount_local * discount ELSE amount_local END) AS deal
                             FROM sales_shipment_items WHERE COALESCE(is_deleted,false)=false GROUP BY shipment_id) x
                    ON x.shipment_id = o.id
                  """ + " " + inner.sql() + " " + """
                  GROUP BY o.client_id
                ) t
                """;
        WhereBuilder outer = new WhereBuilder("WHERE 1=1");
        inner.params().forEach((k, v) -> outer.add("1=1", k, v));
        return execute(cols, dataSelect, fromJoin, outer, "\"dealAmount\" DESC, \"clientName\"",
                List.of(facetClientSummary()), facets, page, size, sort, order);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse returnSummary(String billNo, UUID clientId, UUID warehouseId, Short status,
                                             LocalDate dateFrom, LocalDate dateTo, String kw,
                                             Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户", 200), ReportColumn.text("region", "区域", 100),
                ReportColumn.number("docCount", "单据数"), ReportColumn.number("totalQty", "数量合计"),
                ReportColumn.money("totalAmount", "退货金额合计"), ReportColumn.money("dealAmount", "成交金额合计"),
                ReportColumn.text("__clientId", ""));  // 隐藏：行点击钻取该客户明细
        String dataSelect = """
                SELECT t."clientName", t."region", t."docCount", t."totalQty", t."totalAmount", t."dealAmount",
                       t."__clientId"
                """;
        WhereBuilder innerW = summaryInnerWhere(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw);
        addOwnerReadFilter(innerW, "o.owner_employee_id", "salesOwners");
        WhereBuilder.Built inner = innerW.build(null);
        String fromJoin = """
                FROM (
                  SELECT o.client_id AS "__clientId",
                         COALESCE(MAX(c.name), '(未指定客户)') AS "clientName",
                         MAX(c.region) AS "region",
                         COUNT(o.id) AS "docCount",
                         COALESCE(SUM(x.qty), 0) AS "totalQty", COALESCE(SUM(x.amount), 0) AS "totalAmount",
                         COALESCE(SUM(x.deal), 0) AS "dealAmount"
                  FROM sales_returns o
                  LEFT JOIN clients c ON c.id = o.client_id
                  LEFT JOIN (SELECT return_id, SUM(qty) AS qty, SUM(amount_local) AS amount,
                                    SUM(CASE WHEN COALESCE(discount,0) > 0 AND COALESCE(discount,0) < 1
                                             THEN amount_local * discount ELSE amount_local END) AS deal
                             FROM sales_return_items WHERE COALESCE(is_deleted,false)=false GROUP BY return_id) x
                    ON x.return_id = o.id
                  """ + " " + inner.sql() + " " + """
                  GROUP BY o.client_id
                ) t
                """;
        WhereBuilder outer = new WhereBuilder("WHERE 1=1");
        inner.params().forEach((k, v) -> outer.add("1=1", k, v));
        return execute(cols, dataSelect, fromJoin, outer, "\"totalAmount\" DESC, \"clientName\"",
                List.of(facetClientSummary()), facets, page, size, sort, order);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public ReportTableResponse otherShipmentSummary(String billNo, UUID clientId, UUID warehouseId, Short status,
                                                    LocalDate dateFrom, LocalDate dateTo, String kw,
                                                    Map<String, String> facets, int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户", 200), ReportColumn.text("region", "区域", 100),
                ReportColumn.text("categoryName", "单类", 110), ReportColumn.number("docCount", "单据数"),
                ReportColumn.number("totalQty", "数量合计"), ReportColumn.money("totalAmount", "金额合计"),
                ReportColumn.money("actualAmount", "实际金额合计"),
                ReportColumn.text("__clientId", ""));  // 隐藏：行点击钻取该客户明细
        String dataSelect = """
                SELECT t."clientName", t."region", t."categoryName", t."docCount", t."totalQty", t."totalAmount",
                       t."actualAmount", t."__clientId"
                """;
        WhereBuilder innerW = summaryInnerWhere(billNo, clientId, warehouseId, status, dateFrom, dateTo, kw);
        addOwnerReadFilter(innerW, "o.owner_employee_id", "salesOwners");
        WhereBuilder.Built inner = innerW.build(null);
        String fromJoin = """
                FROM (
                  SELECT o.client_id AS "__clientId",
                         COALESCE(MAX(c.name), '(未指定客户)') AS "clientName",
                         MAX(c.region) AS "region", MAX(cc.name) AS "categoryName",
                         COUNT(o.id) AS "docCount",
                         COALESCE(SUM(x.qty), 0) AS "totalQty", COALESCE(SUM(x.amount), 0) AS "totalAmount",
                         COALESCE(SUM(x.actual), 0) AS "actualAmount"
                  FROM sales_other_shipments o
                  LEFT JOIN clients c ON c.id = o.client_id
                  LEFT JOIN client_categories cc ON cc.id = c.category_id
                  LEFT JOIN (SELECT shipment_id, SUM(qty) AS qty, SUM(amount_local) AS amount,
                                    SUM(amount_local - COALESCE(returned_amount,0)) AS actual
                             FROM sales_other_shipment_items WHERE COALESCE(is_deleted,false)=false GROUP BY shipment_id) x
                    ON x.shipment_id = o.id
                  """ + " " + inner.sql() + " " + """
                  GROUP BY o.client_id
                ) t
                """;
        WhereBuilder outer = new WhereBuilder("WHERE 1=1");
        inner.params().forEach((k, v) -> outer.add("1=1", k, v));
        return execute(cols, dataSelect, fromJoin, outer, "\"actualAmount\" DESC, \"clientName\"",
                List.of(facetClientSummary()), facets, page, size, sort, order);
    }

    // ======================== facet 复用 ========================

    private static FacetSpec facetClient() {
        return new FacetSpec("clientName", "CAST(c.id AS text) AS v, c.name AS lbl", "c.id, c.name", "o.client_id", "uuid");
    }

    private static FacetSpec facetWarehouse(String key) {
        return new FacetSpec(key, "CAST(wh.id AS text) AS v, wh.name AS lbl", "wh.id, wh.name", "o.warehouse_id", "uuid");
    }

    // ======================== 导出（加密 Excel） ========================

    /**
     * 导出某报表全量（不分页，循环 size=500 累积全部行），返回 ExportColumn + 行 Map。
     * 列定义映射 ReportColumn→ExportColumn（剥离 width）。report 取值与 GET 路径一致
     * （{docType}/{detail|summary}，docType 大写）：ORDER/detail 等 8 个。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:export')")
    public ExportPayload export(String report, Map<String, String> p, String sort, String order) {
        String billNo = p == null ? null : p.get("billNo");
        UUID clientId = parseUuid(p == null ? null : p.get("clientId"));
        UUID currencyId = parseUuid(p == null ? null : p.get("currencyId"));
        UUID warehouseId = parseUuid(p == null ? null : p.get("warehouseId"));
        Short status = parseShort(p == null ? null : p.get("status"));
        LocalDate dateFrom = parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = parseDate(p == null ? null : p.get("dateTo"));
        String kw = p == null ? null : p.get("keyword");
        Map<String, String> facets = facetsOfMap(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (report) {
            case "ORDER/detail"           -> (pg, sz) -> detail(DOC_ORDER, billNo, clientId, currencyId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "ORDER/summary"          -> (pg, sz) -> summary(DOC_ORDER, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "SHIPMENT/detail"        -> (pg, sz) -> detail(DOC_SHIPMENT, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "SHIPMENT/summary"       -> (pg, sz) -> summary(DOC_SHIPMENT, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "RETURN/detail"          -> (pg, sz) -> detail(DOC_RETURN, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "RETURN/summary"         -> (pg, sz) -> summary(DOC_RETURN, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "OTHER_SHIPMENT/detail"  -> (pg, sz) -> detail(DOC_OTHER_SHIPMENT, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "OTHER_SHIPMENT/summary" -> (pg, sz) -> summary(DOC_OTHER_SHIPMENT, billNo, clientId, warehouseId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
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
    @PreAuthorize("hasAuthority('sales_report:view')")
    public List<MonthlySummaryRow> monthly(String docType, UUID clientId, UUID goodsId,
                                           LocalDate dateFrom, LocalDate dateTo, int limit) {
        String dt = docType == null ? null : docType.trim().toUpperCase();
        if (dt != null && !java.util.Set.of("QUOTE", DOC_ORDER, DOC_SHIPMENT,
                DOC_OTHER_SHIPMENT, DOC_RETURN).contains(dt)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知销售月报类型：" + docType);
        }
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var ownerScope = accessPolicy.scope();
        var scopedOwners = accessPolicy.nativeReadScopeWithLegacySentinel(
                "owner_employee_id", "salesOwners", NIL, ownerScope);
        var q = em.createNativeQuery("""
                SELECT doc_type, ym, goods_id, client_id, currency_id,
                       SUM(qty_sum) AS qty,
                       SUM(CASE WHEN doc_type = 'ORDER' THEN amt_original ELSE amt_local END) AS amt,
                       SUM(line_cnt) AS lines
                FROM sales_monthly_mv
                WHERE (CAST(:docType AS text) IS NULL OR doc_type = :docType)
                  AND (CAST(:from AS date) IS NULL OR ym >= :from)
                  AND (CAST(:to AS date) IS NULL OR ym <= :to)
                  AND (CAST(:clientId AS uuid) IS NULL OR client_id = :clientId)
                  AND (CAST(:goodsId AS uuid) IS NULL OR goods_id = :goodsId)
                  """ + "AND " + scopedOwners.predicate() + " " + """
                GROUP BY doc_type, ym, goods_id, client_id, currency_id
                ORDER BY amt DESC NULLS LAST
                LIMIT :limit
                """);
        scopedOwners.bind(q);
        q.setParameter("docType", dt);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("clientId", clientId);
        q.setParameter("goodsId", goodsId);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new MonthlySummaryRow(
                (String) r[0],
                ((java.sql.Date) r[1]).toLocalDate(),
                (UUID) r[2],
                NIL.equals(r[3]) ? null : (UUID) r[3],
                NIL.equals(r[4]) ? null : (UUID) r[4],
                (BigDecimal) r[5],
                (BigDecimal) r[6],
                ((Number) r[7]).longValue()
        )).toList();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_report:view')")
    public List<PendingRow> pending(UUID clientId, int limit) {
        int safeLimit = Math.min(Math.max(1, limit), 2000);
        var ownerScope = accessPolicy.scope();
        SalesDocumentAccessPolicy.NativeReadScope scopedOwners = ownerScope.seeAll()
                ? null
                : accessPolicy.nativeReadScope(
                        "o.owner_employee_id", "salesOwners", ownerScope);
        String ownerPredicate = scopedOwners == null
                ? "" : " AND " + scopedOwners.predicate();
        String sql = """
                SELECT i.goods_id, i.color_id, o.client_id, o.currency_id,
                       SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) AS pending_qty,
                       SUM(CASE WHEN i.qty > 0
                           THEN i.amount_original
                               * (i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) / i.qty
                           ELSE 0 END) AS pending_amt
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE COALESCE(i.is_deleted,false)=false
                  AND COALESCE(o.is_deleted,false)=false
                """ + ownerPredicate
                + (clientId == null ? "" : " AND o.client_id = :clientId") + " " + """
                GROUP BY i.goods_id, i.color_id, o.client_id, o.currency_id
                HAVING SUM(i.qty - i.shipped_qty + i.returned_qty - i.flag_qty) > 0
                """;
        sql += " ORDER BY pending_qty DESC LIMIT :limit";
        var q = em.createNativeQuery(sql);
        if (scopedOwners != null) {
            scopedOwners.bind(q);
        }
        if (clientId != null) q.setParameter("clientId", clientId);
        q.setParameter("limit", safeLimit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        boolean mask = !priceMasker.canView(); // 价格脱敏（SOP §三8）：待交金额同口径置 null
        return rows.stream().map(r -> new PendingRow(
                (UUID) r[0],
                r[1] == null ? null : (UUID) r[1],
                r[2] == null ? null : (UUID) r[2],
                r[3] == null ? null : (UUID) r[3],
                (BigDecimal) r[4],
                mask ? null : (BigDecimal) r[5]
        )).toList();
    }

    // ======================== 内部结构 ========================

    private static String normalizeDocType(String docType) {
        if (docType == null) throw new ApiException(ErrorCode.BUSINESS, "docType 必填");
        String dt = docType.trim().toUpperCase();
        if (dt.equals("QUOTE")) throw new ApiException(ErrorCode.BUSINESS, "销售报价无报表");
        if (!java.util.Set.of(DOC_ORDER, DOC_SHIPMENT, DOC_OTHER_SHIPMENT, DOC_RETURN).contains(dt)) {
            throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + docType);
        }
        return dt;
    }

    /** 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型。 */
    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {}

    /** WHERE 构造器：base + 若干 AND 子句（带参数）。与采购同型。 */
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
