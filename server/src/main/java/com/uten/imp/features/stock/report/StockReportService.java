package com.uten.imp.features.stock.report;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockCostMasker;
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
 * <p>人员名：worker 按 current UUID 优先、UUID 为空才回退 B_Worker legacy_id；
 * maker/approver 只按 current UUID 关联 employees，历史 UUID 为空时回退 Sys_Operator 姓名快照，
 * 绝不把 Sys_Operator.ID 当作 employees.legacy_id。员工名可附「（子类）」标记。
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

    /** B_Worker 当前/legacy 员工名 + 「（子类）」标记。 */
    private static final String WK = "em_wk.full_name || COALESCE('(' || em_wk.legacy_category || ')','')";
    /** 新系统当前员工名优先；历史单据回退 Sys_Operator 姓名快照。 */
    private static final String MK = "COALESCE(em_mk.full_name || COALESCE('(' || em_mk.legacy_category || ')',''), o.maker_name_snapshot)";
    private static final String AP = "COALESCE(em_ap.full_name || COALESCE('(' || em_ap.legacy_category || ')',''), o.approver_name_snapshot)";

    private final EntityManager em;
    private final SystemSettingsService settings;
    private final com.uten.imp.features.stock.StockQueryService stockQueryService;
    private final StockCostMasker costMasker;

    // ======================== 明细 / 汇总 派发 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse detail(String docType, String billNo, UUID warehouseId, UUID clientId, Short status,
                                      UUID departmentId, LocalDate dateFrom, LocalDate dateTo, String kw,
                                      Map<String, String> facets, int page, int size, String sort, String order) {
        String dt = normalizeDocType(docType);
        // 末尾追加隐藏 __srcId（= 单据头 stock_documents.id）：行点击跳该单据编辑页。
        List<Col> cols = new ArrayList<>(detailCols(dt));
        cols.add(c("__srcId", "", "text", null, "o.id"));
        String dataSelect = "SELECT " + selectClause(cols);
        String fromJoin = DETAIL_FROM;
        WhereBuilder w = new WhereBuilder(
                "WHERE COALESCE(i.is_deleted,false)=false AND COALESCE(o.is_deleted,false)=false AND i.bill_type = '" + dt + "'");
        addCommonFilters(w, billNo, warehouseId, clientId, status, departmentId, dateFrom, dateTo, kw, true);
        return execute(cols.stream().map(c -> c.col).toList(), dataSelect, fromJoin, w,
                "o.bill_date DESC, o.bill_no, i.line_no NULLS LAST", commonFacets(), facets, page, size, sort, order);
    }

    @Transactional(readOnly = true)
    public ReportTableResponse summary(String docType, String billNo, UUID warehouseId, UUID clientId, Short status,
                                       UUID departmentId, LocalDate dateFrom, LocalDate dateTo, String kw,
                                       Map<String, String> facets, int page, int size, String sort, String order) {
        String dt = normalizeDocType(docType);
        // 末尾追加隐藏 __srcId（= 单据头 stock_documents.id）：汇总一行一单，行点击跳该单据编辑页。
        List<Col> cols = new ArrayList<>(summaryCols(dt));
        cols.add(c("__srcId", "", "text", null, "o.id"));
        String dataSelect = "SELECT " + selectClause(cols);
        String fromJoin = SUMMARY_FROM;
        WhereBuilder w = new WhereBuilder(
                "WHERE COALESCE(o.is_deleted,false)=false AND o.doc_type = '" + dt + "'");
        addCommonFilters(w, billNo, warehouseId, clientId, status, departmentId, dateFrom, dateTo, kw, false);
        return execute(cols.stream().map(c -> c.col).toList(), dataSelect, fromJoin, w,
                "o.bill_date DESC, o.bill_no", commonFacets(), facets, page, size, sort, order);
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
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
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
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("qty", "数量", "number", null, "i.qty"));
            case DOC_DRAW -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("departmentName", "领料车间", "text", 110, "dp.name"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("assTeam", "装配班组", "text", 100, "o.ass_team"),
                    c("orderNo", "订单号", "text", 140, "o.source_doc_no"),
                    c("workerName", "领料人", "text", 100, WK),
                    c("makerName", "制单员", "text", 100, MK),
                    c("approverName", "审核员", "text", 100, AP),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("drawQty", "领料数量", "number", null, "i.qty"),
                    c("issuedQty", "已出库", "number", null, "i.issued_qty"),
                    c("actualQty", "实发数量", "number", null, "i.base_qty"));
            case DOC_WDRAW -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "退料人", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("returnQty", "清退数量", "number", null, "i.qty"));
            case DOC_FINISHED_IN -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("material", "材质", "text", 90, "g.material"),
                    c("netWeight", "净重", "number", null, "i.weight"),
                    c("qty", "数量", "number", null, "i.qty"));
            case DOC_FINISHED_OUT -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("series", "系列", "text", 90, "g.series"),
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
                    c("weight", "重量", "number", null, "i.weight"),
                    c("qty", "数量", "number", null, "i.qty"));
            case DOC_CHECK -> List.of(
                    c("billNo", "单号", "text", 140, "o.bill_no"),
                    c("billDate", "开单日期", "date", null, "o.bill_date"),
                    c("warehouseName", "仓库", "text", 120, "wh.name"),
                    c("workerName", "跟单员", "text", 100, WK),
                    c("approved", "是否审核", "bool", null, "(o.status = 1)"),
                    c("goodsCode", "编号", "text", 110, "i.goods_code_snapshot"),
                    c("stockPlace", "库位号", "text", 90, "g.stock_place"),
                    c("model", "型号", "text", 100, "g.model"),
                    c("clientModel", "客户型号", "text", 110, "g.c_number"),
                    c("goodsName", "货品名称", "text", 180, "i.goods_name_snapshot"),
                    c("spec", "规格", "text", 140, "g.spec"),
                    c("colorName", "颜色", "text", 80, "col.name"),
                    c("unitName", "单位", "text", 70, "un.name"),
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
                    c("departmentName", "领料车间", "text", 110, "dp.name"),
                    c("assTeam", "装配班组", "text", 100, "o.ass_team"),
                    c("clientName", "客户名称", "text", 150, "cl.name"),
                    c("orderNo", "订单号", "text", 140, "o.source_doc_no"),
                    c("issueStatus", "出库进度", "text", 90,
                            "CASE COALESCE(o.issue_status,0) WHEN 2 THEN '已出完' WHEN 1 THEN '部分出库' ELSE '未出库' END"),
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
            LEFT JOIN departments dp ON dp.id = o.department_id
            LEFT JOIN employees em_wk ON em_wk.id = o.worker_id
                OR (o.worker_id IS NULL AND em_wk.legacy_id = o.worker_legacy_id)
            LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
            LEFT JOIN employees em_ap ON em_ap.id = o.approver_id
            LEFT JOIN goods g ON g.id = i.goods_id
            LEFT JOIN colors col ON col.id = i.color_id
            LEFT JOIN units un ON un.id = i.unit_id
            """;

    private static final String SUMMARY_FROM = """
            FROM stock_documents o
            LEFT JOIN warehouses wh ON wh.id = o.warehouse_id
            LEFT JOIN warehouses wh2 ON wh2.id = o.to_warehouse_id
            LEFT JOIN clients cl ON cl.id = o.client_id
            LEFT JOIN departments dp ON dp.id = o.department_id
            LEFT JOIN employees em_wk ON em_wk.id = o.worker_id
                OR (o.worker_id IS NULL AND em_wk.legacy_id = o.worker_legacy_id)
            LEFT JOIN employees em_mk ON em_mk.id = o.maker_id
            LEFT JOIN employees em_ap ON em_ap.id = o.approver_id
            """;

    // ======================== 主过滤（公共） ========================

    private static void addCommonFilters(WhereBuilder w, String billNo, UUID warehouseId, UUID clientId, Short status,
                                         UUID departmentId,
                                         LocalDate dateFrom, LocalDate dateTo, String kw, boolean hasItems) {
        if (billNo != null && !billNo.isBlank()) w.add("o.bill_no LIKE :billNo", "billNo", "%" + billNo + "%");
        if (warehouseId != null) w.add("o.warehouse_id = :warehouseId", "warehouseId", warehouseId);
        if (clientId != null) w.add("o.client_id = :clientId", "clientId", clientId);
        if (status != null) w.add("o.status = :status", "status", status);
        if (departmentId != null) w.add("o.department_id = :departmentId", "departmentId", departmentId);
        if (dateFrom != null) w.add("o.bill_date >= :dateFrom", "dateFrom", dateFrom);
        if (dateTo != null) w.add("o.bill_date <= :dateTo", "dateTo", dateTo);
        if (kw != null && !kw.isBlank()) {
            String k = "%" + kw.toLowerCase() + "%";
            if (hasItems) {
                w.add("(LOWER(o.bill_no) LIKE LOWER(:kw) "
                        + "OR LOWER(COALESCE(i.goods_name_snapshot,'')) LIKE LOWER(:kw) "
                        + "OR LOWER(COALESCE(i.goods_code_snapshot,'')) LIKE LOWER(:kw) "
                        + "OR EXISTS (SELECT 1 FROM goods gg WHERE gg.id = i.goods_id "
                        + "AND LOWER(COALESCE(gg.model,'')) LIKE LOWER(:kw)))", "kw", k);
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

    // ======================== 导出（加密 Excel） ========================

    /**
     * 导出某报表全量（不分页，循环 size=500 累积全部行），返回 ExportColumn + 行 Map。
     * 列定义映射 ReportColumn→ExportColumn（剥离 width）。report 取值与 GET 路径一致：
     * {@code <docType>/<detail|summary>}，docType ∈ TRANSFER/OTHER_IN/DRAW/WDRAW/FINISHED_IN/FINISHED_OUT/CHECK。
     *
     * <p>白名单：kind 仅认 {@code detail}/{@code summary}（switch default 抛错）；docType 走
     * {@link #normalizeDocType}（命中 {@link #DOC_TYPES} 集合，防 SQL 注入）。过滤参数化（{@link WhereBuilder}）。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(String report, Map<String, String> p, String sort, String order) {
        if (report == null || report.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "report 必填");
        }
        // 即时库存（页面同款查询，report='instant-inventory'，走独立分支非 docType/kind）。
        if ("instant-inventory".equals(report.trim())) {
            return exportInstantInventory(p, sort, order);
        }
        // 货架目视化清单（report='shelf-labels'，现场挂牌打印/张贴口径，走独立分支）。
        if ("shelf-labels".equals(report.trim())) {
            return exportShelfLabels(p);
        }
        String[] parts = report.split("/");
        if (parts.length != 2) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报表格式应为 docType/detail|summary: " + report);
        }
        String docType = parts[0].trim();
        String kind = parts[1].trim().toLowerCase();
        String billNo = p == null ? null : p.get("billNo");
        UUID warehouseId = parseUuid(p == null ? null : p.get("warehouseId"));
        UUID clientId = parseUuid(p == null ? null : p.get("clientId"));
        Short status = parseShort(p == null ? null : p.get("status"));
        UUID departmentId = parseUuid(p == null ? null : p.get("departmentId"));
        LocalDate dateFrom = parseDate(p == null ? null : p.get("dateFrom"));
        LocalDate dateTo = parseDate(p == null ? null : p.get("dateTo"));
        String kw = p == null ? null : p.get("keyword");
        Map<String, String> facets = facetsOfMap(p);
        BiFunction<Integer, Integer, ReportTableResponse> loader = switch (kind) {
            case "detail"  -> (pg, sz) -> detail(docType, billNo, warehouseId, clientId, status,
                    departmentId, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            case "summary" -> (pg, sz) -> summary(docType, billNo, warehouseId, clientId, status,
                    departmentId, dateFrom, dateTo, kw, facets, pg, sz, sort, order);
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报表 kind: " + kind);
        };
        return paginateAll(loader);
    }

    /** 即时库存导出列（与页面完整业务列一致；成本列按 goods:cost:view 动态裁剪）。 */
    private static final List<ReportColumn> INSTANT_EXPORT_COLUMNS = List.of(
            ReportColumn.text("category", "所属类型", 120),
            ReportColumn.text("goodsCode", "物料编码", 120),
            ReportColumn.text("series", "物料系列", 90),
            ReportColumn.text("stockPlace", "库位号", 90),
            ReportColumn.text("model", "型号", 110),
            ReportColumn.text("cNumber", "客户型号", 120),
            ReportColumn.text("name", "货品名称", 220),
            ReportColumn.text("spec", "规格", 120),
            ReportColumn.text("color", "颜色", 90),
            ReportColumn.text("unit", "单位", 70),
            ReportColumn.text("remark", "备注", 90),
            ReportColumn.number("weight", "库存重量"),
            ReportColumn.number("qty", "库存数量"),
            ReportColumn.number("pendingQty", "待检量"),
            ReportColumn.money("costAmount", "库存台账金额"),
            ReportColumn.number("moreQty", "多排数量"));

    /**
     * 即时库存导出（report='instant-inventory'）：复用 {@code StockQueryService.instantInventory}
     * 同口径查询（分类子树/仓库/含不良仓/关键字/排序），分页循环全量 → ExportPayload。
     * 参数：categoryId/warehouseId/includeDefective(默认 true)/keyword + sort/order。
     */
    private ExportPayload exportInstantInventory(Map<String, String> p, String sort, String order) {
        UUID categoryId = parseUuid(p == null ? null : p.get("categoryId"));
        UUID warehouseId = parseUuid(p == null ? null : p.get("warehouseId"));
        boolean includeDefective = !"false".equalsIgnoreCase(p == null ? null : p.get("includeDefective"));
        String kw = p == null ? null : p.get("keyword");
        boolean canViewCost = costMasker.canView();
        List<ReportColumn> columns = canViewCost
                ? INSTANT_EXPORT_COLUMNS
                : INSTANT_EXPORT_COLUMNS.stream()
                        .filter(column -> !"costAmount".equals(column.key()))
                        .toList();
        BiFunction<Integer, Integer, ReportTableResponse> loader = (pg, sz) -> {
            var r = stockQueryService.instantInventory(categoryId, warehouseId, includeDefective,
                    kw, pg, sz, sort, order);
            List<Map<String, Object>> rows = new ArrayList<>(r.getItems().size());
            for (var it : r.getItems()) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("category", it.getCategoryName());
                m.put("goodsCode", it.getGoodsCode());
                m.put("series", it.getSeries());
                m.put("stockPlace", it.getStockPlace());
                m.put("model", it.getModel());
                m.put("cNumber", it.getCNumber());
                m.put("name", it.getName());
                m.put("spec", it.getSpec());
                m.put("color", it.getColorName());
                m.put("unit", it.getUnitName());
                m.put("remark", it.getRemark());
                m.put("weight", it.getWeight());
                m.put("qty", it.getQty());
                m.put("pendingQty", it.getPendingQty());
                if (canViewCost) {
                    m.put("costAmount", it.getCostAmount());
                }
                m.put("moreQty", it.getMoreQty());
                rows.add(m);
            }
            return new ReportTableResponse(columns, rows, Map.of(),
                    r.getPage(), r.getSize(), r.getTotal(), r.getTotalPages());
        };
        return paginateAll(loader);
    }

    /**
     * 货架目视化清单导出（report='shelf-labels'）：货品主档已维护库位号的全部货品，
     * 列 = 库行/库位号/物料编码/物料系列/物料名称/颜色（与现场挂牌一致 + 库行便于分组打印）。
     * 参数：rack（库行，如 A31）/keyword；与库存数量无关。
     */
    private ExportPayload exportShelfLabels(Map<String, String> p) {
        String rack = p == null ? null : p.get("rack");
        String kw = p == null ? null : p.get("keyword");
        var items = stockQueryService.shelfLabelRows(rack, kw);
        List<ExportColumn> cols = List.of(
                new ExportColumn("rack", "库行", "text"),
                new ExportColumn("place", "库位号", "text"),
                new ExportColumn("goodsCode", "物料编码", "text"),
                new ExportColumn("series", "物料系列", "text"),
                new ExportColumn("goodsName", "物料名称", "text"),
                new ExportColumn("colorName", "颜色", "text"));
        List<Map<String, Object>> rows = new ArrayList<>(items.size());
        for (var it : items) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("rack", it.getRack());
            m.put("place", it.getPlace());
            m.put("goodsCode", it.getGoodsCode());
            m.put("series", it.getSeries());
            m.put("goodsName", it.getGoodsName());
            m.put("colorName", it.getColorName());
            rows.add(m);
        }
        return new ExportPayload(cols, rows, rows.size());
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

    // ======================== 通用执行器（与 purchase/sales 同型） ========================

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
