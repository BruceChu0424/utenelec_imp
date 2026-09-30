package com.uten.imp.features.finance.cost;

import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 成本核算报表（C4 · 王少春 4 项；附件 15/7/7-1/8/8-1/8-2/8-3 模板列结构照抄）。
 *
 * <ul>
 *   <li><b>产品成本汇总</b> {@link #productCost}：货品 13 项成本预算字段（source_e 材料费 + work/make/lacquer/
 *       plating/machining/polish/electric/incidental/manage/lost/rent/casing_e）+ 标准合计 total +
 *       单位成本 c_total 仅作为历史主档预算；实际值来自有效成品入库的生产价值来源，未核清保持待定。</li>
 *   <li><b>销售成本核算汇总</b>（附件 15）{@link #salesCostSummary}：按客户 销售出货金额 E（出货−退货）、
 *       销售成本读取追加式 COGS 价值变动（含退货与后补差额），收入使用已审核 AR 本币原额。
 *       未归集的费用、税费和净利润为 NULL，不套固定费率。</li>
 *   <li><b>铜柱加工费核算</b>（附件 7）{@link #copperFee}：委外进仓按货品聚合 数量×单价=金额
 *       （keyword 按加工商，如 铜柱车间/黄庆哲）。</li>
 *   <li><b>插套酸洗入库明细</b>（附件 7-1）{@link #copperPickling}：酸洗件委外进仓逐行 时间/货品/重量KG/数量个。</li>
 *   <li><b>塑料耗用明细</b>(附件 8){@link #plasticUsage}：数据源是车间内料仓的结算结果 (ADR-131 §7.5),
 *       按内料仓的期间出表; 上月结存 = 期初实盘、本月仓库领用 = 领入、退料 = 退回、产品入库数 = 理论用量、
 *       账面结存 = 期初 + 领入 − 退回 − 其它耗用 − 理论、实际盘点数 = 期末实盘、差异 = 实盘 − 账面。</li>
 *   <li><b>塑料领料/退料/产品入库明细</b>(附件 8-1/8-2/8-3){@link #plasticDetail}：kind=issue/return/finished,
 *       领料与退料取内料仓流水, 产品入库取已结算各期的理论明细。</li>
 * </ul>
 *
 * <p>口径说明：只取 status=1 已审核单据；stock_movements movement_type：5=DRAW 领用 / 6=WDRAW 退料 /
 * 9,10=CHECK 盘盈亏 / 13=FINISHED_IN 成品入库 (已核实映射)。「运费」无数据源，列占位 NULL。
 * 附件 8 不再用"成品入库重量 × BOM 占比"与"材质文本推断"两条近似口径, 一律读内料仓结算结果;
 * 「安装挑选不良」第一期恒为 0, 表头注明待不良数上线。</p>
 */
@Service
@RequiredArgsConstructor
public class FinanceCostService {

    private final EntityManager em;

    // ======================== 产品成本汇总（标准成本 13 项 + 实际对比） ========================

    /** 历史预算与本期有效产出当前价值对照；撤回入库不重复计数，合法零成本不被过滤。 */
    @Transactional(readOnly = true)
    public ReportTableResponse productCost(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("goodsCode", "货品编码", 110),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.text("spec", "规格型号", 130),
                ReportColumn.text("unit", "单位", 60),
                ReportColumn.money("sourceFee", "材料费"),
                ReportColumn.money("workFee", "工费"),
                ReportColumn.money("makeFee", "制作费"),
                ReportColumn.money("lacquerFee", "喷油费"),
                ReportColumn.money("platingFee", "电镀费"),
                ReportColumn.money("machiningFee", "机加费"),
                ReportColumn.money("polishFee", "抛光费"),
                ReportColumn.money("electricFee", "电费"),
                ReportColumn.money("incidentalFee", "杂项费"),
                ReportColumn.money("manageFee", "管理费"),
                ReportColumn.money("lostFee", "损耗费"),
                ReportColumn.money("rentFee", "租金"),
                ReportColumn.money("casingFee", "外壳费"),
                ReportColumn.money("stdTotal", "历史主档预算合计"),
                ReportColumn.money("unitCost", "历史主档单位预算"),
                ReportColumn.money("actualCost", "有效入库当前单位成本"),
                ReportColumn.money("diff", "差异(实际−历史预算)"),
                ReportColumn.number("actualQty", "有效入库数量"),
                ReportColumn.money("knownActualAmount", "已归集入库成本"),
                ReportColumn.text("actualState", "成本状态", 150));
        String core = """
                SELECT g.code AS "goodsCode", g.name AS "goodsName",
                       TRIM(BOTH ' ' FROM COALESCE(g.spec,'') || ' ' || COALESCE(g.model,'')) AS "spec",
                       COALESCE(u.name,'') AS "unit",
                       COALESCE(g.source_e,0) AS "sourceFee", COALESCE(g.work_e,0) AS "workFee",
                       COALESCE(g.make_e,0) AS "makeFee", COALESCE(g.lacquer_e,0) AS "lacquerFee",
                       COALESCE(g.plating_e,0) AS "platingFee", COALESCE(g.machining_e,0) AS "machiningFee",
                       COALESCE(g.polish_e,0) AS "polishFee", COALESCE(g.electric_e,0) AS "electricFee",
                       COALESCE(g.incidental_e,0) AS "incidentalFee", COALESCE(g.manage_e,0) AS "manageFee",
                       COALESCE(g.lost_e,0) AS "lostFee", COALESCE(g.rent_e,0) AS "rentFee",
                       COALESCE(g.casing_e,0) AS "casingFee",
                       COALESCE(g.total,0) AS "stdTotal", COALESCE(g.c_total,0) AS "unitCost",
                       a.actual AS "actualCost",
                       (a.actual - g.c_total) AS "diff",
                       a.qty AS "actualQty",a.known_amount AS "knownActualAmount",a.state AS "actualState",
                       g.name AS party_name, g.code AS party_code
                FROM goods g
                LEFT JOIN units u
                  ON (u.id = g.unit_id
                      OR (g.unit_id IS NULL
                          AND u.legacy_id = NULLIF(g.unit_legacy_id, 0)))
                LEFT JOIN (
                    SELECT goods_id,SUM(effective_qty) qty,SUM(known_amount_local) known_amount,
                           CASE WHEN NOT bool_or(pending OR known_amount_local IS NULL) AND SUM(effective_qty)>0
                                THEN SUM(known_amount_local)/SUM(effective_qty) END actual,
                           CASE WHEN SUM(effective_qty)=0 THEN 'WITHDRAWN'
                                WHEN bool_or(pending OR known_amount_local IS NULL) THEN 'PENDING'
                                ELSE 'VALUATION_FINAL' END state
                    FROM v_stock_actual_finished_receipts
                    WHERE business_date BETWEEN :from AND :to
                    GROUP BY goods_id
                ) a ON a.goods_id = g.id
                WHERE g.is_deleted = false
                  AND (COALESCE(g.c_total,0) <> 0 OR COALESCE(g.total,0) <> 0 OR a.goods_id IS NOT NULL)
                """;
        return runPaged(cols, core, "t.\"goodsCode\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 15 · 销售成本核算汇总（按客户） ========================

    /** 本币收入与同期间实际 COGS 变动；保留仅退货、后补差额和未核价客户。 */
    @Transactional(readOnly = true)
    public ReportTableResponse salesCostSummary(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户名称", 170),
                ReportColumn.text("sellerName", "业务员", 100),
                ReportColumn.text("region", "区域", 110),
                ReportColumn.text("director", "总监", 110),
                ReportColumn.money("saleAmount", "销售净额（本币）"),
                ReportColumn.money("saleCost", "已知销售成本（本币）"),
                ReportColumn.number("costRatio", "含工本占销售比率"),
                ReportColumn.money("manageFee", "管理费（待归集）"),
                ReportColumn.money("saleFee", "销售费用"),
                ReportColumn.money("taxFee", "税费（待归集）"),
                ReportColumn.money("freight", "运费"),
                ReportColumn.money("netProfit", "净利润"),
                ReportColumn.number("profitRate", "净利润率"),
                ReportColumn.text("currencyBasis", "币种口径", 100),
                ReportColumn.text("costState", "成本状态", 150));
        String core = """
                WITH revenue AS (
                    SELECT client_id,sum(amount_original_local) amount FROM ar_ap_ledger
                    WHERE direction='AR' AND source_doc_type IN('SALES_SHIPMENT','SALES_RETURN')
                      AND status=1 AND NOT is_deleted AND bill_date BETWEEN :from AND :to GROUP BY client_id
                ), costs AS (
                    SELECT client_id,sum(amount_local) amount,bool_or(pending) pending
                    FROM v_stock_actual_cogs_postings WHERE business_date BETWEEN :from AND :to GROUP BY client_id
                ), coverage AS (
                    SELECT client_id,bool_or(pending) pending FROM v_stock_actual_sales_cost_coverage
                    WHERE business_date BETWEEN :from AND :to GROUP BY client_id
                ), client_scope AS (
                    SELECT client_id FROM revenue UNION SELECT client_id FROM costs UNION SELECT client_id FROM coverage
                ), agg AS (
                    SELECT scope.client_id,COALESCE(revenue.amount,0) e,
                           CASE WHEN costs.amount IS NOT NULL THEN costs.amount
                                WHEN coverage.client_id IS NOT NULL AND NOT coverage.pending THEN 0 END f,
                           COALESCE(costs.pending,false) OR COALESCE(coverage.pending,false)
                             OR (costs.amount IS NULL AND coverage.client_id IS NULL) pending
                    FROM client_scope scope LEFT JOIN revenue ON revenue.client_id IS NOT DISTINCT FROM scope.client_id
                    LEFT JOIN costs ON costs.client_id IS NOT DISTINCT FROM scope.client_id
                    LEFT JOIN coverage ON coverage.client_id IS NOT DISTINCT FROM scope.client_id
                )
                SELECT COALESCE(c.name,'来源客户待核实') AS "clientName",
                       COALESCE(em_sel.full_name,'') AS "sellerName",
                       COALESCE(c.region,'') AS "region",
                       COALESCE(dv.director,'') AS "director",
                       a.e AS "saleAmount", a.f AS "saleCost",
                       CASE WHEN NOT a.pending THEN ROUND(a.f / NULLIF(a.e,0), 4) END AS "costRatio",
                       NULL::numeric AS "manageFee",NULL::numeric AS "saleFee",NULL::numeric AS "taxFee",
                       NULL::numeric AS "freight",NULL::numeric AS "netProfit",NULL::numeric AS "profitRate",
                       'LOCAL' AS "currencyBasis",
                       CASE WHEN a.pending THEN 'COST_PENDING' ELSE 'COGS_KNOWN_OTHER_EXPENSES_PENDING' END AS "costState",
                       COALESCE(c.name,'来源客户待核实') AS party_name, c.code AS party_code
                FROM agg a
                LEFT JOIN clients c ON c.id = a.client_id
                LEFT JOIN client_director_v dv ON dv.client_id = c.id
                LEFT JOIN employees em_sel
                  ON (em_sel.id = c.owner_employee_id
                      OR (c.owner_employee_id IS NULL
                          AND em_sel.legacy_id = CASE
                              WHEN BTRIM(COALESCE(c.emp_id,'')) ~ '^[0-9]{1,9}$'
                              THEN BTRIM(c.emp_id)::int ELSE NULL END))
                """;
        return runPaged(cols, core, "t.\"clientName\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 7 · 铜柱加工费核算（委外进仓按货品聚合） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse copperFee(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("supplierName", "加工商", 140),
                ReportColumn.text("goodsName", "产品名称", 220),
                ReportColumn.text("unit", "单位", 70),
                ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "单价"),
                ReportColumn.money("amount", "金额"));
        String core = """
                SELECT s.name AS "supplierName", g.name AS "goodsName",
                       COALESCE(u.name,'') AS "unit",
                       SUM(i.qty) AS "qty",
                       (ARRAY_AGG(i.price ORDER BY i.bill_date DESC)
                           FILTER (WHERE i.price IS NOT NULL AND i.price <> 0))[1] AS "price",
                       SUM(i.qty) * COALESCE((ARRAY_AGG(i.price ORDER BY i.bill_date DESC)
                           FILTER (WHERE i.price IS NOT NULL AND i.price <> 0))[1], 0) AS "amount",
                       s.name AS party_name, s.code AS party_code
                FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                JOIN suppliers s ON s.id = d.supplier_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND i.bill_date BETWEEN :from AND :to
                GROUP BY s.name, s.code, g.name, u.name
                """;
        return runPaged(cols, core, "t.\"supplierName\", t.\"goodsName\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 7-1 · 插套酸洗入库明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse copperPickling(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "时间"),
                ReportColumn.text("supplierName", "车间/加工商", 130),
                ReportColumn.text("goodsName", "货品名称", 220),
                ReportColumn.number("weight", "重量(KG)"),
                ReportColumn.number("qty", "数量(个)"),
                ReportColumn.text("billNo", "入库单号", 140));
        String core = """
                SELECT i.bill_date AS "billDate", s.name AS "supplierName",
                       g.name AS "goodsName",
                       COALESCE(i.weight,0) AS "weight", i.qty AS "qty", i.bill_no AS "billNo",
                       s.name AS party_name, g.name AS party_code
                FROM subcontract_receipt_items i
                JOIN subcontract_receipts d ON d.id = i.receipt_id
                JOIN suppliers s ON s.id = d.supplier_id
                LEFT JOIN goods g ON g.id = i.goods_id
                WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND i.bill_date BETWEEN :from AND :to
                  AND (g.name ILIKE '%酸洗%' OR s.name ILIKE '%铜柱%')
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"goodsName\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 8 · 塑料耗用明细(车间内料仓结算结果) ========================

    /**
     * 塑料耗用明细(ADR-131 §7.5)：按车间内料仓的期间出表，按月查询时列出期末日落在所选日期范围里的已结算各期。
     * 列名列序保持会计模板原样，末尾追加「其它耗用」「期间」「内料仓」。上月结存 = 期初实盘；本月仓库领用 = 领入；
     * 退料 = 退回；安装挑选不良第一期恒为 0(待不良数上线)；产品入库数 = 理论用量(良品 × 单个重量；辅料取按主料理论
     * 分到产品的量，记车间费用的料为 0)；账面结存 = 期初 + 领入 − 退回 − 其它耗用 − 产品入库数；实际盘点数 = 期末实盘；
     * 差异 = 实盘 − 账面(负数表示多用)；成品占材料比例% = 产品入库数 / 实际用量。
     */
    @Transactional(readOnly = true)
    public ReportTableResponse plasticUsage(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("goodsCode", "材料编码", 110),
                ReportColumn.text("goodsName", "材料名称", 200),
                ReportColumn.number("prevBalance", "上月结存"),
                ReportColumn.number("drawQty", "本月仓库领用"),
                ReportColumn.number("returnQty", "退料"),
                ReportColumn.number("rejectQty", "安装挑选不良(待不良数上线)"),
                ReportColumn.number("finishedWeight", "产品入库数"),
                ReportColumn.number("bookBalance", "账面结存"),
                ReportColumn.number("checkQty", "实际盘点数"),
                ReportColumn.number("diff", "差异"),
                ReportColumn.number("usageRatio", "成品占材料比例%"),
                ReportColumn.number("otherIssueQty", "其它耗用"),
                ReportColumn.text("periodLabel", "期间", 190),
                ReportColumn.text("binName", "内料仓", 160));
        String core = """
                SELECT goods.code AS "goodsCode",
                       goods.name || COALESCE(' ' || color.name, '') AS "goodsName",
                       report.opening_qty AS "prevBalance",
                       report.transfer_in_qty AS "drawQty",
                       report.return_qty AS "returnQty",
                       CAST(0 AS numeric) AS "rejectQty",
                       used.product_qty AS "finishedWeight",
                       report.opening_qty + report.transfer_in_qty - report.return_qty - report.other_issue_qty
                           - used.product_qty AS "bookBalance",
                       report.closing_qty AS "checkQty",
                       report.closing_qty - (report.opening_qty + report.transfer_in_qty - report.return_qty
                           - report.other_issue_qty - used.product_qty) AS "diff",
                       CASE WHEN report.actual_qty > 0
                            THEN round(used.product_qty / report.actual_qty * 100, 2) END AS "usageRatio",
                       report.other_issue_qty AS "otherIssueQty",
                       to_char(report.start_date, 'YYYY-MM-DD') || ' 至 ' || to_char(report.end_date, 'YYYY-MM-DD')
                           AS "periodLabel",
                       bin.name AS "binName",
                       goods.name AS party_name, goods.code AS party_code,
                       report.end_date AS sort_end_date, report.period_no AS sort_period_no
                FROM v_workshop_material_period_report report
                JOIN goods ON goods.id = report.goods_id
                LEFT JOIN colors color ON color.id = report.color_id
                JOIN warehouses bin ON bin.id = report.bin_warehouse_id
                CROSS JOIN LATERAL (
                    SELECT round(CASE report.cost_basis WHEN 'OWN' THEN COALESCE(report.theory_qty, 0)
                                                        WHEN 'SHARED' THEN report.consumed_qty
                                                        ELSE 0 END, 4) AS product_qty) used
                WHERE report.close_id IS NOT NULL
                  AND report.end_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"binName\", t.sort_end_date, t.sort_period_no, t.\"goodsCode\"",
                keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 8-1/8-2/8-3 · 领料/退料/产品入库明细(内料仓流水与理论明细) ========================

    @Transactional(readOnly = true)
    public ReportTableResponse plasticDetail(String kind, String keyword, LocalDate from, LocalDate to,
                                             int page, int size) {
        return switch (kind == null ? "issue" : kind) {
            case "return" -> plasticReturn(keyword, from, to, page, size);
            case "finished" -> plasticFinished(keyword, from, to, page, size);
            default -> plasticIssue(keyword, from, to, page, size);
        };
    }

    /** 附件 8-1 领料明细：仓库发到车间内料仓的每一笔(业务日期落在所选范围)。 */
    private ReportTableResponse plasticIssue(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("planNo", "领料单号", 120),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.text("model", "型号", 120),
                ReportColumn.text("color", "颜色", 100),
                ReportColumn.number("qty", "实发数量"),
                ReportColumn.text("remark", "备注", 160));
        String core = """
                SELECT document.bill_no AS "billNo", ledger.business_date AS "billDate",
                       requisition.request_no AS "planNo",
                       goods.name AS "goodsName", COALESCE(goods.model, '') AS "model",
                       COALESCE(color.name, '') AS "color", ledger.signed_qty AS "qty",
                       bin.name || CASE WHEN ledger.is_supplement THEN ' 上一期漏录补录' ELSE '' END AS "remark",
                       goods.name AS party_name, goods.code AS party_code
                FROM v_workshop_material_bin_ledger ledger
                JOIN workshop_material_requisition_postings posting ON posting.id = ledger.source_row_id
                JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
                JOIN workshop_material_requisitions requisition ON requisition.id = line.requisition_id
                JOIN stock_document_items item ON item.id = posting.stock_document_item_id
                JOIN stock_documents document ON document.id = item.doc_id
                JOIN goods ON goods.id = ledger.goods_id
                LEFT JOIN colors color ON color.id = ledger.color_id
                JOIN warehouses bin ON bin.id = ledger.bin_warehouse_id
                WHERE ledger.source_kind = 'ISSUE' AND ledger.business_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
    }

    /** 附件 8-2 退料明细：车间内料仓退回仓库的每一笔。 */
    private ReportTableResponse plasticReturn(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("series", "系列", 100),
                ReportColumn.text("goodsCode", "编号", 130),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.number("qty", "实退数量"));
        String core = """
                SELECT document.bill_no AS "billNo", ledger.business_date AS "billDate",
                       COALESCE(goods.series, '') AS "series",
                       (goods.code || CASE WHEN NULLIF(BTRIM(COALESCE(color.code, '')), '') IS NOT NULL
                                           THEN '-' || BTRIM(color.code) ELSE '' END) AS "goodsCode",
                       goods.name AS "goodsName", -ledger.signed_qty AS "qty",
                       goods.name AS party_name, goods.code AS party_code
                FROM v_workshop_material_bin_ledger ledger
                JOIN workshop_material_requisition_postings posting ON posting.id = ledger.source_row_id
                JOIN stock_document_items item ON item.id = posting.stock_document_item_id
                JOIN stock_documents document ON document.id = item.doc_id
                JOIN goods ON goods.id = ledger.goods_id
                LEFT JOIN colors color ON color.id = ledger.color_id
                WHERE ledger.source_kind = 'RETURN' AND ledger.business_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
    }

    /** 附件 8-3 产品入库明细：已结算各期的理论明细(每行报工 × 所用的料；重量 = 良品 × 单个重量)。 */
    private ReportTableResponse plasticFinished(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("series", "系列", 100),
                ReportColumn.text("goodsCode", "编号", 130),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.text("color", "颜色", 100),
                ReportColumn.text("material", "材质", 120),
                ReportColumn.number("weight", "重量"),
                ReportColumn.number("qty", "数量"),
                ReportColumn.text("remark", "备注", 160));
        String core = """
                SELECT report.bill_no AS "billNo", theory.business_date AS "billDate",
                       COALESCE(product.series, '') AS "series",
                       (product.code || CASE WHEN NULLIF(BTRIM(COALESCE(item_color.code, '')), '') IS NOT NULL
                                             THEN '-' || BTRIM(item_color.code) ELSE '' END) AS "goodsCode",
                       product.name AS "goodsName", COALESCE(item_color.name, '') AS "color",
                       material.name AS "material", theory.theory_qty AS "weight", theory.output_qty_base AS "qty",
                       bin.name || ' ' || to_char(period.start_date, 'YYYY-MM-DD') || ' 至 '
                           || to_char(period.end_date, 'YYYY-MM-DD') AS "remark",
                       product.name AS party_name, product.code AS party_code
                FROM workshop_material_close_theory_lines theory
                JOIN workshop_material_period_closes period_close
                  ON period_close.id = theory.close_id AND period_close.status = 'ACTIVE'
                JOIN workshop_material_close_materials close_material ON close_material.id = theory.close_material_id
                JOIN workshop_material_period_lines line ON line.id = close_material.period_line_id
                JOIN workshop_material_periods period ON period.id = line.period_id
                JOIN warehouses bin ON bin.id = period.bin_warehouse_id
                JOIN goods material ON material.id = line.goods_id
                JOIN production_daily_reports report ON report.id = theory.report_id
                JOIN production_daily_report_items item ON item.id = theory.report_item_id
                JOIN goods product ON product.id = theory.product_goods_id
                LEFT JOIN colors item_color ON item_color.id = item.color_id
                WHERE theory.business_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\", t.\"goodsCode\"", keyword, from, to, page, size,
                Map.of());
    }

    // ======================== 通用执行器（同 FinanceStatementService 范式） ========================

    /** core 末尾必须输出 party_name/party_code 两列（keyword 过滤；尾部两列不进结果映射）。 */
    private ReportTableResponse runPaged(List<ReportColumn> cols, String coreSql, String orderBy,
                                         String keyword, LocalDate from, LocalDate to,
                                         int page, int size, Map<String, Object> extraParams) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;
        String where = "WHERE TRUE";
        if (keyword != null && !keyword.isBlank()) {
            where = "WHERE (LOWER(COALESCE(t.party_name,'')) LIKE LOWER(:kw)"
                    + " OR LOWER(COALESCE(t.party_code,'')) LIKE LOWER(:kw))";
        }
        String wrapped = "SELECT * FROM (" + coreSql + ") t " + where;
        var dq = em.createNativeQuery(wrapped + " ORDER BY " + orderBy + " LIMIT :__l OFFSET :__o");
        bindRaw(dq, keyword, from, to, extraParams);
        dq.setParameter("__l", safeSize);
        dq.setParameter("__o", offset);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = dq.getResultList();
        List<Map<String, Object>> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            Map<String, Object> m = new LinkedHashMap<>();
            for (int i = 0; i < cols.size(); i++) {
                m.put(cols.get(i).key(), norm(r[i]));
                if (r[i] instanceof BigDecimal decimal) m.put(cols.get(i).key()+"Exact",decimal.toPlainString());
            }
            items.add(m);
        }
        var cq = em.createNativeQuery("SELECT COUNT(*) FROM (" + coreSql + ") t " + where);
        bindRaw(cq, keyword, from, to, extraParams);
        long total = ((Number) cq.getSingleResult()).longValue();
        int totalPages = safeSize == 0 ? 0 : (int) ((total + safeSize - 1) / safeSize);
        return new ReportTableResponse(cols, items, new LinkedHashMap<>(), safePage, safeSize, total, totalPages);
    }

    private static void bindRaw(Query q, String keyword, LocalDate from, LocalDate to, Map<String, Object> extra) {
        if (keyword != null && !keyword.isBlank()) q.setParameter("kw", "%" + keyword.toLowerCase() + "%");
        q.setParameter("from", from);
        q.setParameter("to", to);
        extra.forEach(q::setParameter);
    }

    private static Object norm(Object v) {
        if (v == null) return null;
        if (v instanceof java.sql.Date d) return d.toLocalDate().toString();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate().toString();
        if (v instanceof java.time.OffsetDateTime odt) return odt.toLocalDate().toString();
        if (v instanceof BigDecimal || v instanceof Boolean || v instanceof Number) return v;
        if (v instanceof UUID u) return u.toString();
        return v.toString();
    }
}
