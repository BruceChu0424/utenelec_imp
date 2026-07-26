package com.uten.imp.features.stock.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
import java.util.stream.Collectors;

/**
 * 仓库报表查询（仓库管理 / 仓库报表）。
 *
 * <p>14 张报表（7 单据类型 × 明细/汇总），与采购 {@code PurchaseReportService} / 销售 {@code SalesReportService}
 * 同型（原生 SQL + EntityManager + ReportTableResponse）。**仓库是统一表**（stock_documents +
 * stock_document_items，doc_type 判别），故所有明细报表共享 FROM/JOIN，仅 docType 过滤 + 列集不同 ——
 * 比销售（多表）更 DRY。
 *
 * <p>明细表：一行=单里一样货品（同单号重复），{@code FROM stock_document_items i JOIN stock_documents o}；
 * 汇总表：一行=一整张单（单号唯一），{@code FROM stock_documents o}。
 *
 * <p>人员名：worker/maker/approver 走 {@code LEFT JOIN employees ON legacy_id = *_legacy_id OR id = *_id}，
 * 名字后附「（子类）」标记（legacy_category 非空时）；employees 由迁移自动补录 B_Worker stub，未补录前暂显空。
 * worker 列标签随 doc_type 不同：TRANSFER/OTHER_IN=经办人、DRAW=领料人、WDRAW=退料人、产成品进/出仓及盘点=跟单员。
 *
 * <p>_null 参数类型坑_：可选过滤用 {@code CAST(:param AS 类型) IS NULL OR ...}（见 MEMORY），本类主过滤走
 * WhereBuilder 条件式追加（Java 端判 null，类型天然正确），facet 子句用 CAST。
 */
@Service
@RequiredArgsConstructor
public class StockReportService {

    public static final String DOC_TRANSFER = "TRANSFER";
    public static final String DOC_OTHER_IN = "OTHER_IN";
    public static final String DOC_DRAW = "DRAW";
    public static final String DOC_WDRAW = "WDRAW";
    public static final String DOC_FINISHED_IN = "FINISHED_IN";
    public static final String DOC_FINISHED_OUT = "FINISHED_OUT";
    public static final String DOC_CHECK = "CHECK";

    private static final java.util.Set<String> DOC_TYPES = java.util.Set.of(
            DOC_TRANSFER, DOC_OTHER_IN, DOC_DRAW, DOC_WDRAW, DOC_FINISHED_IN, DOC_FINISHED_OUT, DOC_CHECK);

    /** 人员名 + 「（子类）」标记（legacy_category 非空时；无匹配员工则 NULL）。 */
    private static final String WK = "em_wk.full_name || COALESCE('（' || em_wk.legacy_category || '）','')";
    private static final String MK = "em_mk.full_name || COALESCE('（' || em_mk.legacy_category || '）','')";
    private static final String AP = "em_ap.full_name || COALESCE('（' || em_ap.legacy_category || '）','')";

    private final EntityManager em;

    // ======================== 明细 / 汇总 派发 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse detail(String docType, String billNo, UUID warehouseId, UUID clientId, Short status,
                                      LocalDate dateFrom, LocalDate dateTo, String kw,
                                      Map<String, String> facets, int page, int size) {
        String dt = normalizeDocType(docType);
        List<Col> cols = detailCols(dt);
        String dataSelect = "SELECT " + selectClause(cols);
        String fromJoin = DETAIL_FROM;
        WhereBuilder w = new WhereBuilder(
                "WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false AND i.bill_type = '" + dt + "'");
        addCommonFilters(w, billNo, warehouseId, clientId, status, dateFrom, dateTo, kw, true);
        return execute(cols.stream().map(c -> c.col).toList(), dataSelect, fromJoin, w,
                "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", commonFacets(), facets, page, size);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse summary(String docType, String billNo, UUID warehouseId, UUID clientId, Short status,
                                       LocalDate dateFrom, LocalDate dateTo, String kw,
                                       Map<String, String> facets, int page, int size) {
        String dt = normalizeDocType(docType);
        List<Col> cols = summaryCols(dt);
        String dataSelect = "SELECT " + selectClause(cols);
        String fromJoin = SUMMARY_FROM;
        WhereBuilder w = new WhereBuilder(
                "WHERE COALESCE(o.is_deleted,false)=false AND o.doc_type = '" + dt + "'");
        addCommonFilters(w, billNo, warehouseId, clientId, status, dateFrom, dateTo, kw, false);
        return execute(cols.stream().map(c -> c.col).toList(), dataSelect, fromJoin, w,
                "o.bill_date DESC, o.bill_no", commonFacets(), facets, page, size);
    }

    // ======================== 明细列集（按 docType） ========================

    private static List<Col> detailCols(String dt) {
        return switch (dt) {
            case DOC_TRANSFER -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("fromWh", "调出仓库", "text", 120, "wh.name"),
                    c("toWh", "调入仓库", "text", 120, "wh2.name"),
                    c("workerName", "经办人", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("qty", "数量", "number", null, "i.qty"));
            case DOC_OTHER_IN -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "经办人", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"));
            case DOC_DRAW -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("assTeam", "装配班组", "text", 100, "o.ass_team"),
                    c("orderNo", "订单号", "text", 140, "o.source_doc_no"),
                    c("workerName", "领料人", "text", 100, WK),
                    c("makerName", "制单员", "text", 100, MK),
                    c("approverName", "审核员", "text", 100, AP),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("drawQty", "领料数量", "number", null, "i.qty"),
                    c("actualQty", "实发数量", "number", null, "i.base_qty"));
            case DOC_WDRAW -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "退料人", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("returnQty", "清退数量", "number", null, "i.qty"));
            case DOC_FINISHED_IN -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("material", "材质", "text", 90, "g.material"),
                    c("netWeight", "净重", "number", null, "i.weight"));
            case DOC_FINISHED_OUT -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("qty", "数量", "number", null, "i.qty"));
            case DOC_CHECK -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("goodsCode", "编号", "text", 110, "g.code"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "g.name"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("bookQty", "帐面数量", "number", null, "COALESCE(i.count_qty,0) - COALESCE(i.surplus_qty,0)"),
                    c("bookWeight", "帐面重量", "number", null, "NULL"),
                    c("actualQty", "实际数量", "number", null, "i.count_qty"),
                    c("actualWeight", "实际重量", "number", null, "i.weight"));
            default -> throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + dt);
        };
    }

    // ======================== 汇总列集（按 docType；一行一单号） ========================

    private static List<Col> summaryCols(String dt) {
        return switch (dt) {
            case DOC_TRANSFER -> List.of(
                    c("billNo", "单号", "text", 150, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("fromWh", "调出仓库", "text", 120, "wh.name"),
                    c("toWh", "调入仓库", "text", 120, "wh2.name"),
                    c("workerName", "经办人", "text", 100, WK),
                    c("makerName", "制单员", "text", 100, MK),
                    c("approverName", "审核员", "text", 100, AP));
            case DOC_OTHER_IN -> List.of(
                    c("billNo", "单号", "text", 150, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "经办人", "text", 100, WK),
                    c("approverName", "审核员", "text", 100, AP),
                    c("makerName", "制单员", "text", 100, MK),
                    c("remark", "备注", "text", 160, "o.remark"));
            case DOC_DRAW -> List.of(
                    c("billNo", "单号", "text", 150, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("assTeam", "装配班组", "text", 100, "o.ass_team"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("orderNo", "订单号", "text", 140, "o.source_doc_no"),
                    c("workerName", "领料人", "text", 100, WK));
            case DOC_WDRAW, DOC_FINISHED_IN, DOC_FINISHED_OUT, DOC_CHECK -> List.of(
                    c("billNo", "单号", "text", 150, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", DOC_WDRAW.equals(dt) ? "退料人" : "跟单员", "text", 100, WK),
                    c("makerName", "制单员", "text", 100, MK),
                    c("approverName", "审核员", "text", 100, AP),
                    c("remark", "备注", "text", 160, "o.remark"));
            default -> throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + dt);
        };
    }

    // ======================== 通用 FROM/JOIN（统一表共享） ========================

    private static final String DETAIL_FROM = """
            FROM stock_document_items i
            JOIN stock_documents o ON o.id = i.doc_id
            LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
            LEFT JOIN warehouses wh2 ON wh2.id = o.to_warehouse_id
            LEFT JOIN clients cl ON cl.id = o.client_id
            LEFT JOIN employees em_wk ON em_wk.legacy_id = o.worker_legacy_id OR em_wk.id = o.worker_id
            LEFT JOIN employees em_mk ON em_mk.legacy_id = o.maker_legacy_id OR em_mk.id = o.maker_id
            LEFT JOIN employees em_ap ON em_ap.legacy_id = o.approver_legacy_id OR em_ap.id = o.approver_id
            LEFT JOIN goods g ON g.id = i.goods_id
            LEFT JOIN colors col ON col.id = i.color_id
            LEFT JOIN units un ON un.id = i.unit_id
            """;

    private static final String SUMMARY_FROM = """
            FROM stock_documents o
            LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
            LEFT JOIN warehouses wh2 ON wh2.id = o.to_warehouse_id
            LEFT JOIN clients cl ON cl.id = o.client_id
            LEFT JOIN employees em_wk ON em_wk.legacy_id = o.worker_legacy_id OR em_wk.id = o.worker_id
            LEFT JOIN employees em_mk ON em_mk.legacy_id = o.maker_legacy_id OR em_mk.id = o.maker_id
            LEFT JOIN employees em_ap ON em_ap.legacy_id = o.approver_legacy_id OR em_ap.id = o.approver_id
            """;

    // ======================== 主过滤（公共） ========================

    private static void addCommonFilters(WhereBuilder w, String billNo, UUID warehouseId, UUID clientId, Short status,
                                         LocalDate dateFrom, LocalDate dateTo, String kw, boolean hasItems) {
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (clientId != null) w.add("o.client_id = :clientId", "clientId", clientId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank()) {
            String k = "%" + kw.toLowerCase() + "%";
            if (hasItems) {
                w.add("(LOWER(o.bill_no) LIKE LOWER(:kw) OR EXISTS (SELECT 1 FROM goods gg WHERE gg.id = i.goods_id AND "
                        + "(LOWER(gg.name) LIKE LOWER(:kw) OR LOWER(COALESCE(gg.code,'')) LIKE LOWER(:kw) "
                        + "OR LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw))))", "kw", k);
            } else {
                w.add("LOWER(o.bill_no) LIKE LOWER(:kw)", "kw", k);
            }
        }
    }

    private static List<FacetSpec> commonFacets() {
        return List.of(
                new FacetSpec("warehouseName", "CAST(wh.id AS text) AS v, wh.name AS lbl", "wh.id, wh.name", "o.warehouse_id", "uuid"),
                new FacetSpec("approved", "(o.status = 1) AS v, CASE WHEN (o.status = 1) THEN '已审' ELSE '未审' END AS lbl",
                        "(o.status = 1)", "o.status = 1", "bool"));
    }

    // ======================== 通用执行器（与 purchase/sales 同型） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse execute(List<ReportColumn> columns, String dataSelect, String fromJoin,
                                       WhereBuilder mainWhere, String orderBy, List<FacetSpec> specs,
                                       Map<String, String> activeFacets, int page, int size) {
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

        var dataQ = em.createNativeQuery(dataSelect + " " + fromJoin + " " + full.sql()
                + " ORDER BY " + orderBy + " LIMIT :__limit OFFSET :__offset");
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
                long cnt = ((Number) fr[2]).longValue();
                buckets.add(new ReportFacet(val, lbl, cnt));
            }
            facets.put(spec.key(), buckets);
        }

        return new ReportTableResponse(columns, items, facets, safePage, safeSize, total, totalPages);
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
            case "uuid" -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS uuid)", p, UUID.fromString(value));
            case "bool" -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS boolean)", p, Boolean.valueOf(value));
            default -> new WhereBuilder.Clause("(" + spec.filterExpr() + ") = CAST(:" + p + " AS text)", p, value);
        };
    }

    private static String normalizeDocType(String docType) {
        if (docType == null) throw new ApiException(ErrorCode.BUSINESS, "docType 必填");
        String dt = docType.trim().toUpperCase();
        if (!DOC_TYPES.contains(dt)) throw new ApiException(ErrorCode.BUSINESS, "未知 docType：" + docType);
        return dt;
    }

    private static String selectClause(List<Col> cols) {
        return cols.stream().map(x -> x.expr + " AS \"" + x.col.key() + "\"").collect(Collectors.joining(", "));
    }

    /** 列 + 其 SQL 表达式（保证列表与 SELECT 投影顺序对齐）。 */
    private record Col(ReportColumn col, String expr) {}

    private static Col c(String key, String label, String type, Integer width, String expr) {
        return new Col(new ReportColumn(key, label, type, width), expr);
    }

    /** 列 facet 规格。selectExpr 投影 v+lbl；groupExpr 分组；filterExpr 过滤表达式；filterType 值类型。 */
    record FacetSpec(String key, String selectExpr, String groupExpr, String filterExpr, String filterType) {}

    /** WHERE 构造器：base + 若干 AND 子句（带参数）。与 purchase/sales 同型。 */
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
