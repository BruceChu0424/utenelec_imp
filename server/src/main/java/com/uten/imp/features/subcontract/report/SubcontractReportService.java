package com.uten.imp.features.subcontract.report;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.report.ReportQueryKit.FacetSpec;
import com.uten.imp.common.report.ReportQueryKit.WhereBuilder;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
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
        UnitProjection unitProjection=unitProjection(columns,dataSelect,fromJoin);
        columns=unitProjection.columns();dataSelect=unitProjection.select();fromJoin=unitProjection.from();
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
        String effectiveOrderBy = mainWhere.orderBy(ReportSort.resolveOrderBy(sort, order, orderBy, sortKeys));

        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql()
                + " ORDER BY " + effectiveOrderBy + " LIMIT :__limit OFFSET :__offset");
        full.params().forEach(dataQ::setParameter);
        mainWhere.searchOrderParameters().forEach(dataQ::setParameter);
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
        // 表格下方合计：与列表用同一份 full（日期/facet/关键字 + 对象级授权谓词）在**整个结果集**
        // 上聚合，与翻到第几页无关；派生表不带 LIMIT/OFFSET，所以绝不会出现「只合计当前页」。
        List<com.uten.imp.common.report.ReportTotal> totals =
                com.uten.imp.common.report.ReportTotalsCalculator.compute(
                        em, dataSelect, fromJoin, full.sql(), full.params(),
                        reportTotalSpecs(safeColumns, columns));
        totals=com.uten.imp.common.report.ReportTotal.withColumnUnits(totals,columns);

        List<ReportColumn> visible = safeColumns.stream().filter(c -> !c.key().startsWith("__")).toList();
        return new ReportTableResponse(visible, items, facets, safePage, safeSize, total, totalPages, totals);
    }

    private record UnitProjection(List<ReportColumn> columns,String select,String from) { }
    private static UnitProjection unitProjection(List<ReportColumn> columns,String select,String from) {
        var projected=new ArrayList<>(columns);
        java.util.Set<String> needed=columns.stream().map(ReportColumn::unitKey).filter(Objects::nonNull)
                .collect(java.util.stream.Collectors.toSet());
        java.util.Set<String> identities=columns.stream().map(ReportColumn::totalGroupIdentityKey).filter(Objects::nonNull)
                .collect(java.util.stream.Collectors.toSet());
        if(identities.contains("__unitId")) {
            projected.add(ReportColumn.text("__unitId",""));select+=", i.unit_id AS \"__unitId\"";
        }
        if(identities.contains("__currencyId")) {
            projected.add(ReportColumn.text("__currencyId",""));select+=", o.currency_id AS \"__currencyId\"";
        }
        if(needed.contains("__currencyName")) {
            projected.add(ReportColumn.text("__currencyName",""));
            select+=", "+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("report_currency")+" AS \"__currencyName\"";
            from+=" LEFT JOIN currencies report_currency ON report_currency.id=o.currency_id";
        }
        if(needed.contains("__unitName")) {
            projected.add(ReportColumn.text("__unitName",""));select+=", report_unit.name AS \"__unitName\"";
            from+=" LEFT JOIN units report_unit ON report_unit.id=i.unit_id";
        }
        return new UnitProjection(List.copyOf(projected),select,from);
    }

    /**
     * 把列定义里 {@code totaled(...)} 声明的合计翻译成聚合规格。
     *
     * <p>{@code emitted} = 实际下发给前端的列（脱敏后）——被 priceMasked 拿掉的金额列不在其中，
     * 合计自然也不会出现，无需另写门控。{@code projected} = dataSelect 真正投影的列，
     * 用来确认分组列（单位名/币种名）确实在派生表里。
     *
     * <p><b>声明了分组列却没投影时整项丢弃</b>，绝不退回「不分组」——那等于跨单位/跨币种相加。
     */
    private static List<com.uten.imp.common.report.ReportTotalsCalculator.Spec> reportTotalSpecs(
            List<ReportColumn> emitted, List<ReportColumn> projected) {
        java.util.Set<String> present = new java.util.HashSet<>();
        for (ReportColumn c : projected) present.add(c.key());
        List<com.uten.imp.common.report.ReportTotalsCalculator.Spec> specs = new ArrayList<>();
        for (ReportColumn c : emitted) {
            String label = c.totalLabel();
            if (label == null || label.isBlank()) continue;
            String g = c.totalGroupKey();
            if (g != null && !present.contains(g)) continue;
            String identity=c.totalGroupIdentityKey();
            if(identity!=null&&!present.contains(identity))identity=null;
            specs.add(new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                    c.key(), label, c.type(), g,identity));
        }
        return specs;
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
        ReportQueryKit.includeDecimalTexts(result);
        return result;
    }

    static boolean isCommercialColumn(ReportColumn column) {
        return "money".equals(column.type()) || isCommercialKey(column.key());
    }

    static boolean isCommercialKey(String key) {
        return "settlementStyle".equals(key)||"__currencyName".equals(key);
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
            case "int", "style" -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS int)", p, ReportQueryKit.parseRequiredInt(value));
            case "bool"  -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS boolean)", p, Boolean.valueOf(value));
            default      -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS text)", p, value);
        };
    }

    // ======================== 主过滤构造（公共） ========================
    // addApprovedByDefault / addCommonDocFilters / addSummaryKw 2026-09-16 收敛到
    // com.uten.imp.common.report.ReportQueryKit（与 purchase 两份逐字一致），调用点见各报表方法。

    /** Current order delivery facts, including imported archive orders; no inventory mutation. */
    @Transactional(readOnly = true)
    public ReportTableResponse orderDetail(String billNo, UUID supplierId, Short status,
            LocalDate dateFrom, LocalDate dateTo, String kw, Map<String,String> facets,
            int page, int size, String sort, String order) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140), ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("supplierName", "加工单位", 160), ReportColumn.date("deliverDate", "交货日期"),
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80), ReportColumn.text("spec", "规格", 140),
                ReportColumn.number("qty", "订货数量").withUnitKey("__unitName"),
                ReportColumn.number("receivedQty", "收货数量").withUnitKey("__unitName"),
                ReportColumn.number("returnedQty", "退货数量").withUnitKey("__unitName"),
                ReportColumn.number("differenceQty", "差异数").withUnitKey("__unitName"),
                ReportColumn.bool("closed", "是否结束"), ReportColumn.text("remark", "摘要", 200),
                ReportColumn.text("__srcId", ""));
        String select = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName",
                       COALESCE(i.deliver_date,o.deliver_date) AS "deliverDate",
                       i.goods_name_snapshot AS "goodsName", i.goods_code_snapshot AS "goodsCode",
                       col.name AS "colorName", g.spec AS "spec", i.qty AS "qty",
                       i.received_qty AS "receivedQty", i.returned_qty AS "returnedQty",
                       %s AS "differenceQty", o.is_closed AS "closed", i.remark AS "remark", o.id AS "__srcId"
                """.formatted(com.uten.imp.common.finance.ProcurementDeliveryDifference.sql("i.qty", "i.received_qty", "i.returned_qty"));
        String from = """
                FROM subcontract_order_items i JOIN subcontract_orders o ON o.id=i.order_id
                LEFT JOIN suppliers sup ON sup.id=o.supplier_id
                LEFT JOIN goods g ON g.id=i.goods_id LEFT JOIN colors col ON col.id=i.color_id
                """;
        WhereBuilder w = new WhereBuilder("WHERE NOT COALESCE(i.is_deleted,false) AND NOT COALESCE(o.is_deleted,false)");
        ReportQueryKit.addCommonDocFilters(w,billNo,supplierId,null,status,dateFrom,dateTo,kw,"o.bill_no","i.bill_date");
        return execute(cols,select,from,w,"o.bill_date DESC,o.bill_no,i.line_no",List.of(facetBillNo(),facetSupplier()),facets,page,size,sort,order);
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
                ReportColumn.money("totalAmount", "总额").withUnitLabel("元"), ReportColumn.bool("approved", "是否审核"),
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.number("weight", "重量").withUnitLabel("千克").totaled("合计重量"),
                ReportColumn.number("girth", "围数").withUnitLabel("围"),
                ReportColumn.number("qty", "数量").withUnitKey("__unitName").totaled("合计数量", "unitName","__unitId"),
                ReportColumn.text("unitName", "单位", 70),
                ReportColumn.text("step", "工序", 80),
                ReportColumn.money("price", "单价").withUnitKey("__currencyName"),
                ReportColumn.money("amount", "金额").withUnitLabel("元").totaled("合计金额"),
                ReportColumn.number("returnedQty", "退货数量").withUnitKey("__unitName").totaled("合计退货数量", "unitName","__unitId"),
                ReportColumn.money("returnedAmount", "退货金额").withUnitLabel("元").totaled("合计退货金额"),
                ReportColumn.text("returnNo", "委外退货单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外进仓单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_rec.full_name, o.receiver_name) AS "receiverName",
                       o.total_local AS "totalAmount", (o.status = 1) AS "approved",
                       i.goods_name_snapshot AS "goodsName", i.goods_code_snapshot AS "goodsCode", col.name AS "colorName",
                       g.model AS "model", g.c_number AS "customerModel", g.spec AS "spec", i.weight AS "weight", i.girth_qty AS "girth",
                       i.qty AS "qty", un.name AS "unitName", NULL AS "step",
                       i.price AS "price", i.amount_local AS "amount",
                       i.returned_qty AS "returnedQty",
                       COALESCE(i.return_amount, returned.amount_local) AS "returnedAmount",
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
                LEFT JOIN LATERAL (
                    -- 退货金额取已审委外退货单的实际贷项(服务端派生); 老库迁入行保留原「退货金额」。
                    SELECT SUM(return_item.amount_local) AS amount_local
                    FROM subcontract_return_items return_item
                    JOIN subcontract_returns return_doc ON return_doc.id = return_item.return_id
                    WHERE return_item.receipt_item_id = i.id AND return_doc.status = 1
                      AND COALESCE(return_item.is_deleted,false)=false
                      AND COALESCE(return_doc.is_deleted,false)=false
                ) returned ON TRUE
                """;
        WhereBuilder w = new WhereBuilder("WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false");
        ReportQueryKit.addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetBillNo(),
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
        ReportQueryKit.addApprovedByDefault(w, status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        ReportQueryKit.addSummaryKw(w, kw, "o.bill_no");
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
                ReportColumn.bool("approved", "是否审核"), ReportColumn.money("totalAmount", "总额").withUnitLabel("元"),
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.number("weight", "重量").withUnitLabel("千克").totaled("合计重量"),
                ReportColumn.number("girth", "围数").withUnitLabel("围"),
                ReportColumn.number("qty", "数量").withUnitKey("__unitName").totaled("合计数量", "unitName","__unitId"),
                ReportColumn.text("unitName", "单位", 70),
                ReportColumn.text("step", "工序", 80),
                ReportColumn.money("price", "单价").withUnitKey("__currencyName"),
                ReportColumn.money("amount", "金额").withUnitLabel("元").totaled("合计金额"),
                ReportColumn.text("receiptNo", "委外进仓单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外退货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       o.settlement_style_legacy AS "settlementStyle",
                       COALESCE(em_mk.full_name, o.maker_name) AS "makerName",
                       (o.status = 1) AS "approved", o.total_local AS "totalAmount",
                       i.goods_name_snapshot AS "goodsName", i.goods_code_snapshot AS "goodsCode", col.name AS "colorName",
                       g.model AS "model", g.c_number AS "customerModel", g.spec AS "spec", i.weight AS "weight", i.girth_qty AS "girth",
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
        ReportQueryKit.addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetBillNo(),
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
        ReportQueryKit.addApprovedByDefault(w, status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        ReportQueryKit.addSummaryKw(w, kw, "o.bill_no");
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
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("unitName", "单位", 70),
                ReportColumn.number("weight", "重量").withUnitLabel("千克").totaled("合计重量"),
                ReportColumn.number("boxQty", "胶箱数量").withUnitLabel("箱").totaled("合计胶箱数量"),
                ReportColumn.number("qty", "数量").withUnitKey("__unitName").totaled("合计数量", "unitName","__unitId"),
                ReportColumn.number("returnedQty", "退货数量").withUnitKey("__unitName").totaled("合计退货数量", "unitName","__unitId"),
                ReportColumn.text("returnNo", "材料退货单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外发料单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       i.goods_name_snapshot AS "goodsName", i.goods_code_snapshot AS "goodsCode", col.name AS "colorName",
                       g.model AS "model", g.c_number AS "customerModel", g.spec AS "spec", un.name AS "unitName", i.weight AS "weight",
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
        ReportQueryKit.addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetBillNo(),
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
        ReportQueryKit.addApprovedByDefault(w, status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        ReportQueryKit.addSummaryKw(w, kw, "o.bill_no");
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
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布。
                ReportColumn.text("goodsName", "货品名称", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("model", "型号", 100),
                ReportColumn.text("customerModel", "客户型号", 100),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("unitName", "单位", 70),
                ReportColumn.number("weight", "重量").withUnitLabel("千克").totaled("合计重量"),
                ReportColumn.number("girth", "围数").withUnitLabel("围"),
                ReportColumn.number("qty", "数量").withUnitKey("__unitName").totaled("合计数量", "unitName","__unitId"),
                ReportColumn.text("issueNo", "材料出仓单号", 140), ReportColumn.text("orderNo", "委外订货单号", 140),
                ReportColumn.text("__srcId", ""));  // 隐藏：行点击跳委外材料退货单编辑页
        String dataSelect = """
                SELECT o.bill_no AS "billNo", o.bill_date AS "billDate", sup.name AS "supplierName", wh.name AS "warehouseName",
                       COALESCE(em_op.full_name, o.operator_name) AS "operatorName", (o.status = 1) AS "approved",
                       i.goods_name_snapshot AS "goodsName", i.goods_code_snapshot AS "goodsCode", col.name AS "colorName",
                       g.model AS "model", g.c_number AS "customerModel", g.spec AS "spec", un.name AS "unitName", i.weight AS "weight",
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
        ReportQueryKit.addCommonDocFilters(w, billNo, supplierId, warehouseId, status, dateFrom, dateTo, kw, "o.bill_no", "i.bill_date");
        List<FacetSpec> specs = List.of(
                facetBillNo(),
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
        ReportQueryKit.addApprovedByDefault(w, status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        ReportQueryKit.addSummaryKw(w, kw, "o.bill_no");
        List<FacetSpec> specs = List.of(facetSupplier(), facetWarehouse());
        return execute(cols, dataSelect, fromJoin, w, "o.bill_date DESC, o.bill_no", specs, facets, page, size, sort, order);
    }

    // ======================== ⑨ 委外出入状况表（综合 · 按 委外商×货品×颜色 聚合） ========================

    /**
     * 列：加工单位/品名/编号/颜色/规格/型号/系列/期初结存/订货数量/发胚(15)/退成品(18)/
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
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布，
                // 「品名及规格」拆成 名称 + 规格 两列。
                ReportColumn.text("goodsName", "品名", 180), ReportColumn.text("goodsCode", "编号", 110),
                ReportColumn.text("colorName", "颜色", 80),
                ReportColumn.text("spec", "规格", 140),
                ReportColumn.text("model", "型号", 100), ReportColumn.text("series", "系列", 90),
                ReportColumn.number("openingQty", "期初结存").withUnitKey("__unitName"), ReportColumn.number("orderQty", "订货数量").withUnitKey("__unitName"),
                ReportColumn.number("issueQty", "发胚数量").withUnitKey("__unitName"), ReportColumn.number("returnQty", "退成品").withUnitKey("__unitName"),
                ReportColumn.number("mReturnQty", "退原胚").withUnitKey("__unitName"), ReportColumn.number("wasteQty", "退不良品").withUnitKey("__unitName"),
                ReportColumn.number("receiptQty", "收货数量").withUnitKey("__unitName"),
                ReportColumn.money("price", "单价").withUnitKey("__currencyName"), ReportColumn.money("amount", "金额").withUnitLabel("元"),
                ReportColumn.number("closingQty", "期末结存").withUnitKey("__unitName"),
                ReportColumn.text("__currencyName",""),ReportColumn.text("__unitName",""));
        List<ReportColumn> safeCols = responseColumns(cols, priceMasked);

        // flow：5 类源明细 UNION，带 signed_qty（方向）+ movement_type + 日期 + 单价/金额
        WhereBuilder search = new WhereBuilder("WHERE TRUE");
        search.search(kw, "a.goods_code_snapshot", "a.goods_name_snapshot", "sup.name", "gg.model", "gg.spec", "gg.series", "col.name");
        WhereBuilder.Built searchFilter = search.build(null);
        String sql = """
                WITH flow AS (
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date AS d, ROUND(i.qty*COALESCE(i.unit_rate,1),4) AS signed_qty,
                           17 AS mt, i.price/NULLIF(COALESCE(i.unit_rate,1),0) AS price,i.amount_local AS amt,
                           o.currency_id
                    FROM subcontract_receipt_items i JOIN subcontract_receipts o ON o.id = i.receipt_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -ROUND(i.qty*COALESCE(i.unit_rate,1),4),18,
                           i.price/NULLIF(COALESCE(i.unit_rate,1),0),i.amount_local,o.currency_id
                    FROM subcontract_return_items i JOIN subcontract_returns o ON o.id = i.return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -ROUND(i.qty*COALESCE(i.unit_rate,1),4),15,NULL,i.amount_local,NULL::uuid
                    FROM subcontract_material_issue_items i JOIN subcontract_material_issues o ON o.id = i.issue_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, ROUND(i.qty*COALESCE(i.unit_rate,1),4),16,NULL,i.amount_local,NULL::uuid
                    FROM subcontract_material_return_items i JOIN subcontract_material_returns o ON o.id = i.material_return_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1 AND COALESCE(i.is_deleted,false)=false
                    UNION ALL
                    SELECT o.supplier_id, i.goods_id, i.goods_code_snapshot, i.goods_name_snapshot,
                           i.color_id, i.bill_date, -ROUND(i.qty*COALESCE(i.unit_rate,1),4),19,NULL,i.amount_local,NULL::uuid
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
                           CASE WHEN COUNT(DISTINCT currency_id) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))=1 AND COUNT(currency_id) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))=COUNT(*) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))
                               THEN AVG(CASE WHEN mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN price END) END AS price,
                           CASE WHEN COUNT(DISTINCT currency_id) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))=1 AND COUNT(currency_id) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))=COUNT(*) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))
                               THEN MIN(currency_id::text) FILTER(WHERE mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date))::uuid END AS currency_id,
                           COALESCE(SUM(CASE WHEN mt=17 AND d >= CAST(:from AS date) AND d <= CAST(:to AS date) THEN amt ELSE 0 END),0) AS amount
                    FROM flow
                    WHERE (CAST(:supplierId AS uuid) IS NULL OR supplier_id = :supplierId)
                    GROUP BY supplier_id, goods_id, goods_code_snapshot, goods_name_snapshot, color_id
                ),
                ord AS (
                    SELECT o.supplier_id, oi.goods_id, oi.goods_code_snapshot, oi.goods_name_snapshot,
                           oi.color_id, SUM(ROUND(oi.qty*COALESCE(oi.unit_rate,1),4)) AS order_qty
                    FROM subcontract_order_items oi JOIN subcontract_orders o ON o.id = oi.order_id
                    WHERE COALESCE(o.is_deleted,false)=false AND o.status=1
                      AND oi.bill_date >= CAST(:from AS date) AND oi.bill_date <= CAST(:to AS date)
                    GROUP BY o.supplier_id, oi.goods_id, oi.goods_code_snapshot,
                             oi.goods_name_snapshot, oi.color_id
                )
                SELECT sup.name AS supplierName,
                       a.goods_name_snapshot AS goodsName, a.goods_code_snapshot AS goodsCode, col.name AS colorName,
                       gg.spec AS spec, gg.model AS model, gg.series AS series,
                       a.opening AS openingQty, COALESCE(od.order_qty, 0) AS orderQty,
                       a.issue_qty AS issueQty, a.return_qty AS returnQty, a.m_return_qty AS mReturnQty,
                       a.waste_qty AS wasteQty, a.receipt_qty AS receiptQty,
                       a.price AS price, a.amount AS amount,
                       a.opening + a.net_qty AS closingQty,
                """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("report_currency")+"""
                       AS "__currencyName",report_unit.name AS "__unitName"
                FROM agg a
                LEFT JOIN suppliers sup ON sup.id = a.supplier_id
                LEFT JOIN goods gg ON gg.id = a.goods_id
                LEFT JOIN colors col ON col.id = a.color_id
                LEFT JOIN currencies report_currency ON report_currency.id=a.currency_id
                LEFT JOIN units report_unit ON report_unit.id=gg.unit_id
                LEFT JOIN ord od ON od.supplier_id = a.supplier_id AND od.goods_id = a.goods_id
                     AND od.goods_code_snapshot IS NOT DISTINCT FROM a.goods_code_snapshot
                     AND od.goods_name_snapshot IS NOT DISTINCT FROM a.goods_name_snapshot
                     AND COALESCE(od.color_id,'00000000-0000-0000-0000-000000000000'::uuid) = COALESCE(a.color_id,'00000000-0000-0000-0000-000000000000'::uuid)
                """ + searchFilter.sql() + "\n ORDER BY "
                + search.orderBy("sup.name NULLS LAST, a.goods_name_snapshot, a.goods_code_snapshot, a.supplier_id, a.goods_id, a.color_id NULLS FIRST") + "\n" + """
                LIMIT :__limit OFFSET :__offset
                """;
        var q = em.createNativeQuery(sql);
        q.setParameter("supplierId", supplierId);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        searchFilter.params().forEach(q::setParameter);
        search.searchOrderParameters().forEach(q::setParameter);
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
                LEFT JOIN suppliers sup ON sup.id = a.supplier_id
                LEFT JOIN colors col ON col.id = a.color_id
                """ + searchFilter.sql();
        var cq = em.createNativeQuery(countSql);
        cq.setParameter("supplierId", supplierId);
        searchFilter.params().forEach(cq::setParameter);
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

    /** 2026-09-25 单号列统一：四张委外明细报表的单号列均投影 o.bill_no，按值筛选（等值匹配，桶 LIMIT 50 见 execute）。 */
    private static FacetSpec facetBillNo() {
        return new FacetSpec("billNo", "o.bill_no AS v, o.bill_no AS lbl", "o.bill_no", "o.bill_no", "text");
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
        UUID supplierId = ReportQueryKit.parseUuid(p == null ? null : p.get("supplierId"));
        UUID warehouseId = ReportQueryKit.parseUuid(p == null ? null : p.get("warehouseId"));
        Short status = ReportQueryKit.parseShort(p == null ? null : p.get("status"));
        LocalDate dateFrom = ReportQueryKit.parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = ReportQueryKit.parseDate(p == null ? null : p.get("dateTo"));
        String kw = p == null ? null : p.get("keyword");
        Map<String, String> facets = ReportQueryKit.facetsOf(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (report) {
            case "ORDER/detail"           -> (pg, sz) -> orderDetail(billNo, supplierId, status, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
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
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "报表类型不正确：" + report);
        };
        return ReportQueryKit.paginateAll(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS), loader,
                ReportTableResponse::total,
                r -> r.columns() == null ? null : r.columns().stream()
                        .map(c -> new ExportColumn(c.key(),c.label(),c.type(),null,c.unitLabel(),c.unitKey())).toList(),
                ReportTableResponse::rows);
    }

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
}
