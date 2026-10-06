package com.uten.imp.features.sales.order;

import com.uten.imp.application.port.AiDocumentStatusToolPostgresSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * sales_order_progress 的对象范围与销售订货单详情接口相同(P1-3): 归属人看得到事实, 同部门没有全量查看的同事与
 * 不存在的单号得到同一句中性回答, 其它部门根本用不了这个工具; 存下的回答在范围或数据变化后不再展示;
 * 查到一次写一条与详情页相同的查看审计, 查不到不写。
 */
class SalesOrderAiChatToolPostgresTest extends AiDocumentStatusToolPostgresSupport {

    @Autowired
    private SalesOrderAiChatTool tool;

    private Staff owner;
    private Staff colleague;
    private Staff outsider;
    private String orderNo;
    private UUID orderId;

    @BeforeEach
    void fixture() throws Exception {
        grant("DEPT_SALES", "ai:use", "sales_order:view");
        grant("DEPT_HR", "ai:use");
        String admin = adminToken();
        owner = newEmployee(admin, "DEPT_SALES");
        colleague = newEmployee(adminToken(), "DEPT_SALES");
        outsider = newEmployee(adminToken(), "DEPT_HR");
        revoke(owner, "sales:view:all");
        revoke(colleague, "sales:view:all");

        UUID unit = unit("个");
        UUID goods = goods("AIT-SO-" + UUID.randomUUID().toString().substring(0, 8), "测试水杯", unit);
        UUID client = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients(id, code, name, status, code_sequence)
                VALUES (?, ?, '保密客户甲', '使用', (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM clients))
                """, client, "AIT-C-" + client);
        orderId = UUID.randomUUID();
        orderNo = billNo("XD");
        jdbc.update("""
                INSERT INTO sales_orders(id, bill_no, bill_date, deliver_date, client_id, status,
                                         finance_confirmed, owner_employee_id)
                VALUES (?, ?, ?, ?, ?, 1, TRUE, ?::uuid)
                """, orderId, orderNo, BILL_DATE, BILL_DATE.plusDays(14), client, owner.employeeId());
        jdbc.update("""
                INSERT INTO sales_order_items(id, bill_no, bill_date, order_id, line_no, goods_id,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, goods_snapshot_locked_at,
                    unit_id, unit_rate, qty)
                SELECT ?, ?, ?, ?, 1, goods.id, goods.code, goods.name, 'MASTER_AT_APPROVAL', now(), ?, 1, 10
                FROM goods WHERE goods.id = ?
                """, UUID.randomUUID(), orderNo, BILL_DATE, orderId, unit, goods);
    }

    @Test
    void ownerSeesStageQuantitiesAndChainWithoutCustomerOrPeople() {
        actAs(owner);
        assertThat(tool.available()).isTrue();
        Map<String, Object> result = tool.execute(Map.of("orderNo", " " + orderNo.toLowerCase() + " "));
        String reply = (String) result.get("reply");
        String detail = (String) result.get("detailReply");
        assertThat(reply).contains("销售订货单 " + orderNo, "待排产", "订 10 个", "交货日期 2026-10-20")
                .contains("等计划部做物料分析");
        assertThat(detail).contains("全链路", "财务审核", "测试水杯", "已排产 0", "已发货 0 个");
        Map<String, Object> facts = tool.modelFacts(result);
        assertThat(facts).containsKey("facts");
        // ADR-150 / SPEC: neither the customer nor any person reaches the model.
        assertThat(facts.toString()).doesNotContain("保密客户甲", fullName(owner));
        assertThat(detail).doesNotContain("保密客户甲", fullName(owner));

        Map<String, Object> evidence = evidence(result);
        tool.authorizeResultRead(evidence);
        // A real progress change (the delivery date moved) invalidates the stored answer.
        jdbc.update("UPDATE sales_orders SET deliver_date = deliver_date + 1 WHERE id = ?", orderId);
        assertEvidenceRefused(tool, evidence);
    }

    @Test
    void colleagueAndUnknownNumberGetTheSameNeutralReply() {
        actAs(colleague);
        Map<String, Object> hidden = tool.execute(Map.of("orderNo", orderNo));
        Map<String, Object> unknown = tool.execute(Map.of("orderNo", "XD20991231999999"));
        assertThat(hidden.get("reply")).isEqualTo(SalesOrderAiChatTool.NOT_FOUND).isEqualTo(unknown.get("reply"));
        assertThat(hidden).doesNotContainKey("detailReply");
        assertThat(tool.modelFacts(hidden)).isEmpty();
        assertThat(hidden.toString()).doesNotContain("待排产", "测试水杯");

        // The owner's stored answer is not shown to the colleague either.
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
     * ADR-105 查看审计: 查到一次就写一条与订货单详情页相同的查看记录(同一动作与对象表, 对象名称标 AI 助手查询);
     * 看不到的单、不存在的单号、用不了工具与复核旧回答都不写。
     */
    @Test
    void aSuccessfulReadLeavesOneDetailViewRecordAndARefusedOneLeavesNone() {
        actAs(colleague);
        tool.execute(Map.of("orderNo", orderNo));
        tool.execute(Map.of("orderNo", "XD20991231999999"));
        actAs(outsider);
        assertForbidden(() -> tool.execute(Map.of("orderNo", orderNo)));
        assertThat(viewRecords(colleague)).isEmpty();
        assertThat(viewRecords(outsider)).isEmpty();
        assertThat(orderViews()).isEmpty();

        actAs(owner);
        Map<String, Object> result = tool.execute(Map.of("orderNo", orderNo));
        assertThat(viewRecords(owner)).singleElement().satisfies(view -> {
            assertThat(view.get("action")).isEqualTo("view_sales_order_detail");
            assertThat(view.get("target_type")).isEqualTo("sales_orders");
            assertThat(view.get("target_id")).isEqualTo(orderId.toString());
            assertThat(view.get("display")).isEqualTo("销售订货单(AI 助手查询)");
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
                SELECT actor_id FROM audit_log WHERE target_type = 'sales_orders' AND target_id = ?
                  AND left(action, 5) = 'view_'
                """, orderId.toString());
    }
}
