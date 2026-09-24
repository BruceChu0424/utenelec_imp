package com.uten.imp.features.master.lifecycle;

import com.uten.imp.features.master.lifecycle.MasterReferenceGuard.RefKind;

import java.util.ArrayList;
import java.util.List;

import static com.uten.imp.features.master.lifecycle.MasterEntityKind.CLIENT;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.COLOR;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.GOODS;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.MOULD;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.SUPPLIER;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.UNIT;
import static com.uten.imp.features.master.lifecycle.MasterEntityKind.WAREHOUSE;

/**
 * 主档引用目录(ADR-111)：库里每一个指向主档的列，要么在这里登记「什么条件下算还在用」，
 * 要么登记为豁免并写明为什么删除主档不影响它。
 *
 * <p>{@code MasterReferenceCatalogCoverageTest} 在真库上把「所有指向七种主档的外键列 + 按命名
 * 约定的无外键 uuid 列」与本目录逐列对账：新加一张引用主档的表而没有在这里归类，测试直接失败——
 * 「删了还在用的主档」不会因为漏登记而复发。
 *
 * <p>每条引用的 SQL 只由本类常量拼成(表名、列名、状态值都是白名单)，统一产出六列：
 * {@code (被引用的主档 id, 引用种类, 引用方 id, 给人看的标签, 标签归属人, 标签可见范围)}。
 * 可见范围是 {@code public}(仓库名、日期等不涉密标签)、{@code goods}(货品编号名称，按货品归属人)
 * 或单据模块的归属范围名(按单据归属人)；调用方看不到的标签只计数、不展示。
 */
final class MasterReferenceCatalog {

    private MasterReferenceCatalog() {
    }

    /** 一处引用：{@code table.column} 指向 {@code target} 主档；{@code sql} 产出统一六列。 */
    record Reference(MasterEntityKind target, String table, String column, RefKind kind, String sql) {
    }

    /** 豁免原因(给维护者看的归类，不进报错文案)。 */
    enum ExemptReason {
        HISTORY("流水、事件或快照：只记录已经发生过的事，主档删除后照样能查"),
        LEGACY("老系统迁移留下的只读记录，不参与新业务"),
        OWN_CONFIG("主档自己的附属设置，随主档一起失效"),
        COVERED("所属业务已由目录里另一处检查覆盖");

        private final String meaning;

        ExemptReason(String meaning) {
            this.meaning = meaning;
        }

        String meaning() { return meaning; }
    }

    record Exemption(String table, String column, ExemptReason reason, String note) {
    }

    // ---- 口径常量(只引用别名 h / a，白名单) ------------------------------------------

    private static final String LIVE = "NOT h.is_deleted AND NOT h.is_closed";
    /** 订单类：审核后仍在执行，直到结案；红冲(-1)的不算。 */
    static final String ORDER_OPEN = LIVE + " AND h.status <> -1";
    static final String PLAN_OPEN = ORDER_OPEN + " AND NOT h.is_canceled";
    /** 过账类：审核即过账完成，只有草稿(0)算在办。 */
    static final String DRAFT_OPEN = LIVE + " AND h.status = 0";
    /** 出货单审核即已出库(V632 财务闸)：未审核且没作废/冲回的才算在办。 */
    static final String SHIPMENT_OPEN = DRAFT_OPEN
            + " AND COALESCE(h.warehouse_work_status, '') NOT IN ('CANCELLED', 'REVERSED')";
    static final String DAILY_REPORT_OPEN = DRAFT_OPEN + " AND NOT h.is_canceled";
    /** 出入库单：草稿，或领料部分出库(issue_status=1)尚未出完。 */
    static final String STOCK_DOC_OPEN = ORDER_OPEN + " AND (h.status = 0 OR COALESCE(h.issue_status, 0) = 1)";
    static final String ANALYSIS_OPEN = "NOT a.is_deleted AND a.status IN ('ACTIVE', 'PARTIALLY_PLANNED')";

    private static final String GOODS_LABEL = "COALESCE(g.code, '') || ' ' || COALESCE(g.name, '')";
    private static final String PARENT_LABEL = "COALESCE(p.code, '') || ' ' || COALESCE(p.name, '')";
    private static final String ANALYSIS_LABEL = "to_char(a.created_at, 'YYYY-MM-DD') || ' 的物料分析'";
    private static final String QTY = "CAST(trim_scale(%s) AS text)";
    private static final String TARGETS = "IN (SELECT id FROM targets)";

    /** 单据表头：表、引用种类、在办口径、归属列、归属范围名(同各模块 DocumentAccessPolicy)。 */
    private record Doc(String table, RefKind kind, String open, String owner, String scope) {
    }

    private static final Doc SALES_ORDER = new Doc("sales_orders", RefKind.SALES_ORDER, ORDER_OPEN,
            "owner_employee_id", "sales");
    private static final Doc SALES_QUOTE = new Doc("sales_quotes", RefKind.SALES_QUOTE, DRAFT_OPEN,
            "maker_id", "sales");
    private static final Doc SHIPMENT = new Doc("sales_shipments", RefKind.SHIPMENT, SHIPMENT_OPEN,
            "owner_employee_id", "sales");
    private static final Doc SALES_RETURN = new Doc("sales_returns", RefKind.SALES_RETURN, DRAFT_OPEN,
            "owner_employee_id", "sales");
    private static final Doc SALES_OTHER_SHIPMENT = new Doc("sales_other_shipments",
            RefKind.SALES_OTHER_SHIPMENT, DRAFT_OPEN, "owner_employee_id", "sales");
    private static final Doc PURCHASE_REQUEST = new Doc("purchase_requests", RefKind.PURCHASE_REQUEST, ORDER_OPEN,
            "maker_id", "purchase");
    private static final Doc PURCHASE_ORDER = new Doc("purchase_orders", RefKind.PURCHASE_ORDER, ORDER_OPEN,
            "maker_id", "purchase");
    private static final Doc PURCHASE_RECEIPT = new Doc("purchase_receipts", RefKind.PURCHASE_RECEIPT, DRAFT_OPEN,
            "maker_id", "purchase");
    private static final Doc PURCHASE_RETURN = new Doc("purchase_returns", RefKind.PURCHASE_RETURN, DRAFT_OPEN,
            "maker_id", "purchase");
    private static final Doc SUBCONTRACT_APPLICATION = new Doc("subcontract_applications",
            RefKind.SUBCONTRACT_APPLICATION, ORDER_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_INQUIRY = new Doc("subcontract_inquiries", RefKind.SUBCONTRACT_INQUIRY,
            DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_ORDER = new Doc("subcontract_orders", RefKind.SUBCONTRACT_ORDER,
            ORDER_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_RECEIPT = new Doc("subcontract_receipts", RefKind.SUBCONTRACT_RECEIPT,
            DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_RETURN = new Doc("subcontract_returns", RefKind.SUBCONTRACT_RETURN,
            DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_WASTE = new Doc("subcontract_wastes", RefKind.SUBCONTRACT_WASTE,
            DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_MATERIAL_ISSUE = new Doc("subcontract_material_issues",
            RefKind.SUBCONTRACT_MATERIAL_ISSUE, DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc SUBCONTRACT_MATERIAL_RETURN = new Doc("subcontract_material_returns",
            RefKind.SUBCONTRACT_MATERIAL_RETURN, DRAFT_OPEN, "maker_id", "subcontract");
    private static final Doc PRODUCTION_PLAN = new Doc("production_plans", RefKind.PRODUCTION_PLAN, PLAN_OPEN,
            "maker_id", "production_plan");
    private static final Doc DAILY_REPORT = new Doc("production_daily_reports", RefKind.DAILY_REPORT,
            DAILY_REPORT_OPEN, "maker_id", "production_plan");
    private static final Doc STOCK_DOCUMENT = new Doc("stock_documents", RefKind.STOCK_DOCUMENT, STOCK_DOC_OPEN,
            "maker_id", "stock_doc");
    private static final Doc FINANCE_RECEIPT = new Doc("finance_receipts", RefKind.FINANCE_RECEIPT, DRAFT_OPEN,
            "maker_id", "finance");
    private static final Doc FINANCE_PAYMENT = new Doc("finance_payments", RefKind.FINANCE_PAYMENT, DRAFT_OPEN,
            "maker_id", "finance");

    /** 明细里指向主档的列。 */
    private record Col(MasterEntityKind target, String column) {
    }

    private static final List<Col> GCU = List.of(
            new Col(GOODS, "goods_id"), new Col(COLOR, "color_id"), new Col(UNIT, "unit_id"));

    private static final List<Reference> REFERENCES = buildReferences();
    private static final List<Exemption> EXEMPTIONS = buildExemptions();

    static List<Reference> references() {
        return REFERENCES;
    }

    static List<Reference> references(MasterEntityKind kind) {
        return REFERENCES.stream().filter(reference -> reference.target() == kind).toList();
    }

    static List<Exemption> exemptions() {
        return EXEMPTIONS;
    }

    // ---- 引用 --------------------------------------------------------------------

    private static List<Reference> buildReferences() {
        List<Reference> out = new ArrayList<>();

        // 货品主档上的列：有效货品还指着它(导入撤回时同批删除的货品除外)。
        for (String column : List.of("color_id", "default_purchase_price_color_id",
                "default_subcontract_price_color_id")) {
            out.add(goodsColumn(COLOR, column));
        }
        for (String column : List.of("unit_id", "thickness_unit_id", "m_weight_unit_id",
                "default_purchase_price_unit_id", "default_subcontract_price_unit_id")) {
            out.add(goodsColumn(UNIT, column));
        }
        out.add(goodsColumn(WAREHOUSE, "owning_warehouse_id"));
        out.add(goodsColumn(CLIENT, "client_id"));
        for (String column : List.of("default_supplier_id", "secondary_supplier_id",
                "default_purchase_price_supplier_id", "default_subcontract_price_supplier_id")) {
            out.add(goodsColumn(SUPPLIER, column));
        }
        out.add(goodsColumn(MOULD, "mould_id"));
        // 货品计量采集设置里的业务单位/实重单位：随有效货品一起算。
        for (String column : List.of("business_unit_id", "actual_weight_unit_id")) {
            out.add(new Reference(UNIT, "measurement_capture_profiles", column, RefKind.GOODS, """
                    SELECT m.%1$s, 'GOODS', CAST(g.id AS text), %2$s, g.owner_employee_id, 'goods'
                    FROM measurement_capture_profiles m JOIN goods g ON g.id = m.goods_id
                    WHERE m.%1$s %3$s AND NOT g.is_deleted
                      AND g.id NOT IN (SELECT id FROM excluded)""".formatted(column, GOODS_LABEL, TARGETS)));
        }

        // 组装清单：父件不在本批(外部引用)与在本批(内部边)分开，内部边交给不动点迭代。
        out.add(new Reference(GOODS, "goods_bom_items", "component_goods_id", RefKind.BOM_PARENT, """
                SELECT b.component_goods_id, 'BOM_PARENT', CAST(p.id AS text), %1$s, p.owner_employee_id, 'goods'
                FROM goods_bom_items b JOIN goods p ON p.id = b.goods_id
                WHERE b.component_goods_id %2$s AND NOT b.is_deleted AND NOT p.is_deleted
                  AND p.id NOT IN (SELECT id FROM targets)""".formatted(PARENT_LABEL, TARGETS)));
        out.add(new Reference(GOODS, "goods_bom_items", "component_goods_id", RefKind.BOM_INTERNAL, """
                SELECT b.component_goods_id, 'BOM_INTERNAL', CAST(p.id AS text), %1$s,
                       CAST(NULL AS uuid), 'public'
                FROM goods_bom_items b JOIN goods p ON p.id = b.goods_id
                WHERE b.component_goods_id %2$s AND NOT b.is_deleted AND NOT p.is_deleted
                  AND p.id IN (SELECT id FROM targets) AND p.id <> b.component_goods_id"""
                .formatted(PARENT_LABEL, TARGETS)));
        out.add(bomRow(COLOR, "color_id"));
        out.add(bomRow(SUPPLIER, "default_supplier_id"));

        out.add(new Reference(WAREHOUSE, "warehouses", "parent_id", RefKind.CHILD_WAREHOUSE, """
                SELECT c.parent_id, 'CHILD_WAREHOUSE', CAST(c.id AS text),
                       COALESCE(c.code, '') || ' ' || COALESCE(c.name, ''), CAST(NULL AS uuid), 'public'
                FROM warehouses c
                WHERE c.parent_id %s AND NOT c.is_deleted""".formatted(TARGETS)));
        out.add(new Reference(UNIT, "unit_measurement_profiles", "canonical_unit_id", RefKind.UNIT_PROFILE, """
                SELECT p.canonical_unit_id, 'UNIT_PROFILE', CAST(u.id AS text),
                       COALESCE(u.code, '') || ' ' || COALESCE(u.name, ''), CAST(NULL AS uuid), 'public'
                FROM unit_measurement_profiles p JOIN units u ON u.id = p.unit_id
                WHERE p.canonical_unit_id %s AND p.unit_id <> p.canonical_unit_id AND NOT u.is_deleted"""
                .formatted(TARGETS)));

        // ---- 单据明细 ----
        lines(out, SALES_ORDER, "sales_order_items", "order_id", GCU);
        lines(out, SALES_QUOTE, "sales_quote_items", "quote_id", GCU);
        lines(out, SHIPMENT, "sales_shipment_items", "shipment_id",
                with(GCU, new Col(WAREHOUSE, "warehouse_id")));
        lines(out, SALES_RETURN, "sales_return_items", "return_id", GCU);
        lines(out, SALES_OTHER_SHIPMENT, "sales_other_shipment_items", "shipment_id", GCU);
        lines(out, PURCHASE_REQUEST, "purchase_request_items", "request_id", GCU);
        lines(out, PURCHASE_ORDER, "purchase_order_items", "order_id", GCU);
        lines(out, PURCHASE_RECEIPT, "purchase_receipt_items", "receipt_id", GCU);
        lines(out, PURCHASE_RETURN, "purchase_return_items", "return_id", GCU);
        lines(out, SUBCONTRACT_APPLICATION, "subcontract_application_items", "application_id", GCU);
        lines(out, SUBCONTRACT_INQUIRY, "subcontract_inquiry_items", "inquiry_id", GCU);
        lines(out, SUBCONTRACT_ORDER, "subcontract_order_items", "order_id", GCU);
        lines(out, SUBCONTRACT_RECEIPT, "subcontract_receipt_items", "receipt_id", GCU);
        lines(out, SUBCONTRACT_RETURN, "subcontract_return_items", "return_id", GCU);
        lines(out, SUBCONTRACT_WASTE, "subcontract_waste_items", "waste_id", GCU);
        List<Col> withParent = with(GCU, new Col(GOODS, "parent_goods_id"), new Col(COLOR, "parent_color_id"));
        lines(out, SUBCONTRACT_MATERIAL_ISSUE, "subcontract_material_issue_items", "issue_id", withParent);
        lines(out, SUBCONTRACT_MATERIAL_RETURN, "subcontract_material_return_items", "material_return_id",
                withParent);
        lines(out, PRODUCTION_PLAN, "production_plan_items", "plan_id", with(GCU, new Col(GOODS, "mgoods_id")));
        lines(out, DAILY_REPORT, "production_daily_report_items", "report_id", GCU);
        lines(out, STOCK_DOCUMENT, "stock_document_items", "doc_id", GCU);
        lines(out, FINANCE_RECEIPT, "finance_receipt_lines", "receipt_id", List.of(new Col(CLIENT, "client_id")));
        lines(out, FINANCE_PAYMENT, "finance_payment_lines", "payment_id", List.of(new Col(SUPPLIER, "supplier_id")));

        // ---- 单据表头 ----
        header(out, SALES_ORDER, CLIENT, "client_id");
        header(out, SALES_QUOTE, CLIENT, "client_id");
        for (Doc doc : List.of(SHIPMENT, SALES_RETURN, SALES_OTHER_SHIPMENT)) {
            header(out, doc, CLIENT, "client_id");
            header(out, doc, WAREHOUSE, "warehouse_id");
        }
        header(out, PURCHASE_REQUEST, WAREHOUSE, "warehouse_id");
        for (Doc doc : List.of(PURCHASE_ORDER, PURCHASE_RECEIPT, PURCHASE_RETURN, SUBCONTRACT_APPLICATION,
                SUBCONTRACT_INQUIRY, SUBCONTRACT_ORDER, SUBCONTRACT_RECEIPT, SUBCONTRACT_RETURN, SUBCONTRACT_WASTE,
                SUBCONTRACT_MATERIAL_ISSUE, SUBCONTRACT_MATERIAL_RETURN, DAILY_REPORT)) {
            header(out, doc, WAREHOUSE, "warehouse_id");
            header(out, doc, SUPPLIER, "supplier_id");
        }
        header(out, STOCK_DOCUMENT, WAREHOUSE, "warehouse_id");
        header(out, STOCK_DOCUMENT, WAREHOUSE, "to_warehouse_id");
        header(out, STOCK_DOCUMENT, CLIENT, "client_id");
        header(out, STOCK_DOCUMENT, SUPPLIER, "supplier_id");
        header(out, FINANCE_RECEIPT, CLIENT, "client_id");
        header(out, FINANCE_RECEIPT, SUPPLIER, "settlement_agent_supplier_id");
        header(out, FINANCE_PAYMENT, SUPPLIER, "supplier_id");

        // ---- 库存与预留 ----
        for (Col col : List.of(new Col(GOODS, "goods_id"), new Col(COLOR, "color_id"),
                new Col(WAREHOUSE, "warehouse_id"))) {
            String label = col.target() == GOODS ? "COALESCE(w.name, w.code, '')" : GOODS_LABEL;
            String owner = col.target() == GOODS ? "CAST(NULL AS uuid)" : "g.owner_employee_id";
            String scope = col.target() == GOODS ? "public" : "goods";
            out.add(new Reference(col.target(), "stock_balances", col.column(), RefKind.STOCK, """
                    SELECT b.%1$s, 'STOCK', CAST(b.id AS text), %2$s || ' ' || %3$s, %4$s, '%5$s'
                    FROM stock_balances b
                    JOIN warehouses w ON w.id = b.warehouse_id
                    JOIN goods g ON g.id = b.goods_id
                    WHERE b.%1$s %6$s AND b.qty <> 0"""
                    .formatted(col.column(), label, QTY.formatted("b.qty"), owner, scope, TARGETS)));
            String open = "r.qty - COALESCE(r.consumed_qty, 0) - COALESCE(r.released_qty, 0)";
            String reservationLabel = col.target() == GOODS ? "COALESCE(w.name, '不限仓库')" : GOODS_LABEL;
            out.add(new Reference(col.target(), "stock_reservations", col.column(), RefKind.RESERVATION, """
                    SELECT r.%1$s, 'RESERVATION', CAST(r.id AS text), %2$s || ' ' || %3$s, %4$s, '%5$s'
                    FROM stock_reservations r
                    LEFT JOIN warehouses w ON w.id = r.warehouse_id
                    JOIN goods g ON g.id = r.goods_id
                    WHERE r.%1$s %6$s AND NOT r.is_deleted AND r.status = 0 AND %7$s > 0"""
                    .formatted(col.column(), reservationLabel, QTY.formatted(open), owner, scope, TARGETS, open)));
        }

        inFlight(out);
        finance(out);
        return List.copyOf(out);
    }

    /** 到货、检验、生产、委外、物料分析等在办流程(各自的状态口径)。 */
    private static void inFlight(List<Reference> out) {
        // 到货预期：审核后的采购/委外订单等货进门。
        String arrivalScope = "CASE e.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END";
        for (Col col : GCU) {
            out.add(new Reference(col.target(), "inbound_expectation_items", col.column(), RefKind.ARRIVAL, """
                    SELECT i.%1$s, 'ARRIVAL', CAST(e.id AS text), COALESCE(e.bill_no_snapshot, '(无单号)'),
                           e.owner_employee_id, %2$s
                    FROM inbound_expectation_items i JOIN inbound_expectations e ON e.id = i.expectation_id
                    WHERE i.%1$s %3$s AND e.status = 'OPEN'""".formatted(col.column(), arrivalScope, TARGETS)));
        }
        for (Col col : List.of(new Col(WAREHOUSE, "warehouse_id"), new Col(SUPPLIER, "supplier_id"))) {
            out.add(new Reference(col.target(), "inbound_expectations", col.column(), RefKind.ARRIVAL, """
                    SELECT e.%1$s, 'ARRIVAL', CAST(e.id AS text), COALESCE(e.bill_no_snapshot, '(无单号)'),
                           e.owner_employee_id, %2$s
                    FROM inbound_expectations e
                    WHERE e.%1$s %3$s AND e.status = 'OPEN'""".formatted(col.column(), arrivalScope, TARGETS)));
        }
        // 到货异常：还没过账/关闭/取消。
        String exceptionScope = "CASE x.order_type WHEN 'PURCHASE' THEN 'purchase' ELSE 'subcontract' END";
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"), new Col(SUPPLIER, "supplier_id"))) {
            out.add(new Reference(col.target(), "procurement_arrival_exceptions", col.column(),
                    RefKind.ARRIVAL_EXCEPTION, """
                    SELECT x.%1$s, 'ARRIVAL_EXCEPTION', CAST(x.id AS text),
                           COALESCE(x.receipt_bill_no_snapshot, x.order_bill_no_snapshot, '(无单号)'),
                           x.owner_employee_id, %2$s
                    FROM procurement_arrival_exceptions x
                    WHERE x.%1$s %3$s AND x.status NOT IN ('RECEIPT_POSTED', 'CLOSED', 'CANCELED')"""
                    .formatted(col.column(), exceptionScope, TARGETS)));
        }
        // 来料检验：还没检完。
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"), new Col(WAREHOUSE, "pre_stocked_warehouse_id"),
                new Col(UNIT, "received_weight_unit_id"))) {
            out.add(new Reference(col.target(), "procurement_inspection_items", col.column(), RefKind.INSPECTION, """
                    SELECT x.%1$s, 'INSPECTION', CAST(x.id AS text),
                           to_char(x.received_at, 'YYYY-MM-DD') || ' 到货的来料检验', CAST(NULL AS uuid), 'public'
                    FROM procurement_inspection_items x
                    WHERE x.%1$s %2$s AND x.status IN ('PENDING', 'PARTIAL')""".formatted(col.column(), TARGETS)));
        }
        // 来料不合格：退货/索赔还没办完。
        for (Col col : with(GCU, new Col(SUPPLIER, "supplier_id"))) {
            out.add(new Reference(col.target(), "procurement_iqc_rejection_cases", col.column(),
                    RefKind.IQC_REJECTION, """
                    SELECT x.%1$s, 'IQC_REJECTION', CAST(x.id AS text), COALESCE(x.receipt_bill_no, '(无单号)'),
                           CAST(NULL AS uuid), 'public'
                    FROM procurement_iqc_rejection_cases x
                    WHERE x.%1$s %2$s AND NOT x.is_deleted
                      AND x.status IN ('PENDING_RETURN', 'RETURN_RECORDED', 'FINANCE_EXCEPTION')"""
                    .formatted(col.column(), TARGETS)));
        }
        // 成品检验：还没检完(标签取来源日报单号)。
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"))) {
            out.add(new Reference(col.target(), "production_fqc_inspections", col.column(), RefKind.INSPECTION, """
                    SELECT x.%1$s, 'INSPECTION', CAST(x.id AS text), COALESCE(h.bill_no, '成品检验'),
                           h.maker_id, 'production_plan'
                    FROM production_fqc_inspections x LEFT JOIN production_daily_reports h ON h.id = x.source_report_id
                    WHERE x.%1$s %2$s AND x.status IN ('PENDING', 'PARTIAL')""".formatted(col.column(), TARGETS)));
        }
        // 退货质检：还没处置完(标签取退货单号)。
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"))) {
            out.add(new Reference(col.target(), "sales_return_quality_items", col.column(), RefKind.INSPECTION, """
                    SELECT x.%1$s, 'INSPECTION', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'),
                           h.owner_employee_id, 'sales'
                    FROM sales_return_quality_items x JOIN sales_returns h ON h.id = x.return_id
                    WHERE x.%1$s %2$s AND x.status IN ('PENDING', 'PARTIAL')""".formatted(col.column(), TARGETS)));
        }

        // 生产：任务段未完工、用料未领完、排产包/排产草稿仍有效(均要求计划本身在办)。
        for (Col col : List.of(new Col(GOODS, "product_goods_id"), new Col(COLOR, "product_color_id"),
                new Col(UNIT, "product_unit_id"))) {
            out.add(new Reference(col.target(), "production_execution_segments", col.column(),
                    RefKind.PRODUCTION_TASK, """
                    SELECT x.%1$s, 'PRODUCTION_TASK', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'),
                           h.maker_id, 'production_plan'
                    FROM production_execution_segments x JOIN production_plans h ON h.id = x.plan_id
                    WHERE x.%1$s %2$s AND NOT x.is_deleted
                      AND x.status IN ('READY', 'WAITING', 'DISPATCHED', 'IN_PROGRESS') AND %3$s"""
                    .formatted(col.column(), TARGETS, PLAN_OPEN)));
        }
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"))) {
            out.add(new Reference(col.target(), "production_material_demands", col.column(),
                    RefKind.PRODUCTION_MATERIAL, """
                    SELECT x.%1$s, 'PRODUCTION_MATERIAL', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'),
                           h.maker_id, 'production_plan'
                    FROM production_material_demands x JOIN production_plans h ON h.id = x.plan_id
                    WHERE x.%1$s %2$s AND NOT x.is_deleted
                      AND x.status IN ('OPEN', 'PARTIAL', 'ALLOCATED', 'WAITING_SUPPLY') AND %3$s"""
                    .formatted(col.column(), TARGETS, PLAN_OPEN)));
        }
        out.add(new Reference(WAREHOUSE, "production_planning_packages", "warehouse_id", RefKind.PRODUCTION_PLAN, """
                SELECT x.warehouse_id, 'PRODUCTION_PLAN', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'),
                       h.maker_id, 'production_plan'
                FROM production_planning_packages x JOIN production_plans h ON h.id = x.plan_id
                WHERE x.warehouse_id %s AND NOT x.is_deleted AND x.status = 'CONFIRMED' AND %s"""
                .formatted(TARGETS, PLAN_OPEN)));
        out.add(new Reference(WAREHOUSE, "production_planning_drafts", "warehouse_id", RefKind.PRODUCTION_PLAN, """
                SELECT x.warehouse_id, 'PRODUCTION_PLAN', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'),
                       h.maker_id, 'production_plan'
                FROM production_planning_drafts x JOIN production_plans h ON h.id = x.plan_id
                WHERE x.warehouse_id %s AND x.status = 'ACTIVE' AND %s""".formatted(TARGETS, PLAN_OPEN)));

        // 委外：发料计划未发完(订单在办)、损耗/短交事项未处理完。
        String materialPlanOpen = "NOT mp.is_deleted AND mp.status = 'OPEN' AND " + ORDER_OPEN;
        out.add(new Reference(SUPPLIER, "subcontract_material_plans", "supplier_id",
                RefKind.SUBCONTRACT_MATERIAL_PLAN, """
                SELECT mp.supplier_id, 'SUBCONTRACT_MATERIAL_PLAN', CAST(h.id AS text),
                       COALESCE(h.bill_no, mp.order_bill_no, '(无单号)'), h.maker_id, 'subcontract'
                FROM subcontract_material_plans mp JOIN subcontract_orders h ON h.id = mp.order_id
                WHERE mp.supplier_id %s AND %s""".formatted(TARGETS, materialPlanOpen)));
        for (Col col : with(GCU, new Col(GOODS, "parent_goods_id"), new Col(COLOR, "parent_color_id"),
                new Col(WAREHOUSE, "preparation_warehouse_id"))) {
            out.add(new Reference(col.target(), "subcontract_material_plan_items", col.column(),
                    RefKind.SUBCONTRACT_MATERIAL_PLAN, """
                    SELECT i.%1$s, 'SUBCONTRACT_MATERIAL_PLAN', CAST(h.id AS text),
                           COALESCE(h.bill_no, mp.order_bill_no, '(无单号)'), h.maker_id, 'subcontract'
                    FROM subcontract_material_plan_items i
                    JOIN subcontract_material_plans mp ON mp.id = i.plan_id
                    JOIN subcontract_orders h ON h.id = mp.order_id
                    WHERE i.%1$s %2$s AND NOT i.is_deleted
                      AND i.preparation_status NOT IN ('OUTBOUND_COMPLETE', 'CANCELLED') AND %3$s"""
                    .formatted(col.column(), TARGETS, materialPlanOpen)));
        }
        String lossOpen = "NOT c.is_deleted AND c.status IN ('OPEN', 'ACCEPTED', 'DISPUTED', 'AWAITING_FULFILLMENT')";
        for (Col col : List.of(new Col(SUPPLIER, "supplier_id"), new Col(UNIT, "quantity_unit_id"))) {
            out.add(new Reference(col.target(), "subcontract_loss_cases", col.column(), RefKind.SUBCONTRACT_CASE, """
                    SELECT c.%1$s, 'SUBCONTRACT_CASE', CAST(c.id AS text), COALESCE(c.waste_bill_no, '委外损耗'),
                           CAST(NULL AS uuid), 'public'
                    FROM subcontract_loss_cases c
                    WHERE c.%1$s %2$s AND %3$s""".formatted(col.column(), TARGETS, lossOpen)));
        }
        for (Col col : GCU) {
            out.add(new Reference(col.target(), "subcontract_loss_case_lines", col.column(),
                    RefKind.SUBCONTRACT_CASE, """
                    SELECT l.%1$s, 'SUBCONTRACT_CASE', CAST(c.id AS text), COALESCE(c.waste_bill_no, '委外损耗'),
                           CAST(NULL AS uuid), 'public'
                    FROM subcontract_loss_case_lines l JOIN subcontract_loss_cases c ON c.id = l.case_id
                    WHERE l.%1$s %2$s AND %3$s""".formatted(col.column(), TARGETS, lossOpen)));
        }
        for (Col col : with(GCU, new Col(SUPPLIER, "supplier_id"))) {
            out.add(new Reference(col.target(), "subcontract_short_delivery_cases", col.column(),
                    RefKind.SUBCONTRACT_CASE, """
                    SELECT x.%1$s, 'SUBCONTRACT_CASE', CAST(x.id AS text),
                           COALESCE(x.order_bill_no_snapshot, '(无单号)'), x.owner_employee_id, 'subcontract'
                    FROM subcontract_short_delivery_cases x
                    WHERE x.%1$s %2$s AND x.status IN ('PENDING_OWNER', 'WAITING_MORE')"""
                    .formatted(col.column(), TARGETS)));
        }

        // 物料分析：来源行、物料行、备料动作、借料、改派、委外交接(均要求分析本身在办)。
        for (Col col : GCU) {
            out.add(analysis(col, "production_material_analysis_items", "x.analysis_id", "NOT x.is_deleted"));
            out.add(analysis(col, "production_material_analysis_materials", "x.analysis_id", "x.active"));
            out.add(analysis(col, "production_material_analysis_borrows", "x.analysis_id", "x.status = 'ACTIVE'"));
            out.add(analysis(col, "preplan_subcontract_requirement_handoff_items",
                    "x.source_analysis_id, x.target_analysis_id", "TRUE"));
        }
        for (Col col : with(GCU, new Col(WAREHOUSE, "warehouse_id"))) {
            out.add(analysis(col, "preplan_supply_actions", "x.analysis_id",
                    "x.status IN ('OPEN', 'CREATED', 'IN_PROGRESS')"));
            out.add(analysis(col, "preplan_subcontract_make_tasks", "x.analysis_id", "x.status = 'ACTIVE'"));
            out.add(analysis(col, "preplan_material_reallocations", "x.from_analysis_id, x.to_analysis_id",
                    "x.status IN ('OPEN', 'PARTIAL')"));
        }
        for (Col col : List.of(new Col(WAREHOUSE, "warehouse_id"), new Col(GOODS, "target_goods_id"),
                new Col(COLOR, "target_color_id"), new Col(UNIT, "target_unit_id"))) {
            out.add(analysis(col, "preplan_subcontract_requirement_handoffs",
                    "x.source_analysis_id, x.target_analysis_id", "TRUE"));
        }
        out.add(new Reference(WAREHOUSE, "production_material_analyses", "warehouse_id", RefKind.ANALYSIS, """
                SELECT a.warehouse_id, 'ANALYSIS', CAST(a.id AS text), %s, CAST(NULL AS uuid), 'public'
                FROM production_material_analyses a
                WHERE a.warehouse_id %s AND %s""".formatted(ANALYSIS_LABEL, TARGETS, ANALYSIS_OPEN)));
        out.add(new Reference(WAREHOUSE, "production_material_analyses", "participating_warehouse_ids",
                RefKind.ANALYSIS, """
                SELECT w.id, 'ANALYSIS', CAST(a.id AS text), %s, CAST(NULL AS uuid), 'public'
                FROM production_material_analyses a JOIN targets w ON w.id = ANY(a.participating_warehouse_ids)
                WHERE %s""".formatted(ANALYSIS_LABEL, ANALYSIS_OPEN)));

        out.add(new Reference(GOODS, "rd_tasks", "goods_id", RefKind.RD_TASK, """
                SELECT t.goods_id, 'RD_TASK', CAST(t.id AS text), COALESCE(t.task_no, t.title, '(无编号)'),
                       CAST(NULL AS uuid), 'public'
                FROM rd_tasks t
                WHERE t.goods_id %s AND NOT t.is_deleted AND t.status IN ('OPEN', 'IN_PROGRESS')"""
                .formatted(TARGETS)));
    }

    /** 往来：未结清的应收/应付、未收回的供应商索赔、未对完的供应商对账。 */
    private static void finance(List<Reference> out) {
        out.add(new Reference(CLIENT, "ar_ap_ledger", "client_id", RefKind.RECEIVABLE, """
                SELECT l.client_id, 'RECEIVABLE', CAST(l.id AS text),
                       COALESCE(l.bill_no, l.source_doc_no, '(无单号)'), CAST(NULL AS uuid), 'public'
                FROM ar_ap_ledger l
                WHERE l.client_id %s AND NOT l.is_deleted AND NOT l.is_settled""".formatted(TARGETS)));
        out.add(new Reference(SUPPLIER, "ar_ap_ledger", "supplier_id", RefKind.PAYABLE, """
                SELECT l.supplier_id, 'PAYABLE', CAST(l.id AS text),
                       COALESCE(l.bill_no, l.source_doc_no, '(无单号)'), CAST(NULL AS uuid), 'public'
                FROM ar_ap_ledger l
                WHERE l.supplier_id %s AND NOT l.is_deleted AND NOT l.is_settled""".formatted(TARGETS)));
        out.add(new Reference(SUPPLIER, "supplier_claim_receivables", "supplier_id", RefKind.SUPPLIER_CLAIM, """
                SELECT c.supplier_id, 'SUPPLIER_CLAIM', CAST(c.id AS text), COALESCE(c.bill_no, '(无单号)'),
                       CAST(NULL AS uuid), 'public'
                FROM supplier_claim_receivables c
                WHERE c.supplier_id %s AND NOT c.is_deleted AND c.status IN ('OPEN', 'PARTIAL')"""
                .formatted(TARGETS)));
        out.add(new Reference(SUPPLIER, "supplier_settlement_batches", "supplier_id", RefKind.SUPPLIER_SETTLEMENT, """
                SELECT s.supplier_id, 'SUPPLIER_SETTLEMENT', CAST(s.id AS text), COALESCE(s.batch_no, '(无单号)'),
                       CAST(NULL AS uuid), 'public'
                FROM supplier_settlement_batches s
                WHERE s.supplier_id %s AND NOT s.is_deleted AND s.status NOT IN ('CLOSED', 'REVERSED')"""
                .formatted(TARGETS)));
    }

    private static Reference goodsColumn(MasterEntityKind target, String column) {
        return new Reference(target, "goods", column, RefKind.GOODS, """
                SELECT g.%1$s, 'GOODS', CAST(g.id AS text), %2$s, g.owner_employee_id, 'goods'
                FROM goods g
                WHERE g.%1$s %3$s AND NOT g.is_deleted
                  AND g.id NOT IN (SELECT id FROM excluded)""".formatted(column, GOODS_LABEL, TARGETS));
    }

    /** 有效父件的有效 BOM 行上还指定着它(颜色/默认供应商)。 */
    private static Reference bomRow(MasterEntityKind target, String column) {
        return new Reference(target, "goods_bom_items", column, RefKind.BOM_ROW, """
                SELECT b.%1$s, 'BOM_ROW', CAST(p.id AS text), %2$s, p.owner_employee_id, 'goods'
                FROM goods_bom_items b JOIN goods p ON p.id = b.goods_id
                WHERE b.%1$s %3$s AND NOT b.is_deleted AND NOT p.is_deleted
                  AND p.id NOT IN (SELECT id FROM excluded)""".formatted(column, PARENT_LABEL, TARGETS));
    }

    private static void lines(List<Reference> out, Doc doc, String items, String fk, List<Col> columns) {
        for (Col col : columns) {
            out.add(new Reference(col.target(), items, col.column(), doc.kind(), """
                    SELECT i.%1$s, '%2$s', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'), h.%3$s, '%4$s'
                    FROM %5$s h JOIN %6$s i ON i.%7$s = h.id
                    WHERE i.%1$s %8$s AND NOT i.is_deleted AND %9$s"""
                    .formatted(col.column(), doc.kind().name(), doc.owner(), doc.scope(), doc.table(), items, fk,
                            TARGETS, doc.open())));
        }
    }

    private static void header(List<Reference> out, Doc doc, MasterEntityKind target, String column) {
        out.add(new Reference(target, doc.table(), column, doc.kind(), """
                SELECT h.%1$s, '%2$s', CAST(h.id AS text), COALESCE(h.bill_no, '(无单号)'), h.%3$s, '%4$s'
                FROM %5$s h
                WHERE h.%1$s %6$s AND %7$s"""
                .formatted(column, doc.kind().name(), doc.owner(), doc.scope(), doc.table(), TARGETS, doc.open())));
    }

    /**
     * 物料分析家族的一处引用：{@code analysisIds} 是指向分析的列(可多列，任一在办即算)，
     * {@code own} 是本表自己的「仍有效」口径。
     */
    private static Reference analysis(Col col, String table, String analysisIds, String own) {
        return new Reference(col.target(), table, col.column(), RefKind.ANALYSIS, """
                SELECT x.%1$s, 'ANALYSIS', CAST(a.id AS text), %2$s, CAST(NULL AS uuid), 'public'
                FROM %3$s x JOIN production_material_analyses a ON a.id IN (%4$s)
                WHERE x.%1$s %5$s AND %6$s AND %7$s"""
                .formatted(col.column(), ANALYSIS_LABEL, table, analysisIds, TARGETS, own, ANALYSIS_OPEN));
    }

    private static List<Col> with(List<Col> base, Col... extra) {
        List<Col> out = new ArrayList<>(base);
        out.addAll(List.of(extra));
        return List.copyOf(out);
    }

    // ---- 豁免 --------------------------------------------------------------------

    private static List<Exemption> buildExemptions() {
        List<Exemption> out = new ArrayList<>();
        exempt(out, ExemptReason.HISTORY, "库存流水", "stock_movements",
                "goods_id", "color_id", "unit_id", "actual_weight_unit_id", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "计量采集的判定记录与证据", "measurement_capture_decision_events",
                "goods_id");
        exempt(out, ExemptReason.HISTORY, "计量采集的判定记录与证据", "measurement_capture_evidence",
                "goods_id", "business_unit_id", "actual_weight_unit_id");
        exempt(out, ExemptReason.HISTORY, "计量采集的明细快照", "measurement_capture_line_snapshots",
                "goods_id", "business_unit_id", "actual_weight_unit_id");
        exempt(out, ExemptReason.HISTORY, "来料检验的放行事件", "procurement_inspection_events",
                "released_weight_unit_id");
        exempt(out, ExemptReason.HISTORY, "来料让步审批记录", "procurement_iqc_consideration_review_approvals",
                "supplier_id");
        exempt(out, ExemptReason.HISTORY, "检验合格后已入库的批次明细", "procurement_iqc_stock_in_batch_items",
                "goods_id", "color_id", "warehouse_id", "weight_unit_id");
        exempt(out, ExemptReason.HISTORY, "成品到货登记(未检完的由成品检验覆盖)",
                "production_finished_arrival_registrations", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "成品检验单打印记录", "production_fqc_inspection_sheets", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "退料收仓确认记录", "production_material_return_receiving_confirmations",
                "previous_warehouse_id", "received_warehouse_id", "source_warehouse_id");
        exempt(out, ExemptReason.HISTORY, "车间直送已过账的移库记录(线边仓里还有没有料由库存余额检查)",
                "production_workshop_direct_transfers", "line_side_warehouse_id");
        exempt(out, ExemptReason.HISTORY, "公共备货供应事件", "preplan_public_supply_events",
                "goods_id", "color_id", "unit_id", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "顶层产出事件", "preplan_root_output_events",
                "goods_id", "color_id", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "出货放行事件", "sales_shipment_finance_release_events", "client_id");
        exempt(out, ExemptReason.HISTORY, "出货仓库作业事件", "sales_shipment_warehouse_events", "warehouse_id");
        exempt(out, ExemptReason.HISTORY, "客户可见范围变更记录", "client_access_change_events", "client_id");
        exempt(out, ExemptReason.HISTORY, "已完成的往来核销", "customer_open_item_offset_batches", "client_id");
        exempt(out, ExemptReason.HISTORY, "已完成的往来核销", "customer_open_item_offsets", "client_id");
        exempt(out, ExemptReason.HISTORY, "已完成的往来核销", "supplier_open_item_offsets", "supplier_id");
        exempt(out, ExemptReason.HISTORY, "已审核的索赔收款", "supplier_claim_cash_receipts", "supplier_id");
        exempt(out, ExemptReason.HISTORY, "官网询盘来访线索", "website_inquiries", "client_id");

        exempt(out, ExemptReason.LEGACY, "老库计量迁移异常", "legacy_measurement_exceptions",
                "goods_id", "color_id", "warehouse_id", "actual_weight_unit_id");
        exempt(out, ExemptReason.LEGACY, "老库计量迁移快照", "legacy_measurement_profile_snapshots", "goods_id");
        exempt(out, ExemptReason.LEGACY, "老库车间直送异常", "production_workshop_direct_legacy_anomalies",
                "goods_id", "color_id", "warehouse_id");
        exempt(out, ExemptReason.LEGACY, "老库客户结算方式迁移问题", "client_default_settlement_migration_issues",
                "client_id");
        exempt(out, ExemptReason.LEGACY, "老库订单成本展开(只读)", "sales_order_cost_items",
                "goods_id", "alt_goods_id", "color_id", "alt_color_id", "unit_id", "supplier_id");
        exempt(out, ExemptReason.LEGACY, "老库委外订单成本展开(只读)", "subcontract_order_cost_items",
                "goods_id", "parent_goods_id", "color_id", "parent_color_id", "unit_id");
        exempt(out, ExemptReason.LEGACY, "老库生产计划成本(只读，按年分区)", "production_plan_costs",
                "goods_id", "master_goods_id", "color_id", "master_color_id", "supplier_id");

        exempt(out, ExemptReason.OWN_CONFIG, "客户收货地址", "client_ship_addresses", "client_id");
        exempt(out, ExemptReason.OWN_CONFIG, "客户可见人授权", "client_visibility_grants", "client_id");
        exempt(out, ExemptReason.OWN_CONFIG, "货品在仓库里的默认存放位置", "warehouse_goods_place_preferences",
                "goods_id", "color_id", "warehouse_id");
        // V693(ADR-115): 负责关系是仓库自己的附属设置, 删仓库后负责人自然失效, 不算「还在用」。
        exempt(out, ExemptReason.OWN_CONFIG, "仓库负责人(仓管员)", "warehouse_keepers", "warehouse_id");
        exempt(out, ExemptReason.OWN_CONFIG, "单位自己的换算设置", "unit_measurement_profiles", "unit_id");
        exempt(out, ExemptReason.OWN_CONFIG, "货品自己的计量采集设置", "measurement_capture_profiles", "goods_id");
        exempt(out, ExemptReason.OWN_CONFIG, "父件自己的组装清单(删父件时同一事务软删)", "goods_bom_items",
                "goods_id");

        exempt(out, ExemptReason.COVERED, "库存成本池跟着库存余额走(库存余额检查)", "stock_value_pools",
                "goods_id", "color_id", "warehouse_id");
        exempt(out, ExemptReason.COVERED, "退料申请本身就是一张出入库单(出入库单检查)",
                "production_material_return_requests", "warehouse_id");
        exempt(out, ExemptReason.COVERED, "返工授权跟着生产任务走(生产任务/生产用料检查)",
                "production_fqc_recovery_authorizations", "goods_id", "color_id", "unit_id", "warehouse_id");
        exempt(out, ExemptReason.COVERED, "补产周期跟着生产计划走(排产包/生产用料检查)",
                "production_fqc_replenishment_cycles", "warehouse_id");
        return List.copyOf(out);
    }

    private static void exempt(List<Exemption> out, ExemptReason reason, String note, String table,
                               String... columns) {
        for (String column : columns) {
            out.add(new Exemption(table, column, reason, note));
        }
    }
}
