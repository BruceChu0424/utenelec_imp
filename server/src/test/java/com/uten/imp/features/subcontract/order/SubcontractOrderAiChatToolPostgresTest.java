package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.AiDocumentStatusToolPostgresSupport;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * subcontract_order_status 的对象范围与两个详情接口相同(P1-3), 并且答得出 ADR-156 的锁: 直属物料不齐时申请锁住、
 * 缺哪种物料差多少, 草稿订货单提交财务会被拦; 物料到了以后答案随之变化, 旧回答不再展示。委外申请不按归属隔离
 * (与申请详情接口一致), 委外订货单按制单人归属; 其它部门用不了这个工具。查到一次写一条与对应详情页相同的
 * 查看审计, 查不到不写。
 */
class SubcontractOrderAiChatToolPostgresTest extends AiDocumentStatusToolPostgresSupport {

    @Autowired
    private SubcontractOrderAiChatTool tool;

    private Staff owner;
    private Staff colleague;
    private Staff outsider;
    private String applicationNo;
    private UUID applicationId;
    private String orderNo;
    private UUID orderId;
    private String materialCode;
    private UUID material;
    private UUID warehouse;

    @BeforeEach
    void fixture() throws Exception {
        grant("QA_OUT", "ai:use", "subcontract_order:view", "subcontract_application:view");
        grant("DEPT_HR", "ai:use");
        owner = newEmployee(adminToken(), "QA_OUT");
        colleague = newEmployee(adminToken(), "QA_OUT");
        outsider = newEmployee(adminToken(), "DEPT_HR");
        revoke(owner, "subcontract:view:all");
        revoke(colleague, "subcontract:view:all");

        UUID piece = unit("个");
        UUID kilogram = unit("千克");
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        String parentCode = "AIT-SC-P-" + suffix;
        materialCode = "AIT-SC-M-" + suffix;
        UUID parent = goods(parentCode, "测试外壳", piece);
        material = goods(materialCode, "测试塑料粒", kilogram);
        warehouse = warehouse();
        jdbc.update("""
                INSERT INTO goods_bom_items(id, goods_id, component_goods_id, qty, consumption_basis, control_stage, sort_order)
                VALUES (?, ?, ?, 2, 'PER_UNIT', 'START', 1)
                """, UUID.randomUUID(), parent, material);

        applicationId = UUID.randomUUID();
        applicationNo = billNo("EB");
        jdbc.update("""
                INSERT INTO subcontract_applications(id, bill_no, bill_date, warehouse_id, need_date, status,
                                                     created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, 1, ?::uuid, ?::uuid)
                """, applicationId, applicationNo, BILL_DATE, warehouse, BILL_DATE.plusDays(10),
                owner.userId(), owner.userId());
        jdbc.update("""
                INSERT INTO subcontract_application_items(id, bill_no, bill_date, application_id, line_no, goods_id,
                    unit_id, goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, unit_rate, qty,
                    created_by, updated_by)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, '测试外壳', 'MASTER_AT_SAVE', 1, 10, ?::uuid, ?::uuid)
                """, UUID.randomUUID(), applicationNo, BILL_DATE, applicationId, parent, piece, parentCode,
                owner.userId(), owner.userId());

        orderId = UUID.randomUUID();
        orderNo = billNo("EO");
        jdbc.update("""
                INSERT INTO subcontract_orders(id, bill_no, bill_date, warehouse_id, status, maker_id,
                                               created_by, updated_by)
                VALUES (?, ?, ?, ?, 0, ?::uuid, ?::uuid, ?::uuid)
                """, orderId, orderNo, BILL_DATE, warehouse, owner.employeeId(), owner.userId(), owner.userId());
        jdbc.update("""
                INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, line_no, goods_id, unit_id,
                    goods_code_snapshot, goods_name_snapshot, goods_snapshot_source, unit_rate, qty,
                    created_by, updated_by)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?, '测试外壳', 'MASTER_AT_SAVE', 1, 5, ?::uuid, ?::uuid)
                """, UUID.randomUUID(), orderNo, BILL_DATE, orderId, parent, piece, parentCode,
                owner.userId(), owner.userId());
    }

    @Test
    void lockedApplicationNamesTheMissingMaterialAndUnlocksWhenStockArrives() {
        actAs(owner);
        assertThat(tool.available()).isTrue();
        Map<String, Object> locked = tool.execute(Map.of("documentNo", applicationNo));
        String reply = (String) locked.get("reply");
        assertThat(reply).contains("委外申请单 " + applicationNo, "等物料齐套(锁住)", materialCode, "还缺 20 千克",
                "需要 20", "现在能用 0");
        assertThat((String) locked.get("detailReply")).contains("申请 10 个", "剩余未下单 10", "现在可下单 0 个");
        assertThat(tool.modelFacts(locked).toString()).doesNotContain(fullName(owner));
        Map<String, Object> evidence = evidence(locked);
        tool.authorizeResultRead(evidence);

        // 100 kg arrive in a usable warehouse; the draft order (5 sets = 10 kg) still claims its share.
        jdbc.update("INSERT INTO stock_balances(id, warehouse_id, goods_id, qty) VALUES (?, ?, ?, 100)",
                UUID.randomUUID(), warehouse, material);
        Map<String, Object> unlocked = tool.execute(Map.of("documentNo", applicationNo));
        assertThat((String) unlocked.get("reply")).contains("待下单", "现在可下单 10");
        assertEvidenceRefused(tool, evidence);
    }

    @Test
    void draftOrderExplainsTheKitCheckBeforeFinance() {
        actAs(owner);
        Map<String, Object> result = tool.execute(Map.of("documentNo", orderNo));
        String reply = (String) result.get("reply");
        assertThat(reply).contains("委外订货单 " + orderNo, "草稿", "提交财务时会被拦下", materialCode,
                "本单需要 10 千克", "现在能用 0 千克");
        assertThat((String) result.get("detailReply")).contains("财务审批：进行中(待提交财务审核)", "订 5 个");
        tool.authorizeResultRead(evidence(result));
    }

    @Test
    void scopeFollowsEachDetailEndpoint() {
        actAs(colleague);
        Map<String, Object> hiddenOrder = tool.execute(Map.of("documentNo", orderNo));
        Map<String, Object> unknown = tool.execute(Map.of("documentNo", "EO20991231999999"));
        assertThat(hiddenOrder.get("reply")).isEqualTo(SubcontractOrderAiChatTool.NOT_FOUND)
                .isEqualTo(unknown.get("reply"));
        assertThat(tool.modelFacts(hiddenOrder)).isEmpty();
        // Applications are planning demand without owner isolation, the same as the application detail page.
        assertThat((String) tool.execute(Map.of("documentNo", applicationNo)).get("reply")).contains("等物料齐套(锁住)");

        actAs(outsider);
        assertThat(tool.available()).isFalse();
        assertForbidden(() -> tool.execute(Map.of("documentNo", applicationNo)));
    }

    /**
     * ADR-105 查看审计: 每种单查到一次就写一条与它自己详情页相同的查看记录(委外订货单详情或委外申请详情, 对象名称标
     * AI 助手查询); 看不到的单、不存在的单号、用不了工具与复核旧回答都不写。
     */
    @Test
    void eachSuccessfulReadLeavesItsOwnDetailViewRecordAndARefusedOneLeavesNone() {
        actAs(colleague);
        tool.execute(Map.of("documentNo", orderNo));
        tool.execute(Map.of("documentNo", "EO20991231999999"));
        actAs(outsider);
        assertForbidden(() -> tool.execute(Map.of("documentNo", orderNo)));
        assertThat(viewRecords(colleague)).isEmpty();
        assertThat(viewRecords(outsider)).isEmpty();
        assertThat(views("subcontract_orders", orderId)).isEmpty();

        // The colleague may see the application (no owner isolation), so that read is recorded under the colleague.
        actAs(colleague);
        tool.execute(Map.of("documentNo", applicationNo));
        assertThat(viewRecords(colleague)).singleElement().satisfies(view -> {
            assertThat(view.get("action")).isEqualTo("view_subcontract_application_detail");
            assertThat(view.get("target_type")).isEqualTo("subcontract_applications");
            assertThat(view.get("target_id")).isEqualTo(applicationId.toString());
            assertThat(view.get("display")).isEqualTo("委外申请单(AI 助手查询)");
            assertThat(view.get("code")).isEqualTo(applicationNo);
        });

        actAs(owner);
        Map<String, Object> result = tool.execute(Map.of("documentNo", orderNo));
        assertThat(viewRecords(owner)).singleElement().satisfies(view -> {
            assertThat(view.get("action")).isEqualTo("view_subcontract_order_detail");
            assertThat(view.get("target_type")).isEqualTo("subcontract_orders");
            assertThat(view.get("target_id")).isEqualTo(orderId.toString());
            assertThat(view.get("display")).isEqualTo("委外订货单(AI 助手查询)");
            assertThat(view.get("code")).isEqualTo(orderNo);
            assertThat(view.get("result")).isEqualTo("success");
        });
        // A re-check of the stored answer is not a new read.
        tool.authorizeResultRead(evidence(result));
        assertThat(views("subcontract_orders", orderId)).hasSize(1);
        assertThat(views("subcontract_applications", applicationId)).hasSize(1);
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

    /** Detail-view records of one fixture document by anyone. */
    private List<Map<String, Object>> views(String table, UUID id) {
        return jdbc.queryForList("""
                SELECT actor_id FROM audit_log WHERE target_type = ? AND target_id = ? AND left(action, 5) = 'view_'
                """, table, id.toString());
    }
}
