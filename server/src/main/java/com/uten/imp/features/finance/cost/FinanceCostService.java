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
 *       单位成本 c_total；期间实际单位成本=成品入库流水(movement_type=13) amount_local/qty 加权；差异=实际−标准。</li>
 *   <li><b>销售成本核算汇总</b>（附件 15）{@link #salesCostSummary}：按客户 销售出货金额 E（出货−退货）、
 *       销售成本 F=Σ(数量×货品 c_total)、含工本比率 F/E、管理费 8%=F×8%、销售费用（区域 OEM 1%/外贸 6%/内销 25%）=E×rate、
 *       税费 10%=E×10%、运费(无数据源 NULL)、净利润=E−F−H−I−J、净利润率、汇率 MAX。</li>
 *   <li><b>铜柱加工费核算</b>（附件 7）{@link #copperFee}：委外进仓按货品聚合 数量×单价=金额
 *       （keyword 按加工商，如 铜柱车间/黄庆哲）。</li>
 *   <li><b>插套酸洗入库明细</b>（附件 7-1）{@link #copperPickling}：酸洗件委外进仓逐行 时间/货品/重量KG/数量个。</li>
 *   <li><b>塑料耗用明细</b>（附件 8）{@link #plasticUsage}：车间口径 上月结存 C=累计领用−累计退料−累计耗用(BOM 重量归属)、
 *       本月领用 D(DRAW)、退料 E(WDRAW)、产品入库耗用 H(BOM 归属成品入库重量)、账面结存=C+D−E−H、
 *       盘点数(CHECK 最新 count_qty)、差异=盘点−账面、成品占材料比例=H/(C+D)。</li>
 *   <li><b>塑料领料/退料/产品入库明细</b>（附件 8-1/8-2/8-3）{@link #plasticDetail}：kind=issue/return/finished。</li>
 * </ul>
 *
 * <p>口径说明：只取 status=1 已审核单据；stock_movements movement_type：5=DRAW 领用 / 6=WDRAW 退料 /
 * 9,10=CHECK 盘盈亏 / 13=FINISHED_IN 成品入库（已核实映射）。耗用归属两条路：①BOM（成品行重量 × 组件 qty 占比）；
 * ②无 BOM 时 goods.material 文本唯一命中材料货品名则全额归属（多命中/零命中不摊，防错配）。均属近似口径。
 * 「安装挑选不良」「运费」无数据源，列占位 NULL。</p>
 */
@Service
@RequiredArgsConstructor
public class FinanceCostService {

    private final EntityManager em;

    // ======================== 产品成本汇总（标准成本 13 项 + 实际对比） ========================

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
                ReportColumn.money("stdTotal", "标准合计"),
                ReportColumn.money("unitCost", "单位成本"),
                ReportColumn.money("actualCost", "期间实际单位成本"),
                ReportColumn.money("diff", "差异(实际−标准)"));
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
                       g.name AS party_name, g.code AS party_code
                FROM goods g
                LEFT JOIN units u ON u.legacy_id = g.unit_legacy_id
                LEFT JOIN (
                    SELECT goods_id, SUM(amount_local) / NULLIF(SUM(qty),0) AS actual
                    FROM stock_movements
                    WHERE movement_type = 13 AND transaction_date BETWEEN :from AND :to
                      AND COALESCE(amount_local,0) <> 0 AND COALESCE(qty,0) <> 0
                    GROUP BY goods_id
                ) a ON a.goods_id = g.id
                WHERE g.is_deleted = false
                  AND (COALESCE(g.c_total,0) <> 0 OR COALESCE(g.total,0) <> 0 OR a.actual IS NOT NULL)
                """;
        return runPaged(cols, core, "t.\"goodsCode\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 15 · 销售成本核算汇总（按客户） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse salesCostSummary(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("clientName", "客户名称", 170),
                ReportColumn.text("sellerName", "业务员", 100),
                ReportColumn.text("region", "区域", 110),
                ReportColumn.text("director", "总监", 110),
                ReportColumn.money("saleAmount", "销售出货金额"),
                ReportColumn.money("saleCost", "销售成本"),
                ReportColumn.number("costRatio", "含工本占销售比率"),
                ReportColumn.money("manageFee", "管理费8%"),
                ReportColumn.money("saleFee", "销售费用"),
                ReportColumn.money("taxFee", "税费10%"),
                ReportColumn.money("freight", "运费"),
                ReportColumn.money("netProfit", "净利润"),
                ReportColumn.number("profitRate", "净利润率"),
                ReportColumn.number("exchangeRate", "汇率"));
        // 销售费用率：区域含 OEM→1%，含 外贸→6%，其余（内销）→25%。净利润= E−F−管理费−销售费用−税费−运费。
        String core = """
                WITH ship AS (
                    SELECT d.client_id,
                           SUM(i.amount_original) AS amt,
                           SUM(i.qty * COALESCE(g.c_total,0)) AS cost,
                           MAX(d.exchange_rate) AS rate
                    FROM sales_shipment_items i
                    JOIN sales_shipments d ON d.id = i.shipment_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    GROUP BY d.client_id
                ),
                ret AS (
                    SELECT d.client_id,
                           SUM(i.amount_original) AS amt,
                           SUM(i.qty * COALESCE(g.c_total,0)) AS cost
                    FROM sales_return_items i
                    JOIN sales_returns d ON d.id = i.return_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    GROUP BY d.client_id
                ),
                agg AS (
                    SELECT s.client_id,
                           (s.amt - COALESCE(r.amt,0)) AS e,
                           (s.cost - COALESCE(r.cost,0)) AS f,
                           s.rate
                    FROM ship s LEFT JOIN ret r ON r.client_id = s.client_id
                )
                SELECT c.name AS "clientName",
                       COALESCE(em_sel.full_name,'') AS "sellerName",
                       COALESCE(c.region,'') AS "region",
                       COALESCE(dv.director,'') AS "director",
                       a.e AS "saleAmount", a.f AS "saleCost",
                       ROUND(a.f / NULLIF(a.e,0), 4) AS "costRatio",
                       ROUND(a.f * 0.08, 2) AS "manageFee",
                       ROUND(a.e * CASE WHEN COALESCE(c.region,'') ILIKE '%OEM%' THEN 0.01
                                        WHEN COALESCE(c.region,'') ILIKE '%外贸%' THEN 0.06
                                        ELSE 0.25 END, 2) AS "saleFee",
                       ROUND(a.e * 0.10, 2) AS "taxFee",
                       NULL AS "freight",
                       ROUND(a.e - a.f - a.f*0.08
                             - a.e * CASE WHEN COALESCE(c.region,'') ILIKE '%OEM%' THEN 0.01
                                          WHEN COALESCE(c.region,'') ILIKE '%外贸%' THEN 0.06
                                          ELSE 0.25 END
                             - a.e * 0.10, 2) AS "netProfit",
                       ROUND((a.e - a.f - a.f*0.08
                             - a.e * CASE WHEN COALESCE(c.region,'') ILIKE '%OEM%' THEN 0.01
                                          WHEN COALESCE(c.region,'') ILIKE '%外贸%' THEN 0.06
                                          ELSE 0.25 END
                             - a.e * 0.10) / NULLIF(a.e,0), 4) AS "profitRate",
                       a.rate AS "exchangeRate",
                       c.name AS party_name, c.code AS party_code
                FROM agg a
                JOIN clients c ON c.id = a.client_id
                LEFT JOIN client_director_v dv ON dv.client_id = c.id
                LEFT JOIN employees em_sel ON em_sel.legacy_id = CAST(NULLIF(REGEXP_REPLACE(COALESCE(c.emp_id,''),'[^0-9]','','g'),'') AS int)
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

    // ======================== 附件 8 · 塑料耗用明细（车间口径） ========================

    @Transactional(readOnly = true)
    public ReportTableResponse plasticUsage(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("goodsCode", "材料编码", 110),
                ReportColumn.text("goodsName", "材料名称", 200),
                ReportColumn.number("prevBalance", "上月结存"),
                ReportColumn.number("drawQty", "本月仓库领用"),
                ReportColumn.number("returnQty", "退料"),
                ReportColumn.number("rejectQty", "安装挑选不良"),
                ReportColumn.number("finishedWeight", "产品入库数"),
                ReportColumn.number("bookBalance", "账面结存"),
                ReportColumn.number("checkQty", "实际盘点数"),
                ReportColumn.number("diff", "差异"),
                ReportColumn.number("usageRatio", "成品占材料比例%"));
        // 车间材料结存口径：上月结存 C=累计(领用−退料−BOM耗用)；账面结存=C+D−E−H；
        // BOM 耗用=成品入库行重量 × 组件 qty 占比（塑胶单材料件近似全量归属）。
        String core = """
                WITH mv AS (
                    SELECT goods_id,
                           SUM(CASE WHEN movement_type=5 AND transaction_date < :from THEN qty ELSE 0 END) AS prev_draw,
                           SUM(CASE WHEN movement_type=6 AND transaction_date < :from THEN qty ELSE 0 END) AS prev_ret,
                           SUM(CASE WHEN movement_type=5 AND transaction_date BETWEEN :from AND :to THEN qty ELSE 0 END) AS draw_qty,
                           SUM(CASE WHEN movement_type=6 AND transaction_date BETWEEN :from AND :to THEN qty ELSE 0 END) AS ret_qty
                    FROM stock_movements
                    WHERE source_doc_type='STOCK_DOC' AND movement_type IN (5,6)
                    GROUP BY goods_id
                ),
                fin AS (
                    SELECT i.goods_id, i.weight AS w, i.bill_date
                    FROM stock_document_items i
                    JOIN stock_documents d ON d.id = i.doc_id
                    WHERE d.doc_type='FINISHED_IN' AND d.status=1 AND d.is_deleted=false AND i.is_deleted=false
                      AND COALESCE(i.weight,0) <> 0
                ),
                bom_share AS (
                    SELECT b.goods_id, b.component_goods_id, b.qty,
                           SUM(b.qty) OVER (PARTITION BY b.goods_id) AS tq
                    FROM goods_bom_items b WHERE b.is_deleted = false
                ),
                mat_map AS (
                    -- 材质文本唯一匹配（无 BOM 的成品）。按材质值去重探测（~50 个值 × 货品名 ILIKE，约 1s）：
                    -- 该材质值全库唯一命中某货品名 → 归属该材料；多命中/零命中不摊，防错配。
                    SELECT fg.id AS finished_id, u.mat_id
                    FROM (SELECT DISTINCT goods_id FROM fin) ff
                    JOIN goods fg ON fg.id = ff.goods_id
                    JOIN (
                        SELECT m.mat, MIN(g2.id::text)::uuid AS mat_id
                        FROM (
                            SELECT DISTINCT BTRIM(fg2.material) AS mat
                            FROM (SELECT DISTINCT goods_id FROM fin) ff2
                            JOIN goods fg2 ON fg2.id = ff2.goods_id
                            WHERE fg2.material IS NOT NULL AND LENGTH(BTRIM(fg2.material)) >= 4
                              AND NOT EXISTS (SELECT 1 FROM goods_bom_items b
                                              WHERE b.goods_id = fg2.id AND b.is_deleted = false)
                        ) m
                        JOIN goods g2 ON g2.is_deleted = false
                                     AND g2.name ILIKE '%' || m.mat || '%'
                        GROUP BY m.mat
                        HAVING COUNT(g2.id) = 1
                    ) u ON u.mat = BTRIM(fg.material)
                    WHERE fg.material IS NOT NULL AND LENGTH(BTRIM(fg.material)) >= 4
                      AND NOT EXISTS (SELECT 1 FROM goods_bom_items b
                                      WHERE b.goods_id = fg.id AND b.is_deleted = false)
                ),
                attr AS (
                    SELECT x.mat_id, SUM(x.prev_w) AS prev_w, SUM(x.m_w) AS m_w FROM (
                        SELECT s.component_goods_id AS mat_id,
                               CASE WHEN f.bill_date < :from THEN f.w * s.qty / NULLIF(s.tq,0) ELSE 0 END AS prev_w,
                               CASE WHEN f.bill_date BETWEEN :from AND :to THEN f.w * s.qty / NULLIF(s.tq,0) ELSE 0 END AS m_w
                        FROM fin f JOIN bom_share s ON s.goods_id = f.goods_id
                        UNION ALL
                        SELECT mm.mat_id,
                               CASE WHEN f.bill_date < :from THEN f.w ELSE 0 END,
                               CASE WHEN f.bill_date BETWEEN :from AND :to THEN f.w ELSE 0 END
                        FROM fin f JOIN mat_map mm ON mm.finished_id = f.goods_id
                    ) x GROUP BY x.mat_id
                ),
                chk AS (
                    SELECT DISTINCT ON (i.goods_id) i.goods_id, i.count_qty
                    FROM stock_document_items i
                    JOIN stock_documents d ON d.id = i.doc_id
                    WHERE d.doc_type='CHECK' AND d.status=1 AND i.is_deleted=false
                      AND i.bill_date BETWEEN :from AND :to AND i.count_qty IS NOT NULL
                    ORDER BY i.goods_id, i.bill_date DESC
                ),
                base AS (
                    SELECT g.id, g.code, g.name,
                           (COALESCE(mv.prev_draw,0) - COALESCE(mv.prev_ret,0) - COALESCE(attr.prev_w,0)) AS c_prev,
                           COALESCE(mv.draw_qty,0) AS d_draw,
                           COALESCE(mv.ret_qty,0) AS e_ret,
                           COALESCE(attr.m_w,0) AS h_fin,
                           chk.count_qty
                    FROM goods g
                    LEFT JOIN mv ON mv.goods_id = g.id
                    LEFT JOIN attr ON attr.mat_id = g.id
                    LEFT JOIN chk ON chk.goods_id = g.id
                    WHERE g.is_deleted = false
                      AND (mv.goods_id IS NOT NULL OR attr.mat_id IS NOT NULL OR chk.goods_id IS NOT NULL)
                )
                SELECT b.code AS "goodsCode", b.name AS "goodsName",
                       ROUND(b.c_prev, 3) AS "prevBalance",
                       ROUND(b.d_draw, 3) AS "drawQty",
                       ROUND(b.e_ret, 3) AS "returnQty",
                       NULL AS "rejectQty",
                       ROUND(b.h_fin, 3) AS "finishedWeight",
                       ROUND(b.c_prev + b.d_draw - b.e_ret - b.h_fin, 3) AS "bookBalance",
                       b.count_qty AS "checkQty",
                       ROUND(b.count_qty - (b.c_prev + b.d_draw - b.e_ret - b.h_fin), 3) AS "diff",
                       ROUND(b.h_fin / NULLIF(b.c_prev + b.d_draw, 0) * 100, 2) AS "usageRatio",
                       b.name AS party_name, b.code AS party_code
                FROM base b
                WHERE (b.c_prev <> 0 OR b.d_draw <> 0 OR b.e_ret <> 0 OR b.h_fin <> 0 OR b.count_qty IS NOT NULL)
                """;
        return runPaged(cols, core, "t.\"goodsCode\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 8-1/8-2/8-3 · 领料/退料/产品入库明细 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse plasticDetail(String kind, String keyword, LocalDate from, LocalDate to,
                                             int page, int size) {
        return switch (kind == null ? "issue" : kind) {
            case "return" -> plasticReturn(keyword, from, to, page, size);
            case "finished" -> plasticFinished(keyword, from, to, page, size);
            default -> plasticIssue(keyword, from, to, page, size);
        };
    }

    /** 附件 8-1 领料明细（DRAW 已审行）。 */
    private ReportTableResponse plasticIssue(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("planNo", "订单号", 120),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.text("model", "型号", 120),
                ReportColumn.text("color", "颜色", 100),
                ReportColumn.number("qty", "实发数量"),
                ReportColumn.text("remark", "备注", 160));
        String core = """
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate",
                       COALESCE(d.plan_no,'') AS "planNo",
                       g.name AS "goodsName", COALESCE(g.model,'') AS "model",
                       COALESCE(c.name,'') AS "color", i.qty AS "qty",
                       COALESCE(i.remark,'') AS "remark",
                       g.name AS party_name, g.code AS party_code
                FROM stock_document_items i
                JOIN stock_documents d ON d.id = i.doc_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                WHERE d.doc_type = 'DRAW' AND d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND i.bill_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
    }

    /** 附件 8-2 退料明细（WDRAW 已审行）。 */
    private ReportTableResponse plasticReturn(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("billNo", "单号", 140),
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("series", "系列", 100),
                ReportColumn.text("goodsCode", "编号", 130),
                ReportColumn.text("goodsName", "货品名称", 200),
                ReportColumn.number("qty", "实退数量"));
        String core = """
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate",
                       COALESCE(g.series,'') AS "series",
                       (g.code || CASE WHEN NULLIF(BTRIM(COALESCE(c.code, '')), '') IS NOT NULL THEN '-' || BTRIM(c.code) ELSE '' END) AS "goodsCode",
                       g.name AS "goodsName", i.qty AS "qty",
                       g.name AS party_name, g.code AS party_code
                FROM stock_document_items i
                JOIN stock_documents d ON d.id = i.doc_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                WHERE d.doc_type = 'WDRAW' AND d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND i.bill_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
    }

    /** 附件 8-3 产品入库明细（FINISHED_IN 已审行）。 */
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
                SELECT i.bill_no AS "billNo", i.bill_date AS "billDate",
                       COALESCE(g.series,'') AS "series",
                       (g.code || CASE WHEN NULLIF(BTRIM(COALESCE(c.code, '')), '') IS NOT NULL THEN '-' || BTRIM(c.code) ELSE '' END) AS "goodsCode",
                       g.name AS "goodsName", COALESCE(c.name,'') AS "color",
                       COALESCE(g.material,'') AS "material",
                       COALESCE(i.weight,0) AS "weight", i.qty AS "qty",
                       COALESCE(i.remark,'') AS "remark",
                       g.name AS party_name, g.code AS party_code
                FROM stock_document_items i
                JOIN stock_documents d ON d.id = i.doc_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                WHERE d.doc_type = 'FINISHED_IN' AND d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                  AND i.bill_date BETWEEN :from AND :to
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
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
            for (int i = 0; i < cols.size(); i++) m.put(cols.get(i).key(), norm(r[i]));
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
