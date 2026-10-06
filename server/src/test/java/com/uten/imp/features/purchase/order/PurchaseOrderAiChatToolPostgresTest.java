package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.AiDocumentStatusToolPostgresSupport;
import com.uten.imp.support.ProcurementReceiptFixtureSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * purchase_order_status 的对象范围与采购订货单详情接口相同(P1-3): 制单人看得到状态和到货、质检数量, 同部门
 * 没有全量查看的同事与不存在的单号得到同一句中性回答, 其它部门用不了这个工具; 查到一次写一条与详情页相同的
 * 查看审计, 查不到不写。
 */
class PurchaseOrderAiChatToolPostgresTest extends AiDocumentStatusToolPostgresSupport {

    @Autowired
    private PurchaseOrderAiChatTool tool;

    private Staff owner;
    private Staff colleague;
    private Staff outsider;
    private String orderNo;
    private UUID orderId;
    private UUID orderItemId;
    private UUID goods;
    private UUID unit;
    private UUID warehouse;

    @BeforeEach
    void fixture() throws Exception {
        grant("SUB_PURCHASE", "ai:use", "purchase_order:view");
        grant("DEPT_HR", "ai:use");
        owner = newEmployee(adminToken(), "SUB_PURCHASE");
        colleague = newEmployee(adminToken(), "SUB_PURCHASE");
        outsider = newEmployee(adminToken(), "DEPT_HR");
        revoke(owner, "purchase:view:all");
        revoke(colleague, "purchase:view:all");

        unit = unit("箱");
        String goodsCode = "AIT-PO-" + UUID.randomUUID().toString().substring(0, 8);
        goods = goods(goodsCode, "测试纸箱", unit);
        warehouse = warehouse();
        UUID supplier = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO suppliers(id, code, name, status, code_sequence)
                VALUES (?, ?, '保密供应商乙', '使用', (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM suppliers))
                """, supplier, "AIT-S-" + supplier);
        orderId = UUID.randomUUID();
        orderItemId = UUID.randomUUID();
        orderNo = billNo("CD");
        jdbc.update("""
                INSERT INTO purchase_orders(id, bill_no, bill_date, deliver_date, warehouse_id, supplier_id, status,
                                            maker_id, created_by)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?::uuid, ?::uuid)
                """, orderId, orderNo, BILL_DATE, BILL_DATE.plusDays(7), warehouse, supplier,
                owner.employeeId(), owner.userId());
        jdbc.update("""
                INSERT INTO purchase_order_items(id, bill_no, bill_date, order_id, line_no, goods_id, unit_id, unit_rate,
                    qty, received_qty, returned_qty, goods_code_snapshot, goods_name_snapshot, goods_snapshot_source)
                VALUES (?, ?, ?, ?, 1, ?, ?, 1, 10, 0, 0, ?, '测试纸箱', 'MASTER_AT_SAVE')
                """, orderItemId, orderNo, BILL_DATE, orderId, goods, unit, goodsCode);
    }

    @Test
    void ownerSeesStatusAndArrivalWithoutSupplierOrPeople() throws Exception {
        actAs(owner);
        assertThat(tool.available()).isTrue();
        Map<String, Object> result = tool.execute(Map.of("orderNo", orderNo));
        assertThat((String) result.get("reply")).contains("采购订货单 " + orderNo, "财务已批准", "等供应商送货",
                "订 10 箱", "已到货 0");
        String detail = (String) result.get("detailReply");
        assertThat(detail).contains("测试纸箱", "待检 0", "已入库 0 箱", "交货日期 2026-10-13");
        assertThat(tool.modelFacts(result).toString()).doesNotContain("保密供应商乙", fullName(owner));
        assertThat(detail).doesNotContain("保密供应商乙", fullName(owner));
        Map<String, Object> evidence = evidence(result);
        tool.authorizeResultRead(evidence);

        // Arrival registered and sent to inspection: the line and the status move, the stored answer is stale.
        registerArrivalAwaitingInspection("4");
        Map<String, Object> arrived = tool.execute(Map.of("orderNo", orderNo));
        assertThat((String) arrived.get("detailReply")).contains("待品质检验", "已到货 4", "待检 4", "合格 0");
        assertEvidenceRefused(tool, evidence);
    }

    @Test
    void colleagueAndUnknownNumberGetTheSameNeutralReply() {
        actAs(colleague);
        Map<String, Object> hidden = tool.execute(Map.of("orderNo", orderNo));
        Map<String, Object> unknown = tool.execute(Map.of("orderNo", "CD20991231999999"));
        assertThat(hidden.get("reply")).isEqualTo(PurchaseOrderAiChatTool.NOT_FOUND).isEqualTo(unknown.get("reply"));
        assertThat(tool.modelFacts(hidden)).isEmpty();
        assertThat(hidden.toString()).doesNotContain("测试纸箱", "财务已批准");
        actAs(owner);
        Map<String, Object> ownerEvidence = evidence(tool.execute(Map.of("orderNo", orderNo)));
        actAs(colleague);
        assertEvidenceRefused(tool, ownerEvidence);
    }

    @Test
    void anotherDepartmentCannotUseTheTool() {
        actAs(outsider);
        assertThat(tool.available()).isFalse();
        assertForbidden(() -> tool.execute(Map.of("orderNo", orderNo)));
    }

    /**
     * ADR-105 查看审计: 查到一次就写一条与采购订货单详情页相同的查看记录(同一动作与对象表, 对象名称标 AI 助手查询);
     * 看不到的单、不存在的单号、用不了工具与复核旧回答都不写。
     */
    @Test
    void aSuccessfulReadLeavesOneDetailViewRecordAndARefusedOneLeavesNone() {
        actAs(colleague);
        tool.execute(Map.of("orderNo", orderNo));
        tool.execute(Map.of("orderNo", "CD20991231999999"));
        actAs(outsider);
        assertForbidden(() -> tool.execute(Map.of("orderNo", orderNo)));
        assertThat(viewRecords(colleague)).isEmpty();
        assertThat(viewRecords(outsider)).isEmpty();
        assertThat(orderViews()).isEmpty();

        actAs(owner);
        Map<String, Object> result = tool.execute(Map.of("orderNo", orderNo));
        assertThat(viewRecords(owner)).singleElement().satisfies(view -> {
            assertThat(view.get("action")).isEqualTo("view_purchase_order_detail");
            assertThat(view.get("target_type")).isEqualTo("purchase_orders");
            assertThat(view.get("target_id")).isEqualTo(orderId.toString());
            assertThat(view.get("display")).isEqualTo("采购订货单(AI 助手查询)");
            assertThat(view.get("code")).isEqualTo(orderNo);
            assertThat(view.get("result")).isEqualTo("success");
        });
        // Showing the stored answer again is a re-check, not a new read; asking again within 30 minutes is folded
        // into the first record, the detail page's own rule.
        tool.authorizeResultRead(evidence(result));
        tool.execute(Map.of("orderNo", orderNo));
        assertThat(orderViews()).hasSize(1);
    }

    /** Detail-view records this reader left (any document). */
    private List<Map<String, Object>> viewRecords(Staff reader) {
        return jdbc.queryForList("""
                SELECT action, target_type, target_id, result, after ->> 'target_display_name' AS display,
                       after ->> 'target_business_code' AS code
                FROM audit_log WHERE actor_id = ?::uuid AND left(action, 5) = 'view_'
                ORDER BY id
                """, reader.userId());
    }

    /** Detail-view records of the fixture order by anyone. */
    private List<Map<String, Object>> orderViews() {
        return jdbc.queryForList("""
                SELECT actor_id FROM audit_log WHERE target_type = 'purchase_orders' AND target_id = ?
                  AND left(action, 5) = 'view_'
                """, orderId.toString());
    }

    /**
     * An approved, explicitly zero-priced receipt line linked to the order line, waiting in incoming inspection. The
     * receipt, its standard payable consideration (the platform's conservation rule) and the inspection slice are
     * written in one transaction, as the receipt approval does.
     */
    private void registerArrivalAwaitingInspection(String qty) throws Exception {
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        String receiptNo = billNo("CJ");
        try (Connection connection = jdbc.getDataSource().getConnection()) {
            connection.setAutoCommit(false);
            try {
                execute(connection, """
                        INSERT INTO purchase_receipts(id, bill_no, bill_date, warehouse_id, status)
                        VALUES (?, ?, ?, ?, 1)
                        """, receiptId, receiptNo, BILL_DATE, warehouse);
                execute(connection, """
                        INSERT INTO purchase_receipt_items(id, bill_no, bill_date, receipt_id, line_no, order_item_id,
                            goods_id, unit_id, unit_rate, qty, price, amount_original, amount_local, replacement_intent,
                            goods_snapshot_source)
                        VALUES (?, ?, ?, ?, 1, ?, ?, ?, 1, ?::numeric, 0, 0, 0, 'NORMAL', 'MASTER_AT_SAVE')
                        """, receiptItemId, receiptNo, BILL_DATE, receiptId, orderItemId, goods, unit, qty);
                execute(connection, "UPDATE purchase_order_items SET received_qty = ?::numeric WHERE id = ?", qty, orderItemId);
                execute(connection, """
                        INSERT INTO procurement_inspection_items(id, receipt_type, receipt_id, receipt_item_id,
                            warehouse_id, goods_id, unit_id, unit_rate, received_base_qty, received_amount_local, status)
                        VALUES (?, 'PURCHASE', ?, ?, ?, ?, ?, 1, ?::numeric, 0, 'PENDING')
                        """, UUID.randomUUID(), receiptId, receiptItemId, warehouse, goods, unit, qty);
                ProcurementReceiptFixtureSupport.appendStandardReceipt(connection, "PURCHASE", receiptId);
                connection.commit();
            } catch (Exception failure) {
                connection.rollback();
                throw failure;
            }
        }
    }

    private static void execute(Connection connection, String sql, Object... values) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < values.length; i++) statement.setObject(i + 1, values[i]);
            statement.executeUpdate();
        }
    }
}
