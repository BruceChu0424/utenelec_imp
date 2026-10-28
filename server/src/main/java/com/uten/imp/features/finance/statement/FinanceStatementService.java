package com.uten.imp.features.finance.statement;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.TaskKeywordSearch;

import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.features.finance.report.FinanceProjectedReportTable;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import jakarta.persistence.EntityManager;
import com.uten.imp.common.report.ReportReadPlan;
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
 *       {@link #subcontractStatement}。按 委外商+货品+颜色+原数量单位 保留完整物理组：期初=累计发料−累计损耗−累计进仓；
 *       本月入库=委外发料（材料单号/日期/数量合计）；允许损耗=入库×损耗率(默认 3%，可传 5%)；
 *       本月出货=委外进仓（入库单号/日期/数量合计）；结存=期初+入库−损耗−出货；
 *       加工金额按进仓原币别分别出表，用本币别计价数量及同币别单位截至期末的最近已知价；合法零价保留。
 *       各币别行的整组库存是重复上下文，不累计。发料没有权威材料价币种，材料价/金额保持未知。</li>
 *   <li><b>供应商对账单</b>（附件 2）：{@link #supplierStatement}。采购收货行 + 采购退货行(负数)，
 *       列：送货日期/物料编码/物料名称/单位/数量/含税单价/含税金额/备注(单号)。</li>
 *   <li><b>其他应收款对账单</b>（附件 4 · 铜材加工按重量）：{@link #otherReceivableStatement}。
 *       委外发料(发出重量/数量)+委外进仓(进仓重量) 逐行流水，损耗 0.5% 按进仓重量，
 *       结余=逐行滚动(含期初)；发料加工价无权威币种，相关价款不猜零或人民币。</li>
 *   <li><b>应收账款客户对账单</b>（附件 5）：{@link #clientStatement}。销售出货行 + 销售退货行(负数)，
 *       列：开单日期/货品名称/颜色/单位/数量/含税单价/含税金额/备注(单号)。</li>
 * </ul>
 *
 * <p>口径说明：只取 status=1（已审核）单据，红冲(-1)/草稿不进表；keyword 按词匹配往来单位、可见货品与单号文本；
 * 日期范围默认上月今日..今日（前端通用页），对账按月选起止即可。
 * 数据局限：发料行 order_item_id 老库未填（全 NULL），材料↔成品按 货品+委外商 直接对应
 * （抽样核实发料行货品即加工件本身，如 80B 外框/金本铜粒）。</p>
 */
@Service
@RequiredArgsConstructor
public class FinanceStatementService {

    private final EntityManager em;
    private final com.uten.imp.features.finance.FinanceDocumentAccessPolicy access;

    // ======================== 附件 1 · 委外加工对账单（=采购外放加工对账单） ========================

    /** Physical groups precede currency price rows; a currency filter never recomputes their stock context. */
    @Transactional(readOnly = true)
    public ReportTableResponse subcontractStatement(String keyword, LocalDate from, LocalDate to,
                                                    BigDecimal lossRate, int page, int size) {
        return subcontractStatement(keyword,from,to,lossRate,page,size,FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly = true)
    public ReportTableResponse subcontractStatement(String keyword,LocalDate from,LocalDate to,BigDecimal lossRate,
            int page,int size,FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = List.of(
                ReportColumn.text("supplierCode", "供应商编号", 110),
                ReportColumn.text("supplierName", "委外商", 150),
                ReportColumn.text("goodsCode", "物料编码", 110),
                ReportColumn.text("goodsName", "品名及规格", 200),
                ReportColumn.text("color", "颜色", 100),
                ReportColumn.number("prevStock", "整组期初库存").withUnitKey("unit"),
                ReportColumn.text("issueBillNo", "材料单号", 150),
                ReportColumn.date("issueDate", "入库日期"),
                ReportColumn.number("issueQty", "整组入库数量").withUnitKey("unit"),
                ReportColumn.number("lossAllowed", "整组允许损耗").withUnitKey("unit"),
                ReportColumn.text("receiptBillNo", "入库单号", 150),
                ReportColumn.date("receiptDate", "出货日期"),
                ReportColumn.number("receiptQty", "整组出货数量").withUnitKey("unit"),
                ReportColumn.number("balance", "整组结存").withUnitKey("unit"),
                ReportColumn.money("processPrice", "加工单价含税").withUnitKey("currencyCode"),
                ReportColumn.money("processAmount", "本币别加工金额").withUnitKey("currencyCode"),
                ReportColumn.money("materialPrice", "材料款单价（待核验）"),
                ReportColumn.money("materialAmount", "材料款金额（待核验）"),
                ReportColumn.text("unit","数量单位",90),ReportColumn.text("currencyCode","加工币别",90),
                ReportColumn.number("processQty","本币别计价数量").withUnitKey("unit"),
                ReportColumn.text("__unitId",""),ReportColumn.text("__currencyId",""),
                ReportColumn.text("__partyName",""),ReportColumn.text("__partyCode",""),
                ReportColumn.text("__supplierId",""),ReportColumn.text("__goodsId",""),ReportColumn.text("__colorId",""),
                ReportColumn.text("__physicalGroupKey",""));
        // Historical NULL trading units stay unknown. A current master unit,
        // an in-use predicate, and a default rate do not prove an old row's unit.
        // Only the source item's persisted unit_id is used for numeric grouping.
        // Rows without that evidence keep their bill numbers and dates, while
        // grouped quantities/prices stay unknown. No master-unit repair,
        // conversion, write-back, or source-document alteration occurs here.
        String core = """
                WITH issue_rows AS (
                    SELECT d.supplier_id,i.goods_id,i.color_id,
                           """+com.uten.imp.common.report.ReportQuantityUnits.transactionUnit("i")+"""
                           AS unit_id,
                           i.qty,i.wasted_qty,i.bill_date,i.bill_no
                    FROM subcontract_material_issue_items i
                    JOIN subcontract_material_issues d ON d.id=i.issue_id
                    JOIN goods ON goods.id=i.goods_id
                    WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false AND i.bill_date<=:to
                ), receipt_rows AS (
                    SELECT d.supplier_id,d.currency_id,i.goods_id,i.color_id,
                           """+com.uten.imp.common.report.ReportQuantityUnits.transactionUnit("i")+"""
                           AS unit_id,
                           i.qty,i.price,i.bill_date,i.bill_no,i.id
                    FROM subcontract_receipt_items i JOIN subcontract_receipts d ON d.id=i.receipt_id
                    JOIN goods ON goods.id=i.goods_id
                    WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false AND i.bill_date<=:to
                ), iss AS (
                    SELECT i.supplier_id,i.goods_id,i.color_id,i.unit_id,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date<:from THEN i.qty ELSE 0 END) END AS prior_qty,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date<:from THEN COALESCE(i.wasted_qty,0) ELSE 0 END) END AS prior_waste,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.qty ELSE 0 END) END AS m_qty,
                           STRING_AGG(DISTINCT CASE WHEN i.unit_id IS NULL OR i.bill_date BETWEEN :from AND :to THEN i.bill_no END,'、') AS m_nos,
                           MAX(CASE WHEN i.unit_id IS NULL OR i.bill_date BETWEEN :from AND :to THEN i.bill_date END) AS m_date
                    FROM issue_rows i GROUP BY i.supplier_id,i.goods_id,i.color_id,i.unit_id
                ), rcv AS (
                    SELECT i.supplier_id,i.goods_id,i.color_id,i.unit_id,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date<:from THEN i.qty ELSE 0 END) END AS prior_qty,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.qty ELSE 0 END) END AS m_qty,
                           STRING_AGG(DISTINCT CASE WHEN i.unit_id IS NULL OR i.bill_date BETWEEN :from AND :to THEN i.bill_no END,'、') AS m_nos,
                           MAX(CASE WHEN i.unit_id IS NULL OR i.bill_date BETWEEN :from AND :to THEN i.bill_date END) AS m_date
                    FROM receipt_rows i GROUP BY i.supplier_id,i.goods_id,i.color_id,i.unit_id
                ), prices AS (
                    SELECT i.supplier_id,i.goods_id,i.color_id,i.unit_id,i.currency_id,
                           CASE WHEN i.unit_id IS NOT NULL THEN SUM(CASE WHEN i.bill_date BETWEEN :from AND :to THEN i.qty ELSE 0 END) END AS process_qty,
                           CASE WHEN i.unit_id IS NOT NULL THEN (ARRAY_AGG(i.price ORDER BY i.bill_date DESC,i.id DESC) FILTER(WHERE i.price IS NOT NULL))[1] END AS process_price
                    FROM receipt_rows i GROUP BY i.supplier_id,i.goods_id,i.color_id,i.unit_id,i.currency_id
                ), merged AS (
                    SELECT COALESCE(iss.supplier_id,rcv.supplier_id) AS supplier_id,
                           COALESCE(iss.goods_id,rcv.goods_id) AS goods_id,
                           COALESCE(iss.color_id,rcv.color_id) AS color_id,COALESCE(iss.unit_id,rcv.unit_id) AS unit_id,
                           CASE WHEN COALESCE(iss.unit_id,rcv.unit_id) IS NOT NULL THEN COALESCE(iss.prior_qty,0)-COALESCE(iss.prior_waste,0)-COALESCE(rcv.prior_qty,0) END AS prev_stock,
                           iss.m_nos AS iss_nos,iss.m_date AS iss_date,
                           CASE WHEN COALESCE(iss.unit_id,rcv.unit_id) IS NOT NULL THEN COALESCE(iss.m_qty,0) END AS iss_qty,
                           CASE WHEN COALESCE(iss.unit_id,rcv.unit_id) IS NOT NULL THEN ROUND(COALESCE(iss.m_qty,0)*:lossRate,2) END AS loss_allowed,
                           rcv.m_nos AS rcv_nos,rcv.m_date AS rcv_date,
                           CASE WHEN COALESCE(iss.unit_id,rcv.unit_id) IS NOT NULL THEN COALESCE(rcv.m_qty,0) END AS rcv_qty
                    FROM iss FULL OUTER JOIN rcv ON rcv.supplier_id=iss.supplier_id AND rcv.goods_id=iss.goods_id
                        AND rcv.color_id IS NOT DISTINCT FROM iss.color_id AND rcv.unit_id IS NOT DISTINCT FROM iss.unit_id
                )
                SELECT s.code AS "supplierCode",s.name AS "supplierName",g.code AS "goodsCode",g.name AS "goodsName",COALESCE(c.name,'') AS "color",
                       m.prev_stock AS "prevStock",COALESCE(m.iss_nos,'') AS "issueBillNo",m.iss_date AS "issueDate",m.iss_qty AS "issueQty",
                       m.loss_allowed AS "lossAllowed",COALESCE(m.rcv_nos,'') AS "receiptBillNo",m.rcv_date AS "receiptDate",m.rcv_qty AS "receiptQty",
                       (m.prev_stock+m.iss_qty-m.loss_allowed-m.rcv_qty) AS "balance",
                       CASE WHEN price.currency_id IS NOT NULL THEN price.process_price END AS "processPrice",
                       CASE WHEN price.currency_id IS NOT NULL THEN ROUND(price.process_qty*price.process_price,2) END AS "processAmount",
                       NULL::numeric AS "materialPrice",NULL::numeric AS "materialAmount",unit.name AS "unit",
                       """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency")+"""
                       AS "currencyCode",price.process_qty AS "processQty",m.unit_id,price.currency_id,
                       s.name AS party_name,s.code AS party_code,m.supplier_id AS "__supplierId",m.goods_id AS "__goodsId",m.color_id AS "__colorId",
                       concat_ws(':',m.supplier_id,m.goods_id,COALESCE(m.color_id::text,'UNKNOWN_COLOR'),COALESCE(m.unit_id::text,'UNKNOWN_UNIT')) AS "__physicalGroupKey"
                FROM merged m JOIN suppliers s ON s.id=m.supplier_id JOIN goods g ON g.id=m.goods_id
                LEFT JOIN colors c ON c.id=m.color_id LEFT JOIN units unit ON unit.id=m.unit_id
                LEFT JOIN prices price ON price.supplier_id=m.supplier_id AND price.goods_id=m.goods_id
                    AND price.color_id IS NOT DISTINCT FROM m.color_id AND price.unit_id IS NOT DISTINCT FROM m.unit_id
                LEFT JOIN currencies currency ON currency.id=price.currency_id
                WHERE m.unit_id IS NULL OR m.prev_stock<>0 OR m.iss_qty<>0 OR m.rcv_qty<>0
                """;
        return runPaged(cols, core, "t.\"supplierName\", t.\"goodsCode\", t.\"__supplierId\", t.\"__goodsId\", t.\"__colorId\" NULLS FIRST,t.unit_id NULLS FIRST,t.currency_id NULLS FIRST", keyword, from, to, page, size,
                Map.of("lossRate", lossRate == null ? new BigDecimal("0.03") : lossRate),false,options,java.util.Set.of("materialPrice","materialAmount"),
                "t.\"goodsName\"", "t.\"goodsCode\"", "t.\"color\"", "t.\"issueBillNo\"", "t.\"receiptBillNo\"");
    }

    // ======================== 附件 2 · 供应商对账单 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse supplierStatement(String keyword, LocalDate from, LocalDate to, int page, int size) {
        return supplierStatement(keyword,from,to,page,size,FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly = true)
    public ReportTableResponse supplierStatement(String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "送货日期"),
                ReportColumn.text("goodsCode", "物料编码", 120),
                ReportColumn.text("goodsName", "物料名称", 220),
                ReportColumn.text("unit", "单位", 70),
                ReportColumn.number("qty", "数量").withUnitKey("unit"),
                ReportColumn.money("price", "含税单价").withUnitKey("currencyCode"),
                ReportColumn.money("amount", "含税金额").withUnitKey("currencyCode"),
                ReportColumn.text("remark", "备注", 170),ReportColumn.text("currencyCode","币别",90),
                ReportColumn.text("__currencyId",""),ReportColumn.text("__unitId",""),
                ReportColumn.text("__partyName",""),ReportColumn.text("__partyCode",""),ReportColumn.text("__partyId",""),
                ReportColumn.text("__sourceType",""),ReportColumn.text("__sourceId",""));
        String core = """
                SELECT * FROM (
                    SELECT i.bill_date AS bill_date, g.code AS goods_code, g.name AS goods_name,
                           COALESCE(u.name,'') AS unit_name, i.qty AS qty, i.price AS price,
                           i.amount_original AS amount, d.bill_no AS remark,
                           """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency")+"""
                           AS currency_code,d.currency_id,i.unit_id,
                           s.name AS party_name, s.code AS party_code, d.supplier_id AS party_id,
                           'PURCHASE_RECEIPT'::text AS source_type, i.id AS source_id
                    FROM purchase_receipt_items i
                    JOIN purchase_receipts d ON d.id = i.receipt_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN suppliers s ON s.id = d.supplier_id
                    LEFT JOIN currencies currency ON currency.id=d.currency_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    UNION ALL
                    SELECT i.bill_date, g.code, g.name,
                           COALESCE(u.name,''), -i.qty, i.price,
                           -i.amount_original, d.bill_no || '(退货)',
                           """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency")+"""
                           ,d.currency_id,i.unit_id,
                           s.name, s.code, d.supplier_id, 'PURCHASE_RETURN'::text, i.id
                    FROM purchase_return_items i
                    JOIN purchase_returns d ON d.id = i.return_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN suppliers s ON s.id = d.supplier_id
                    LEFT JOIN currencies currency ON currency.id=d.currency_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                ) t
                """;
        return runPaged(cols, core, "t.bill_date, t.goods_code, t.source_type, t.source_id", keyword, from, to, page, size, Map.of(),false,options,
                "t.goods_name", "t.goods_code", "t.unit_name", "t.remark");
    }

    // ======================== 附件 4 · 其他应收款对账单（铜材加工按重量） ========================

    /** Copper material flow keeps its complete KG timeline; unproved material currency/price stays unknown. */
    @Transactional(readOnly = true)
    public ReportTableResponse otherReceivableStatement(String keyword, LocalDate from, LocalDate to,
                                                        int page, int size) {
        return otherReceivableStatement(keyword,from,to,page,size,FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly = true)
    public ReportTableResponse otherReceivableStatement(String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "日期"),
                ReportColumn.text("goodsName", "产品名称", 200),
                ReportColumn.text("spec", "规格", 120),
                ReportColumn.number("inWeight", "进仓重量(KG)"),
                ReportColumn.number("outWeight", "发出重量(KG)"),
                ReportColumn.number("loss", "损耗0.5%"),
                ReportColumn.number("balance", "本月结余(KG)"),
                ReportColumn.number("outQty", "发出数量").withUnitKey("unit"),
                ReportColumn.money("price", "加工单价（待核验）"),
                ReportColumn.money("processAmount", "加工货款（待核验）"),
                ReportColumn.text("billNo", "单号", 150),ReportColumn.text("unit","数量单位",90),
                ReportColumn.text("__partyName",""),ReportColumn.text("__partyCode",""),
                ReportColumn.text("__sourceType",""),ReportColumn.text("__sourceId",""),ReportColumn.text("__unitId",""));
        String core = """
                WITH flows AS (
                    SELECT i.goods_id,i.color_id,i.unit_id,i.bill_date,i.bill_no,
                           i.weight AS in_weight,0::numeric AS out_weight,0::numeric AS out_qty,NULL::numeric AS price,
                           d.supplier_id,'SUBCONTRACT_RECEIPT'::text AS source_type,i.id AS source_id
                    FROM subcontract_receipt_items i JOIN subcontract_receipts d ON d.id=i.receipt_id
                    WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false
                    UNION ALL
                    SELECT i.goods_id,i.color_id,i.unit_id,i.bill_date,i.bill_no,0::numeric,i.weight,i.qty,NULL::numeric,
                           d.supplier_id,'SUBCONTRACT_ISSUE'::text,i.id
                    FROM subcontract_material_issue_items i JOIN subcontract_material_issues d ON d.id=i.issue_id
                    WHERE d.status=1 AND d.is_deleted=false AND i.is_deleted=false
                ), prev AS (
                    SELECT goods_id,color_id,supplier_id,SUM(in_weight-out_weight-in_weight*0.005) AS prev_balance,
                           COUNT(*) FILTER(WHERE in_weight IS NULL OR out_weight IS NULL) AS unknown_count
                    FROM flows WHERE bill_date<:from GROUP BY goods_id,color_id,supplier_id
                ), period AS (
                    SELECT f.*,ROUND(f.in_weight*0.005,3) AS loss FROM flows f
                    WHERE f.bill_date BETWEEN :from AND :to
                      AND (f.in_weight IS NULL OR f.out_weight IS NULL OR f.in_weight<>0 OR f.out_weight<>0 OR f.out_qty<>0)
                )
                SELECT p.bill_date AS "billDate",g.name AS "goodsName",COALESCE(g.spec,g.model,'') AS "spec",
                       p.in_weight AS "inWeight",p.out_weight AS "outWeight",p.loss AS "loss",
                       CASE WHEN COALESCE(pv.unknown_count,0)
                           + COUNT(*) FILTER(WHERE p.in_weight IS NULL OR p.out_weight IS NULL) OVER material_timeline>0 THEN NULL
                           ELSE ROUND(COALESCE(pv.prev_balance,0)+SUM(p.in_weight-p.out_weight-p.loss) OVER material_timeline,3) END AS "balance",
                       p.out_qty AS "outQty",p.price AS "price",NULL::numeric AS "processAmount",p.bill_no AS "billNo",unit.name AS "unit",
                       s.name AS party_name,s.code AS party_code,p.source_type,p.source_id,p.unit_id
                FROM period p LEFT JOIN prev pv ON pv.goods_id=p.goods_id AND pv.color_id IS NOT DISTINCT FROM p.color_id AND pv.supplier_id=p.supplier_id
                JOIN goods g ON g.id=p.goods_id LEFT JOIN suppliers s ON s.id=p.supplier_id LEFT JOIN units unit ON unit.id=p.unit_id
                WINDOW material_timeline AS (PARTITION BY p.supplier_id,p.goods_id,p.color_id ORDER BY p.bill_date,p.bill_no,p.source_type,p.source_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                """;
        return runPaged(cols, core, "t.\"billDate\", t.\"billNo\", t.source_type, t.source_id", keyword, from, to, page, size, Map.of(),true,options,java.util.Set.of("price","processAmount"),
                "t.\"goodsName\"", "t.\"spec\"", "t.\"billNo\"");
    }

    // ======================== 附件 5 · 应收账款客户对账单 ========================

    @Transactional(readOnly = true)
    public ReportTableResponse clientStatement(String keyword, LocalDate from, LocalDate to, int page, int size) {
        return clientStatement(keyword,from,to,page,size,FinanceReportColumnOptions.NONE);
    }
    @Transactional(readOnly = true)
    public ReportTableResponse clientStatement(String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options) {
        com.uten.imp.features.finance.FinanceCompanyReportAccess.require(access);
        List<ReportColumn> cols = List.of(
                ReportColumn.date("billDate", "开单日期"),
                ReportColumn.text("goodsName", "货品名称", 220),
                ReportColumn.text("color", "颜色", 110),
                ReportColumn.text("unit", "单位", 70),
                ReportColumn.number("qty", "数量").withUnitKey("unit"),
                ReportColumn.money("price", "含税单价").withUnitKey("currencyCode"),
                ReportColumn.money("amount", "含税金额").withUnitKey("currencyCode"),
                ReportColumn.text("remark", "备注", 170),ReportColumn.text("currencyCode","币别",90),
                ReportColumn.text("__currencyId",""),ReportColumn.text("__unitId",""),
                ReportColumn.text("__partyName",""),ReportColumn.text("__partyCode",""),
                ReportColumn.text("__sourceType",""),ReportColumn.text("__sourceId",""));
        String core = """
                SELECT * FROM (
                    SELECT i.bill_date AS bill_date, g.name AS goods_name,
                           COALESCE(c.name,'') AS color_name, COALESCE(u.name,'') AS unit_name,
                           i.qty AS qty, i.price AS price, i.amount_original AS amount,
                           d.bill_no AS remark,
                           """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency")+"""
                           AS currency_code,d.currency_id,i.unit_id,cl.name AS party_name, cl.code AS party_code,
                           'SALES_SHIPMENT'::text AS source_type, i.id AS source_id
                    FROM sales_shipment_items i
                    JOIN sales_shipments d ON d.id = i.shipment_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN colors c ON c.id = i.color_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN clients cl ON cl.id = d.client_id
                    LEFT JOIN currencies currency ON currency.id=d.currency_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                    UNION ALL
                    SELECT i.bill_date, g.name,
                           COALESCE(c.name,''), COALESCE(u.name,''),
                           -i.qty, i.price, -i.amount_original,
                           d.bill_no || '(退货)',
                           """+com.uten.imp.common.finance.CurrencyDisplayLabel.sql("currency")+"""
                           ,d.currency_id,i.unit_id,cl.name,cl.code,'SALES_RETURN'::text,i.id
                    FROM sales_return_items i
                    JOIN sales_returns d ON d.id = i.return_id
                    LEFT JOIN goods g ON g.id = i.goods_id
                    LEFT JOIN colors c ON c.id = i.color_id
                    LEFT JOIN units u ON u.id = i.unit_id
                    LEFT JOIN clients cl ON cl.id = d.client_id
                    LEFT JOIN currencies currency ON currency.id=d.currency_id
                    WHERE d.status = 1 AND d.is_deleted = false AND i.is_deleted = false
                      AND i.bill_date BETWEEN :from AND :to
                ) t
                """;
        return runPaged(cols, core, "t.bill_date, t.goods_name, t.source_type, t.source_id", keyword, from, to, page, size, Map.of(),false,options,
                "t.goods_name", "t.color_name", "t.unit_name", "t.remark");
    }

    // ======================== 通用执行器（镜像 FinanceReportService.executeRawPaged） ========================

    /** 原生 SQL 分页执行器。core 末尾必须输出 party_name/party_code 两列（与可见文本联合搜索；
     *  包装为子查询 t 后行映射按位置取前 N 列，尾部 party 列不进结果）。 */
    private ReportTableResponse runPaged(List<ReportColumn> cols, String coreSql, String orderBy,
                                         String keyword, LocalDate from, LocalDate to,
                                         int page, int size, Map<String, Object> extraParams,
                                         boolean chronological,FinanceReportColumnOptions options, String... textFields) {
        return runPaged(cols,coreSql,orderBy,keyword,from,to,page,size,extraParams,chronological,options,java.util.Set.of(),textFields);
    }
    private ReportTableResponse runPaged(List<ReportColumn> cols,String coreSql,String orderBy,String keyword,LocalDate from,LocalDate to,
            int page,int size,Map<String,Object> extraParams,boolean chronological,FinanceReportColumnOptions options,
            java.util.Set<String> nonQueryableKeys,String... textFields) {
        List<String> fields = new ArrayList<>(List.of("t.party_name", "t.party_code"));
        fields.addAll(List.of(textFields));
        boolean searching = !KeywordSearch.terms(keyword).isEmpty();
        String where = searching ? "WHERE " + TaskKeywordSearch.conditionParameter("kw", fields.toArray(String[]::new)) : "WHERE TRUE";
        // Running balances are computed inside coreSql and retain their timeline.
        String rank = searching && !chronological ? TaskKeywordSearch.rankNamesFirstParameter("kw",
                new String[]{textFields[0]},new String[]{},fields.toArray(String[]::new)) + ", " : "";
        String projected="SELECT t.*,ROW_NUMBER() OVER (ORDER BY "+rank+orderBy+") AS \"__headerOrdinal\" FROM ("+coreSql+") t "+where;
        return FinanceProjectedReportTable.query(em,cols,FinanceProjectedReportTable.aliasProjection(projected,cols,"statement_source","__headerOrdinal"),
                query->bindRaw(query,keyword,from,to,extraParams),"report.\"__headerOrdinal\"",options.filters(),java.util.Set.of(),
                page,size,options.sort(),options.order(),chronological,List.of(),nonQueryableKeys);
    }

    private static void bindRaw(Query q, String keyword, LocalDate from, LocalDate to, Map<String, Object> extra) {
        if (!KeywordSearch.terms(keyword).isEmpty()) q.setParameter("kw", KeywordSearch.phrase(keyword));
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
