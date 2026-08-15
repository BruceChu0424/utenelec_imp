package com.uten.imp.features.finance.statement;

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
 * 月结对账单自动生成（C2 · 财务室 5 张「目前手工做」对账单，模板列结构照抄附件 Excel）。
 *
 * <ul>
 *   <li><b>委外加工对账单</b>（附件 1，兼「采购外放加工对账单」梁淑华·核对供应商欠料）：
 *       {@link #subcontractStatement}。按 委外商+货品+颜色 聚合：期初库存(PCS)=累计发料−累计损耗−累计进仓；
 *       本月入库=委外发料（材料单号/日期/数量合计）；允许损耗=入库×损耗率(默认 3%，可传 5%)；
 *       本月出货=委外进仓（入库单号/日期/数量合计）；结存=期初+入库−损耗−出货；
 *       金额=出货×加工单价（进仓行最新非零价）；减扣材料款=结存×材料单价（发料行最新非零价）。</li>
 *   <li><b>供应商对账单</b>（附件 2）：{@link #supplierStatement}。采购收货行 + 采购退货行(负数)，
 *       列：送货日期/物料编码/物料名称/单位/数量/含税单价/含税金额/备注(单号)。</li>
 *   <li><b>其他应收款对账单</b>（附件 4 · 铜材加工按重量）：{@link #otherReceivableStatement}。
 *       委外发料(发出重量/数量)+委外进仓(进仓重量) 逐行流水，损耗 0.5% 按进仓重量，
 *       结余=逐行滚动(含期初)；加工货款=发出数量×加工单价。</li>
 *   <li><b>应收账款客户对账单</b>（附件 5）：{@link #clientStatement}。销售出货行 + 销售退货行(负数)，
 *       列：开单日期/货品名称/颜色/单位/数量/含税单价/含税金额/备注(单号)。</li>
 * </ul>
 *
 * <p>口径说明：只取 status=1（已审核）单据，红冲(-1)/草稿不进表；keyword 过滤往来单位名称/编号；
 * 日期范围默认上月今日..今日（前端通用页），对账按月选起止即可。
 * 数据局限：发料行 order_item_id 老库未填（全 NULL），材料↔成品按 货品+委外商 直接对应
 * （抽样核实发料行货品即加工件本身，如 80B 外框/金本铜粒）。</p>
 */
@Service
@RequiredArgsConstructor
public class FinanceStatementService {

    private final EntityManager em;

    // ======================== 附件 1 · 委外加工对账单（=采购外放加工对账单） ========================

    /** 委外加工对账单：按 委外商+货品+颜色 聚合，委外发料与进仓 FULL OUTER JOIN；结存=期初+入库−损耗−出货，金额=出货×进仓行最新非零价，损耗率 lossRate 缺省 3%（可传 5%）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse subcontractStatement(String keyword, LocalDate from, LocalDate to,
                                                    BigDecimal lossRate, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.text("supplierCode", "供应商编号", 110),
                ReportColumn.text("supplierName", "委外商", 150),
                ReportColumn.text("goodsCode", "物料编码", 110),
                ReportColumn.text("goodsName", "品名及规格", 200),
                ReportColumn.text("color", "颜色", 100),
                ReportColumn.number("prevStock", "期初库存(PCS)"),
                ReportColumn.text("issueBillNo", "材料单号", 150),
                ReportColumn.date("issueDate", "入库日期"),
                ReportColumn.number("issueQty", "入库数量合计"),
                ReportColumn.number("lossAllowed", "允许损耗"),
                ReportColumn.text("receiptBillNo", "入库单号", 150),
                ReportColumn.date("receiptDate", "出货日期"),
                ReportColumn.number("receiptQty", "出货数量合计"),
                ReportColumn.number("balance", "结存"),
                ReportColumn.money("processPrice", "加工单价含税"),
                ReportColumn.money("processAmount", "金额"),
                ReportColumn.money("materialPrice", "减扣材料款单价"),
                ReportColumn.money("materialAmount", "减扣材料款金额"));
        String core = """
                WITH iss AS (
                    SELECT d.supplier_id, i.goods_id, i.color_id,
                           SUM(CASE WHEN i.bill_date < :from THEN i.qty ELSE 0 END) AS prior_qty,
                           SUM(CASE WHEN i.bill_date < :from THEN COALESCE(i.wasted_qty,0) ELSE 0 END) AS prior_waste,
                           SUM(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.qty ELSE 0 END) AS m_qty,
                           STRING_AGG(DISTINCT CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.bill_no END, '、') AS m_nos,
                           MAX(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.bill_date END) AS m_date,
                           (ARRAY_AGG(i.price ORDER BY i.bill_date DESC)
                               FILTER (WHERE i.price IS NOT NULL AND i.price <> 0))[1] AS m_price
                    FROM subcontract_material_issue_items i
                    JOIN subcontract_material_issues d ON d.id = i.issue_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                    GROUP BY d.supplier_id, i.goods_id, i.color_id
                ),
                rcv AS (
                    SELECT d.supplier_id, i.goods_id, i.color_id,
                           SUM(CASE WHEN i.bill_date < :from THEN i.qty ELSE 0 END) AS prior_qty,
                           SUM(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.qty ELSE 0 END) AS m_qty,
                           STRING_AGG(DISTINCT CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.bill_no END, '、') AS m_nos,
                           MAX(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.bill_date END) AS m_date,
                           (ARRAY_AGG(i.price ORDER BY i.bill_date DESC)
                               FILTER (WHERE i.price IS NOT NULL AND i.price <> 0))[1] AS m_price
                    FROM subcontract_receipt_items i
                    JOIN subcontract_receipts d ON d.id = i.receipt_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                    GROUP BY d.supplier_id, i.goods_id, i.color_id
                ),
                merged AS (
                    SELECT COALESCE(iss.supplier_id, rcv.supplier_id) AS supplier_id,
                           COALESCE(iss.goods_id, rcv.goods_id) AS goods_id,
                           COALESCE(iss.color_id, rcv.color_id) AS color_id,
                           COALESCE(iss.prior_qty,0) - COALESCE(iss.prior_waste,0) - COALESCE(rcv.prior_qty,0) AS prev_stock,
                           iss.m_nos AS iss_nos, iss.m_date AS iss_date, COALESCE(iss.m_qty,0) AS iss_qty,
                           ROUND(COALESCE(iss.m_qty,0) * :lossRate, 2) AS loss_allowed,
                           rcv.m_nos AS rcv_nos, rcv.m_date AS rcv_date, COALESCE(rcv.m_qty,0) AS rcv_qty,
                           rcv.m_price AS process_price, iss.m_price AS material_price
                    FROM iss FULL OUTER JOIN rcv
                      ON rcv.supplier_id = iss.supplier_id AND rcv.goods_id = iss.goods_id
                         AND rcv.color_id IS NOT DISTINCT FROM iss.color_id
                )
                SELECT s.code AS "supplierCode", s.name AS "supplierName",
                       g.code AS "goodsCode", g.name AS "goodsName", COALESCE(c.name,'') AS "color",
                       m.prev_stock AS "prevStock",
                       COALESCE(m.iss_nos,'') AS "issueBillNo", m.iss_date AS "issueDate", m.iss_qty AS "issueQty",
                       m.loss_allowed AS "lossAllowed",
                       COALESCE(m.rcv_nos,'') AS "receiptBillNo", m.rcv_date AS "receiptDate", m.rcv_qty AS "receiptQty",
                       (m.prev_stock + m.iss_qty - m.loss_allowed - m.rcv_qty) AS "balance",
                       m.process_price AS "processPrice",
                       ROUND(m.rcv_qty * COALESCE(m.process_price,0), 2) AS "processAmount",
                       m.material_price AS "materialPrice",
                       ROUND((m.prev_stock + m.iss_qty - m.loss_allowed - m.rcv_qty) * COALESCE(m.material_price,0), 2) AS "materialAmount",
                       s.name AS party_name, s.code AS party_code
                FROM merged m
                JOIN suppliers s ON s.id = m.supplier_id
                JOIN goods g ON g.id = m.goods_id
                LEFT JOIN colors c ON c.id = m.color_id
                WHERE (m.prev_stock <> 0 OR m.iss_qty <> 0 OR m.rcv_qty <> 0)
                """;
        return runPaged(cols, core, "t.\"supplierName\", t.\"goodsCode\"", keyword, from, to, page, size,
                Map.of("lossRate", lossRate == null ? new BigDecimal("0.03") : lossRate));
    }

    // ======================== 附件 2 · 供应商对账单 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse supplierStatement(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "送货日期"),
                ReportColumn.text("goodsCode", "物料编码", 120),
                ReportColumn.text("goodsName", "物料名称", 220),
                ReportColumn.text("unit", "单位", 70),
                ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "含税单价"),
                ReportColumn.money("amount", "含税金额"),
                ReportColumn.text("remark", "备注", 170));
        String core = """
                SELECT * FROM (
                    SELECT i.bill_date AS bill_date, g.code AS goods_code, g.name AS goods_name,
                           COALESCE(u.name,'') AS unit_name, i.qty AS qty, i.price AS price,
                           i.amount_original AS amount, d.bill_no AS remark,
                           s.name AS party_name, s.code AS party_code, d.supplier_id AS party_id
                    FROM purchase_receipt_items i
                    JOIN purchase_receipts d ON d.id = i.receipt_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN suppliers s ON s.id = d.supplier_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    UNION ALL
                    SELECT i.bill_date, g.code, g.name,
                           COALESCE(u.name,''), -i.qty, i.price,
                           -i.amount_original, d.bill_no || '（退货）',
                           s.name, s.code, d.supplier_id
                    FROM purchase_return_items i
                    JOIN purchase_returns d ON d.id = i.return_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN suppliers s ON s.id = d.supplier_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                ) t
                """;
        return runPaged(cols, core, "t.bill_date, t.goods_code", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 4 · 其他应收款对账单（铜材加工按重量） ========================

    /** 其他应收款对账单（铜材加工按重量）：委外进仓(进仓重量)/发料(发出重量、数量)逐行流水，损耗 0.5% 按进仓重量，结余按 供应商+货品+颜色 分区滚动累计（含期初）。 */
    @Transactional(readOnly = true)
    public ReportTableResponse otherReceivableStatement(String keyword, LocalDate from, LocalDate to,
                                                        int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "日期"),
                ReportColumn.text("goodsName", "产品名称", 200),
                ReportColumn.text("spec", "规格", 120),
                ReportColumn.number("inWeight", "进仓重量(KG)"),
                ReportColumn.number("outWeight", "发出重量(KG)"),
                ReportColumn.number("loss", "损耗0.5%"),
                ReportColumn.number("balance", "本月结余(KG)"),
                ReportColumn.number("outQty", "发出数量(PCS)"),
                ReportColumn.money("price", "加工单价"),
                ReportColumn.money("processAmount", "加工货款"),
                ReportColumn.text("billNo", "单号", 150));
        String core = """
                WITH flows AS (
                    SELECT i.goods_id, i.color_id, i.bill_date, i.bill_no,
                           COALESCE(i.weight, 0) AS in_weight, 0::numeric AS out_weight,
                           0::numeric AS out_qty, NULL::numeric AS price,
                           d.supplier_id
                    FROM subcontract_receipt_items i
                    JOIN subcontract_receipts d ON d.id = i.receipt_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                    UNION ALL
                    SELECT i.goods_id, i.color_id, i.bill_date, i.bill_no,
                           0::numeric, COALESCE(i.weight, 0),
                           i.qty, NULLIF(i.price, 0),
                           d.supplier_id
                    FROM subcontract_material_issue_items i
                    JOIN subcontract_material_issues d ON d.id = i.issue_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                ),
                prev AS (
                    SELECT goods_id, color_id, supplier_id,
                           SUM(in_weight - out_weight - in_weight * 0.005) AS prev_balance
                    FROM flows WHERE bill_date < :from
                    GROUP BY goods_id, color_id, supplier_id
                ),
                period AS (
                    SELECT f.*, ROUND(f.in_weight * 0.005, 3) AS loss
                    FROM flows f
                    WHERE f.bill_date BETWEEN :from AND :to
                      AND (f.in_weight <> 0 OR f.out_weight <> 0 OR f.out_qty <> 0)
                )
                SELECT p.bill_date AS "billDate", g.name AS "goodsName", COALESCE(g.spec, g.model, '') AS "spec",
                       p.in_weight AS "inWeight", p.out_weight AS "outWeight", p.loss AS "loss",
                       ROUND(COALESCE(pv.prev_balance,0)
                           + SUM(p.in_weight - p.out_weight - p.loss) OVER (
                               PARTITION BY p.supplier_id, p.goods_id, p.color_id
                               ORDER BY p.bill_date, p.bill_no), 3) AS "balance",
                       p.out_qty AS "outQty", p.price AS "price",
                       ROUND(p.out_qty * COALESCE(p.price,0), 2) AS "processAmount",
                       p.bill_no AS "billNo",
                       s.name AS party_name, s.code AS party_code
                FROM period p
                LEFT JOIN prev pv ON pv.goods_id = p.goods_id AND pv.color_id IS NOT DISTINCT FROM p.color_id
                                 AND pv.supplier_id = p.supplier_id
                JOIN goods g ON g.id = p.goods_id
                LEFT JOIN suppliers s ON s.id = p.supplier_id
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\"", keyword, from, to, page, size, Map.of());
    }

    // ======================== 附件 5 · 应收账款客户对账单 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse clientStatement(String keyword, LocalDate from, LocalDate to, int page, int size) {
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("goodsName", "货品名称", 220),
                ReportColumn.text("color", "颜色", 110),
                ReportColumn.text("unit", "单位", 70),
                ReportColumn.number("qty", "数量"),
                ReportColumn.money("price", "含税单价"),
                ReportColumn.money("amount", "含税金额"),
                ReportColumn.text("remark", "备注", 170));
        String core = """
                SELECT * FROM (
                    SELECT i.bill_date AS bill_date, g.name AS goods_name,
                           COALESCE(c.name,'') AS color_name, COALESCE(u.name,'') AS unit_name,
                           i.qty AS qty, i.price AS price, i.amount_original AS amount,
                           d.bill_no AS remark, cl.name AS party_name, cl.code AS party_code
                    FROM sales_shipment_items i
                    JOIN sales_shipments d ON d.id = i.shipment_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN colors c ON c.id = i.color_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN clients cl ON cl.id = d.client_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    UNION ALL
                    SELECT i.bill_date, g.name,
                           COALESCE(c.name,''), COALESCE(u.name,''),
                           -i.qty, i.price, -i.amount_original,
                           d.bill_no || '（退货）', cl.name, cl.code
                    FROM sales_return_items i
                    JOIN sales_returns d ON d.id = i.return_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN colors c ON c.id = i.color_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN clients cl ON cl.id = d.client_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                ) t
                """;
        return runPaged(cols, core, "t.bill_date, t.goods_name", keyword, from, to, page, size, Map.of());
    }

    // ======================== 通用执行器（镜像 FinanceReportService.executeRawPaged） ========================

    /** 原生 SQL 分页执行器。core 末尾必须输出 party_name/party_code 两列（keyword 过滤往来单位；
     *  包装为子查询 t 后行映射按位置取前 N 列，尾部 party 列不进结果）。 */
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
