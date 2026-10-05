package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Savepoint;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * V798(ADR-143 委外按工序领直属物料与分批回厂)在「从空库 Flyway 迁到头」的真实库上的数据库层验收。
 *
 * <p>把 DB 切片用 psql 草稿库验证过的脚本搬成可重复的契约测试:
 * functional.sql(领料数量口径、草稿行守卫、逐种物料回厂守恒、结束领料)、
 * functional_lots.sql(顶层委外件 depth=1 精确批次在两个订货明细间分摊并经血缘守卫接管)、
 * sanity.sql(读函数冒烟与 f/sets 互逆)、nb_zero_line.sql 与 sr_zero_line_receipt.sql
 * (没有计划行的明细一律 fail-closed)、rf_legacy_receipt.sql(老库导入的已审核回厂行没有冻结物料口径也放行,
 * 新流程行仍必须带口径)、rf_warehouse_dropped.sql(仓库整行删掉的领料行 = 软删 + warehouse_dropped_at, 申领量保留、
 * 哪里都不再计数), 外加: 被删对象确实不存在、后置扫描(任何幸存函数/视图/约束/
 * 索引/触发器不再引用被删名字)、委外领料权限点的目录行、页面权限面绑定与授予范围。
 *
 * <p>每个用例在克隆库里开一个事务, 结束时整体回滚; 主档(部门/员工/账号/单位/货品/BOM/仓库)按真实触发器
 * 写入, 委外订单头等与长链路外键相关的夹具行与脚本一样在 replica 角色下直写, 被测动作一律在 origin 角色下
 * 走真实守卫。延迟约束触发器只在提交时触发, 回滚的事务里不验证它们(与原脚本一致)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractStepDrawMigrationPostgresTest {

    private static final AtomicInteger SEQUENCE = new AtomicInteger();
    private static MigratedSchemaBaseline.ScopedDatabase database;

    private Connection db;

    @BeforeAll
    static void openDatabase() throws SQLException {
        database = MigratedSchemaBaseline.openDatabase("sc_step_draw_v798");
    }

    @AfterAll
    static void closeDatabase() throws SQLException {
        if (database != null) {
            database.close();
        }
    }

    @BeforeEach
    void connect() throws SQLException {
        db = database.openConnection();
        db.setAutoCommit(false);
    }

    @AfterEach
    void rollback() throws SQLException {
        if (db != null) {
            try {
                db.rollback();
            } finally {
                db.close();
            }
        }
    }

    // ====================================================================================
    // functional.sql: 计划行插入守卫、行级数量口径、草稿行守卫、逐种物料回厂守恒、结束领料
    // ====================================================================================

    @Test
    void drawQuantitiesIssueLineGuardsAndPerMaterialReceiptConservation() throws SQLException {
        Fixture f = fixture("fn");
        UUID p = goods(f, "P", "委外");
        UUID x1 = goods(f, "X1", "采购");
        UUID x2 = goods(f, "X2", "采购");
        bom(p, x1, "2");
        bom(p, x2, "0.1");
        assertEquals(2, count("SELECT count(*) FROM fn_subcontract_draw_edges(?)", p),
                "两条按件、开工投入、按单领料的直属边都是可发外边");

        UUID orderId = UUID.randomUUID(), orderItem = UUID.randomUUID(), planId = UUID.randomUUID();
        UUID issueId = UUID.randomUUID(), receiptId = UUID.randomUUID(), receiptItem = UUID.randomUUID();
        replica(() -> {
            exec("INSERT INTO subcontract_orders(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 0)",
                    orderId, "T-V798-" + f.tag());
            exec("""
                    INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, goods_id, goods_snapshot_source,
                        qty, unit_rate, unit_id, line_no)
                    VALUES (?, ?, current_date, ?, ?, 'MASTER_AT_SAVE', 10, 1, ?, 1)
                    """, orderItem, "T-V798-" + f.tag(), orderId, p, f.unit());
            exec("INSERT INTO subcontract_material_plans(id, order_id, order_bill_no) VALUES (?, ?, ?)",
                    planId, orderId, "T-V798-" + f.tag());
        });

        // A. 计划行插入守卫: 计划量必须 = f(Q, b) = CEIL(10 × 2, 4) = 20, 写 21 被拒。
        expectViolation("计划量不等于 f(Q,b) 的计划行", null, """
                INSERT INTO subcontract_material_plan_items(plan_id, order_item_id, line_no, parent_goods_id, goods_id,
                    color_id, unit_id, unit_rate, bom_unit_qty, planned_qty)
                VALUES (?, ?, 1, ?, ?, NULL, ?, 1, 2, 21)
                """, planId, orderItem, p, x1, f.unit());
        // 冻结的物料必须是可发外直属边: 拿父件自己当物料被拒。
        expectViolation("不是可发外直属边的计划行", null, """
                INSERT INTO subcontract_material_plan_items(plan_id, order_item_id, line_no, parent_goods_id, goods_id,
                    color_id, unit_id, unit_rate, bom_unit_qty, planned_qty)
                VALUES (?, ?, 1, ?, ?, NULL, ?, 1, 2, 20)
                """, planId, orderItem, p, p, f.unit());
        UUID line1 = UUID.randomUUID(), line2 = UUID.randomUUID();
        exec("""
                INSERT INTO subcontract_material_plan_items(id, plan_id, order_item_id, line_no, parent_goods_id, goods_id,
                    color_id, unit_id, unit_rate, bom_unit_qty, planned_qty)
                VALUES (?, ?, ?, 1, ?, ?, NULL, ?, 1, 2, 20),
                       (?, ?, ?, 2, ?, ?, NULL, ?, 1, 0.1, 1)
                """, line1, planId, orderItem, p, x1, f.unit(), line2, planId, orderItem, p, x2, f.unit());

        // B. 没有库存: 可领 0, 还缺 10, 两种物料。
        Map<String, Object> s = summary(orderItem);
        qty("0", s.get("drawable_qty"), "B 无库存可领");
        qty("10", s.get("short_qty"), "B 无库存还缺");
        assertEquals(2, ((Number) s.get("material_kind_count")).intValue(), "B 物料种数");
        assertIdentity(s, "B");

        // C. X1 15 (够 7.5 套)、X2 0.55 (够 5.5 套): 按短板可领 5.5, 还缺 4.5, 两种都不算已备。
        replica(() -> exec("""
                INSERT INTO stock_balances(goods_id, color_id, warehouse_id, qty)
                VALUES (?, NULL, ?, 15), (?, NULL, ?, 0.55)
                """, x1, f.warehouse(), x2, f.warehouse()));
        s = summary(orderItem);
        qty("5.5", s.get("drawable_qty"), "C 可领按短板物料 X2");
        qty("4.5", s.get("short_qty"), "C 还缺");
        qty("5.5", s.get("reachable_qty"), "C 可达套数");
        assertEquals(0, ((Number) s.get("ready_kind_count")).intValue(), "C 两种物料都还缺");
        assertIdentity(s, "C");

        // D. 绑定计划行的发料行: 必须带 requested_qty、qty ≤ requested_qty、物料身份与计划行一致、requested_qty 不可改。
        replica(() -> exec("""
                INSERT INTO subcontract_material_issues(id, bill_no, bill_date, status, warehouse_id)
                VALUES (?, ?, current_date, 0, ?)
                """, issueId, "T-V798-I-" + f.tag(), f.warehouse()));
        expectViolation("D1 计划行发料行缺 requested_qty", null, """
                INSERT INTO subcontract_material_issue_items(bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id)
                VALUES ('T', current_date, ?, ?, ?, NULL, ?, 1, 11, 'MASTER_AT_SAVE', ?)
                """, issueId, orderItem, x1, f.unit(), line1);
        expectViolation("D2 发料量超过 requested_qty", null, """
                INSERT INTO subcontract_material_issue_items(bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id, requested_qty)
                VALUES ('T', current_date, ?, ?, ?, NULL, ?, 1, 12, 'MASTER_AT_SAVE', ?, 11)
                """, issueId, orderItem, x1, f.unit(), line1);
        expectViolation("D3 发料行物料与计划行不一致", null, """
                INSERT INTO subcontract_material_issue_items(bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id, requested_qty)
                VALUES ('T', current_date, ?, ?, ?, NULL, ?, 1, 11, 'MASTER_AT_SAVE', ?, 11)
                """, issueId, orderItem, x2, f.unit(), line1);
        UUID item1 = UUID.randomUUID(), item2 = UUID.randomUUID();
        exec("""
                INSERT INTO subcontract_material_issue_items(id, bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id, requested_qty)
                VALUES (?, 'T', current_date, ?, ?, ?, NULL, ?, 1, 11, 'MASTER_AT_SAVE', ?, 11),
                       (?, 'T', current_date, ?, ?, ?, NULL, ?, 1, 0.55, 'MASTER_AT_SAVE', ?, 0.55)
                """, item1, issueId, orderItem, x1, f.unit(), line1, item2, issueId, orderItem, x2, f.unit(), line2);
        expectViolation("D4 requested_qty 写入后不可改", null,
                "UPDATE subcontract_material_issue_items SET requested_qty = 12 WHERE id = ?", item1);
        exec("UPDATE subcontract_material_issue_items SET qty = 10 WHERE id = ?", item1); // 仓库改少
        exec("UPDATE subcontract_material_issue_items SET qty = 11 WHERE id = ?", item1); // 改回 ≤ requested
        qty("0", scalar("SELECT fn_subcontract_take_component_entitlements(?, ?, ?, 11, ?)",
                line1, issueId, f.warehouse(), f.user()), "没有精确专属批次时接管量为 0");

        // E. 草稿: 待仓库发 5.5 套, 已领 0, 已覆盖 5.5。
        s = summary(orderItem);
        qty("5.5", s.get("pending_qty"), "E 待仓库发");
        qty("0", s.get("drawn_qty"), "E 已领");
        qty("5.5", s.get("complete_qty"), "E 已覆盖套数");
        assertIdentity(s, "E");
        Map<String, Object> fact1 = one("SELECT * FROM fn_subcontract_draw_facts(?) WHERE plan_item_id = ?", orderItem, line1);
        qty("11", fact1.get("pending_qty"), "E X1 待发");
        assertEquals(Boolean.TRUE, fact1.get("line_open"), "E 行开放");

        // F. 审核发出(只验数量口径): 已领 5.5, 可回厂套数 5.5。
        replica(() -> {
            exec("UPDATE subcontract_material_issues SET status = 1 WHERE id = ?", issueId);
            exec("UPDATE subcontract_material_issue_items SET at_supplier_qty = qty WHERE issue_id = ?", issueId);
            exec("UPDATE subcontract_material_plan_items SET issued_qty = 11 WHERE id = ?", line1);
            exec("UPDATE subcontract_material_plan_items SET issued_qty = 0.55 WHERE id = ?", line2);
        });
        s = summary(orderItem);
        qty("5.5", s.get("drawn_qty"), "F 已领");
        qty("0", s.get("pending_qty"), "F 待仓库发");
        assertIdentity(s, "F");
        qty("5.5", scalar("SELECT fn_subcontract_returnable_qty(?)", orderItem), "F 可回厂套数 = 委外商处物料短板");

        // G. 回厂 3 套: 逐种核销 f(3, b) = X1 6 / X2 0.3, 守恒通过且成本完整。
        replica(() -> {
            exec("INSERT INTO subcontract_receipts(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 1)",
                    receiptId, "T-V798-R-" + f.tag());
            exec("""
                    INSERT INTO subcontract_receipt_items(id, bill_no, bill_date, receipt_id, order_item_id, goods_id,
                        goods_snapshot_source, qty, unit_rate, material_basis_qty)
                    VALUES (?, 'T', current_date, ?, ?, ?, 'MASTER_AT_SAVE', 3, 1, 3)
                    """, receiptItem, receiptId, orderItem, p);
            exec("UPDATE subcontract_material_issue_items SET consumed_qty = 6 WHERE id = ?", item1);
            exec("UPDATE subcontract_material_issue_items SET consumed_qty = 0.3 WHERE id = ?", item2);
        });
        exec("SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        assertEquals(Boolean.TRUE, scalar("SELECT fn_subcontract_receipt_material_complete(?)", receiptItem),
                "G 每种冻结物料都核销到 f(R) 时成本完整");
        Map<String, Object> basis = one("SELECT * FROM fn_subcontract_receipt_basis(?)", orderItem);
        qty("3", basis.get("basis_qty"), "G 物料口径回厂 R");
        assertEquals(0, ((Number) basis.get("reversed_line_count")).intValue(), "G 没有红冲行");
        // 一种物料核销不足(0.2 ≠ f(3, 0.1)=0.3)即拒绝, 成本不完整。
        exec("UPDATE subcontract_material_issue_items SET consumed_qty = 0.2 WHERE id = ?", item2);
        expectViolation("G2 X2 核销与目标差超过红冲容差", null,
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        assertEquals(Boolean.FALSE, scalar("SELECT fn_subcontract_receipt_material_complete(?)", receiptItem),
                "G3 有一种物料没核销到目标就不完整");
        exec("UPDATE subcontract_material_issue_items SET consumed_qty = 0.3 WHERE id = ?", item2);

        // H. 冻结口径比回厂量少 1, 但既没有质检补回也没有财务批准自带料: 拒绝。
        exec("UPDATE subcontract_receipt_items SET material_basis_qty = 2 WHERE id = ?", receiptItem);
        expectViolation("H 物料口径净额超出质检补回与财务批准自带料", "nets more than",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        exec("UPDATE subcontract_receipt_items SET material_basis_qty = 3 WHERE id = ?", receiptItem);

        // I. 结束领料必须写原因; 两行都结束后不再开放、不再可领, 视为已发完。
        expectViolation("I 结束领料没有原因", null,
                "UPDATE subcontract_material_plan_items SET draw_closed_at = now() WHERE id = ?", line1);
        exec("""
                UPDATE subcontract_material_plan_items SET draw_closed_at = now(), draw_close_reason = '物料停用'
                WHERE id IN (?, ?)
                """, line1, line2);
        s = summary(orderItem);
        assertEquals(Boolean.FALSE, s.get("any_open"), "I 没有开放行");
        qty("0", s.get("drawable_qty"), "I 可领");
        assertEquals(Boolean.TRUE, s.get("all_sent"), "I 结束领料的行视为已发完");
        assertIdentity(s, "I");
    }

    // ====================================================================================
    // functional_lots.sql: 顶层委外件(ROOT_SUPPLY)的 depth=1 精确批次在两个订货明细间分摊, 经血缘守卫接管
    // ====================================================================================

    @Test
    void rootSupplyExactLotsArePartitionedAcrossOrderItemsAndTakenWithTheirLineage() throws SQLException {
        Fixture f = fixture("lots");
        UUID p = goods(f, "P", "委外");
        UUID child = goods(f, "C", "采购");
        bom(p, child, "2");
        UUID edge = (UUID) scalar("SELECT edge_id FROM fn_subcontract_draw_edges(?)", p);
        assertNotNull(edge, "P 必须有一条可发外直属边");

        // 与 functional_lots.sql 相同的固定主键: 认领区间按 (order_item_id, application_item_id, parent_material_id) 排序。
        UUID an = id("a01"), ai = id("a02"), pn = id("a03"), ca = id("a04"), sa = id("a05"), sai = id("a06");
        UUID act = id("a07"), al = id("a08"), orderId = id("b01"), oi1 = id("b11"), oi2 = id("b12");
        UUID planId = id("b21"), line1 = id("b31"), line2 = id("b32");
        UUID res = id("c01"), ev = id("c02"), issueId = id("c03"), issueItem = id("c04");
        replica(() -> {
            exec("""
                    INSERT INTO production_material_analyses(id, fingerprint, initial_idempotency_key, maker_id, warehouse_id,
                        participating_warehouse_ids)
                    VALUES (?, repeat('a', 64), ?, ?, ?, ARRAY[CAST(? AS uuid)])
                    """, an, "k-v798-analysis-" + f.tag(), f.employee(), f.warehouse(), f.warehouse());
            exec("""
                    INSERT INTO production_material_analysis_items(id, analysis_id, goods_id, requested_qty, unit_id,
                        source_type, source_ref, source_reason)
                    VALUES (?, ?, ?, 10, ?, 'STOCK', 'T-V798', 'V798 test')
                    """, ai, an, p, f.unit());
            exec("""
                    INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id, depth, goods_id,
                        node_key, path, per_product_qty, required_qty, source_suggestion, unit_id, node_role, active)
                    VALUES (?, ?, ?, 0, ?, 'ROOT', 'ROOT', 1, 10, 'SUBCONTRACT', ?, 'ROOT_SUPPLY', TRUE)
                    """, pn, an, ai, p, f.unit());
            exec("""
                    INSERT INTO production_material_analysis_materials(id, analysis_id, analysis_item_id, depth, goods_id,
                        color_id, node_key, path, per_product_qty, required_qty, source_suggestion, unit_id, node_role,
                        active, bom_item_id)
                    VALUES (?, ?, ?, 1, ?, NULL, 'A', 'A', 2, 20, 'BUY', ?, 'BOM_COMPONENT', TRUE, ?)
                    """, ca, an, ai, child, f.unit(), edge);
            exec("INSERT INTO subcontract_applications(id, bill_no, bill_date) VALUES (?, ?, current_date)",
                    sa, "T-SA-" + f.tag());
            exec("""
                    INSERT INTO subcontract_application_items(id, application_id, bill_no, bill_date, goods_id,
                        goods_snapshot_source, qty, unit_rate)
                    VALUES (?, ?, ?, current_date, ?, 'MASTER_AT_SAVE', 10, 1)
                    """, sai, sa, "T-SA-" + f.tag(), p);
            exec("""
                    INSERT INTO preplan_supply_actions(id, action_group_key, analysis_id, created_by, goods_id, idempotency_key,
                        request_business_key, request_hash, requested_qty, route, unit_id, warehouse_id, status,
                        operation_type, external_document_type, external_document_id)
                    VALUES (?, repeat('a', 64), ?, ?, ?, ?, repeat('b', 64), repeat('c', 64), 10, 'SUBCONTRACT', ?, ?,
                        'CREATED', 'SUPPLY', 'SUBCONTRACT_APPLICATION', ?)
                    """, act, an, f.user(), p, "k-act-v798-" + f.tag(), f.unit(), f.warehouse(), sa);
            exec("""
                    INSERT INTO preplan_supply_action_allocations(id, action_id, allocated_qty, analysis_id,
                        analysis_material_id, external_item_id)
                    VALUES (?, ?, 10, ?, ?, ?)
                    """, al, act, an, pn, sai);
            exec("INSERT INTO subcontract_orders(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 0)",
                    orderId, "T-V798-L-" + f.tag());
            exec("""
                    INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, goods_id, goods_snapshot_source,
                        qty, unit_rate, unit_id, line_no)
                    VALUES (?, ?, current_date, ?, ?, 'MASTER_AT_SAVE', 6, 1, ?, 1),
                           (?, ?, current_date, ?, ?, 'MASTER_AT_SAVE', 4, 1, ?, 2)
                    """, oi1, "T-V798-L-" + f.tag(), orderId, p, f.unit(), oi2, "T-V798-L-" + f.tag(), orderId, p, f.unit());
            exec("""
                    INSERT INTO subcontract_order_item_sources(order_item_id, application_item_id, alloc_qty, line_no)
                    VALUES (?, ?, 6, 1), (?, ?, 4, 1)
                    """, oi1, sai, oi2, sai);
            exec("INSERT INTO subcontract_material_plans(id, order_id, order_bill_no) VALUES (?, ?, ?)",
                    planId, orderId, "T-V798-L-" + f.tag());
            exec("INSERT INTO stock_balances(goods_id, color_id, warehouse_id, qty) VALUES (?, NULL, ?, 15)",
                    child, f.warehouse());
            exec("""
                    INSERT INTO stock_reservations(id, goods_id, color_id, warehouse_id, qty, consumed_qty, released_qty, status,
                        owner_type, owner_id, purpose, supply_type, supply_id, idempotency_key)
                    VALUES (?, ?, NULL, ?, 15, 0, 0, 0, 'PREPLAN_ANALYSIS', ?, 'PREPLAN_MATERIAL',
                        'PURCHASE_REQUEST_ITEM', gen_random_uuid(), ?)
                    """, res, child, f.warehouse(), an, "k-res-" + f.tag());
            exec("""
                    INSERT INTO preplan_stock_entitlement_events(id, beneficiary_analysis_id, beneficiary_analysis_material_id,
                        event_group_id, event_type, idempotency_key, qty, stock_reservation_id, created_by)
                    VALUES (?, ?, ?, gen_random_uuid(), 'ORIGIN_IQC', ?, 15, ?, ?)
                    """, ev, an, ca, "k-ev-v798-" + f.tag(), res, f.user());
        });
        exec("""
                INSERT INTO subcontract_material_plan_items(id, plan_id, order_item_id, line_no, parent_goods_id, goods_id,
                    color_id, unit_id, unit_rate, bom_unit_qty, planned_qty)
                VALUES (?, ?, ?, 1, ?, ?, NULL, ?, 1, 2, 12),
                       (?, ?, ?, 1, ?, ?, NULL, ?, 1, 2, 8)
                """, line1, planId, oi1, p, child, f.unit(), line2, planId, oi2, p, child, f.unit());

        // 15 个专属批次按两个订货明细的冻结需求依次分摊: 第一个 6×2=12, 第二个只剩 3。
        assertLots(oi1, line1, "12");
        assertLots(oi2, line2, "3");
        Map<String, Object> stock1 = one("SELECT * FROM fn_subcontract_draw_line_stock(?)", line1);
        qty("12", stock1.get("exact_qty"), "line1 精确批次");
        qty("0", stock1.get("public_qty"), "专属批次已被分析预留, 不算公共可用");
        qty("6", summary(oi1).get("drawable_qty"), "订货明细 1 可领 12/2 = 6 套");
        qty("1.5", summary(oi2).get("drawable_qty"), "订货明细 2 可领 3/2 = 1.5 套");

        replica(() -> exec("""
                INSERT INTO subcontract_material_issues(id, bill_no, bill_date, status, warehouse_id)
                VALUES (?, ?, current_date, 0, ?)
                """, issueId, "T-V798-LI-" + f.tag(), f.warehouse()));
        exec("""
                INSERT INTO subcontract_material_issue_items(id, bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id, requested_qty)
                VALUES (?, 'T', current_date, ?, ?, ?, NULL, ?, 1, 12, 'MASTER_AT_SAVE', ?, 12)
                """, issueItem, issueId, oi1, child, f.unit(), line1);
        qty("12", scalar("SELECT fn_subcontract_take_component_entitlements(?, ?, ?, 12, ?)",
                line1, issueId, f.warehouse(), f.user()), "按冻结计划行接管 12 个专属批次");

        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_component_entitled_lots(?)", oi1),
                "接管后订货明细 1 不再有可接管批次");
        assertLots(oi2, line2, "3");
        Map<String, Object> handoff = one("""
                SELECT qty, application_item_id, plan_item_id, target_reservation_id
                FROM subcontract_component_stock_handoffs WHERE plan_item_id = ?
                """, line1);
        qty("12", handoff.get("qty"), "交接量");
        assertEquals(sai, handoff.get("application_item_id"), "交接记录指回来源委外申请明细");
        Map<String, Object> source = one("""
                SELECT released_qty, release_reason, status FROM stock_reservations WHERE id = ?
                """, res);
        qty("12", source.get("released_qty"), "原分析预留释放 12");
        assertEquals("TRANSFERRED_TO_SUBCONTRACT", source.get("release_reason"), "释放原因");
        Map<String, Object> target = one("""
                SELECT qty, owner_type, owner_id, source_doc_type, source_doc_id
                FROM stock_reservations WHERE id = ?
                """, handoff.get("target_reservation_id"));
        qty("12", target.get("qty"), "领料草稿的目标预留");
        assertEquals("SUBCONTRACT_OUTBOUND", target.get("owner_type"));
        assertEquals(line1, target.get("owner_id"), "目标预留挂在冻结计划行上");
        assertEquals("SUBCONTRACT_OUTBOUND_DRAFT", target.get("source_doc_type"));
        assertEquals(issueId, target.get("source_doc_id"), "目标预留的来源单据是这张领料草稿");
    }

    // ====================================================================================
    // sanity.sql: f / sets 互逆、读函数对未知主键的空结果、新权限与触发器存在
    // ====================================================================================

    @Test
    void readFunctionsAreTotalAndTheSetsMaterialFunctionsAreExactInverses() throws SQLException {
        Map<String, Object> math = one("""
                SELECT fn_subcontract_draw_f(3, 0.333333) AS f_3, fn_subcontract_draw_sets(1.0000, 0.333333) AS sets_1,
                       fn_subcontract_draw_f(1, 0.12341) AS f_1, fn_subcontract_draw_sets(0.1235, 0.12341) AS sets_back,
                       fn_subcontract_draw_f(2, 0.00122) AS f_2, fn_subcontract_draw_sets(0.0025, 0.00122) AS sets_2,
                       fn_subcontract_draw_sets(5, 0) AS sets_zero_b
                """);
        qty("1", math.get("f_3"), "f(3, 0.333333) = CEIL(0.999999, 4)");
        qty("3", math.get("sets_1"), "sets(1, 0.333333) = TRUNC(3.000003, 4)");
        qty("0.1235", math.get("f_1"), "f(1, 0.12341) = CEIL(0.12341, 4)");
        qty("1.0007", math.get("sets_back"), "sets(0.1235, 0.12341) = TRUNC(1.000729.., 4)");
        qty("0.0025", math.get("f_2"), "f(2, 0.00122) = CEIL(0.00244, 4)");
        qty("2.0491", math.get("sets_2"), "sets(0.0025, 0.00122) = TRUNC(2.04918.., 4)");
        assertNull(math.get("sets_zero_b"), "单耗为 0 时套数无定义");
        // 0.0001 网格上 f(S) ≤ x ⟺ S ≤ sets(x)。
        assertEquals(0L, ((Number) scalar("""
                SELECT count(*)
                FROM generate_series(0, 400) s_step, (VALUES (0.333333), (0.12341), (2), (0.00122), (1.5)) b(b),
                     generate_series(0, 60) x_step
                WHERE (fn_subcontract_draw_f(s_step / 10000.0 * 7, b.b) <= x_step / 20.0)
                      <> (s_step / 10000.0 * 7 <= fn_subcontract_draw_sets(x_step / 20.0, b.b))
                """)).longValue(), "f 与 sets 必须是同一网格上的互逆函数");

        UUID unknown = UUID.randomUUID();
        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_draw_edges(?)", unknown));
        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_component_entitled_lots(?)", unknown));
        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_draw_line_stock(?)", unknown));
        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_draw_facts(?)", unknown));
        assertEquals(0, count("SELECT count(*) FROM fn_subcontract_draw_summary(?)", unknown));
        qty("0", scalar("SELECT fn_subcontract_returnable_qty(?)", unknown), "未知明细可回厂 0(不是 NULL)");
        Map<String, Object> basis = one("SELECT * FROM fn_subcontract_receipt_basis(?)", unknown);
        qty("0", basis.get("basis_qty"), "未知明细回厂口径 0");
        assertEquals(Boolean.FALSE, scalar("SELECT fn_subcontract_receipt_material_complete(?)", unknown),
                "未知回厂行不算成本完整");
        // 仓库通知可见性(V796)在 V798 改为按领料草稿解析仓库: 对未知草稿也必须能正常求值。
        exec("""
                SELECT fn_notice_warehouse_visible(?, 'SUBCONTRACT_OUTBOUND_READY', 'SUBCONTRACT_MATERIAL_ISSUE', ?,
                    '/warehouse/subcontract-outbound/' || ?, 'notice:read,subcontract_outbound:view,subcontract_outbound:execute')
                """, UUID.randomUUID(), unknown, unknown.toString());

        Map<String, Object> triggers = new LinkedHashMap<>();
        for (Map<String, Object> row : rows("""
                SELECT t.tgname, t.tgenabled FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                WHERE c.relname = 'subcontract_material_issue_items'
                  AND t.tgname IN ('trg_guard_subcontract_draw_issue_item', 'trg_guard_subcontract_draw_issue_item_upd')
                """)) {
            triggers.put((String) row.get("tgname"), String.valueOf(row.get("tgenabled")));
        }
        assertEquals("A", triggers.get("trg_guard_subcontract_draw_issue_item"),
                "领料草稿行插入守卫必须 ENABLE ALWAYS(复制角色下也生效)");
        assertEquals("A", triggers.get("trg_guard_subcontract_draw_issue_item_upd"),
                "领料草稿行更新守卫必须 ENABLE ALWAYS");
    }

    // ====================================================================================
    // nb_zero_line.sql + sr_zero_line_receipt.sql: 没有计划行的明细一律 fail-closed
    // ====================================================================================

    @Test
    void anOrderItemWithoutPlanLinesHasNothingDrawableNothingReturnableAndNoCompleteCost() throws SQLException {
        Fixture f = fixture("zero");
        UUID p = goods(f, "P", "委外");
        UUID orderId = UUID.randomUUID(), orderItem = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID(), receiptItem = UUID.randomUUID();
        replica(() -> {
            exec("INSERT INTO subcontract_orders(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 0)",
                    orderId, "T-ZERO-" + f.tag());
            exec("""
                    INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, goods_id, goods_snapshot_source,
                        qty, unit_rate, unit_id, line_no)
                    VALUES (?, ?, current_date, ?, ?, 'MASTER_AT_SAVE', 10, 1, ?, 1)
                    """, orderItem, "T-ZERO-" + f.tag(), orderId, p, f.unit());
        });

        qty("0", scalar("SELECT fn_subcontract_returnable_qty(?)", orderItem), "没有计划行: 可回厂 0, 不是 NULL");
        Map<String, Object> s = summary(orderItem);
        for (String column : List.of("material_kind_count", "ready_kind_count", "drawn_qty", "pending_qty",
                "drawable_qty", "short_qty", "complete_qty", "reachable_qty")) {
            qty("0", s.get(column), "没有计划行: " + column);
        }
        assertEquals(Boolean.FALSE, s.get("all_covered"), "没有计划行不算已覆盖");
        assertEquals(Boolean.FALSE, s.get("all_sent"), "没有计划行不算已发完");
        assertEquals(Boolean.FALSE, s.get("any_open"), "没有计划行没有开放行");
        qty("10", s.get("order_qty"), "订货量照实返回");

        // 整行由质检补回 / 财务批准自带料支撑(物料口径 0): 走净额规则, 没有批准额度即拒绝。
        replica(() -> {
            exec("INSERT INTO subcontract_receipts(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 1)",
                    receiptId, "T-ZERO-R-" + f.tag());
            exec("""
                    INSERT INTO subcontract_receipt_items(id, bill_no, bill_date, receipt_id, order_item_id, goods_id,
                        goods_snapshot_source, qty, unit_rate, material_basis_qty)
                    VALUES (?, 'T', current_date, ?, ?, ?, 'MASTER_AT_SAVE', 3, 1, 0)
                    """, receiptItem, receiptId, orderItem, p);
        });
        assertEquals(Boolean.FALSE, scalar("SELECT fn_subcontract_receipt_material_complete(?)", receiptItem),
                "没有计划行的回厂行成本永远不完整");
        expectViolation("物料口径 0 且没有任何批准额度", "nets more than",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        replica(() -> exec("UPDATE subcontract_receipt_items SET material_basis_qty = 3 WHERE id = ?", receiptItem));
        expectViolation("没有计划行却有物料口径回厂", "no frozen draw plan lines",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        replica(() -> exec("UPDATE subcontract_receipt_items SET material_basis_qty = NULL WHERE id = ?", receiptItem));
        expectViolation("已审核回厂行缺冻结物料口径", "lacks its frozen material basis",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        replica(() -> exec("UPDATE subcontract_receipts SET status = -1 WHERE id = ?", receiptId));
        exec("SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        exec("SELECT fn_assert_subcontract_target_outbound_receipt(NULL)");
        assertEquals("上层 HVX1 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商",
                scalar("SELECT fn_workshop_direct_reason_text('SUBCONTRACT_ROUTE', NULL, 'HVX1', NULL, NULL, NULL, NULL)"),
                "车间直送 SUBCONTRACT_ROUTE 文案改为委外领料说法");
    }

    // ====================================================================================
    // 被删对象、后置扫描、重置策略
    // ====================================================================================

    @Test
    void retiredMakeFirstAndSoleComponentObjectsAreGoneAndNothingLiveStillNamesThem() throws SQLException {
        for (String relation : List.of(
                "preplan_subcontract_entitlement_handoff_slices", "preplan_subcontract_requirement_supply_claims",
                "preplan_subcontract_requirement_handoff_events", "preplan_subcontract_requirement_handoff_items",
                "preplan_subcontract_requirement_handoffs", "preplan_subcontract_make_batch_reversals",
                "preplan_subcontract_make_task_batches", "preplan_subcontract_make_tasks",
                "subcontract_outbound_preparation_commands",
                "v_preplan_subcontract_target_future_supply", "v_preplan_subcontract_requirement_supply_claim_state",
                "v_preplan_subcontract_parent_output_claim_balance", "v_preplan_subcontract_entitlement_handoff_slice_state",
                "v_preplan_subcontract_requirement_handoff_state", "v_subcontract_quantity_basis_issues")) {
            assertNull(scalar("SELECT to_regclass(?)::text", "public." + relation), "已删除的表/视图仍存在: " + relation);
        }
        for (String function : List.of(
                "fn_subcontract_sole_component_goods", "fn_subcontract_component_outbound_goods",
                "fn_subcontract_component_edges", "fn_subcontract_component_kit_capacity",
                "fn_subcontract_component_available_stock", "fn_workshop_direct_source_is_subcontract",
                "fn_guard_aggregate_subcontract_task", "fn_preplan_aggregate_subcontract_task_source",
                "fn_assert_subcontract_make_task_batches", "fn_subcontract_preparation_reservation_has_qualified_origin")) {
            assertEquals(0, count("""
                    SELECT count(*) FROM pg_proc WHERE proname = ? AND pronamespace = 'public'::regnamespace
                    """, function), "已删除的函数仍存在: " + function);
        }
        assertNull(scalar("SELECT to_regprocedure('fn_subcontract_component_entitled_lots(uuid,uuid)')::text"),
                "旧两参数版精确批次函数必须删除");
        assertNotNull(scalar("SELECT to_regprocedure('fn_subcontract_component_entitled_lots(uuid)')::text"),
                "按订货明细计算的精确批次函数必须存在");
        for (String function : List.of("fn_subcontract_draw_f(numeric,numeric)", "fn_subcontract_draw_sets(numeric,numeric)",
                "fn_subcontract_draw_edges(uuid)", "fn_subcontract_draw_line_stock(uuid)", "fn_subcontract_draw_facts(uuid)",
                "fn_subcontract_draw_summary(uuid)", "fn_subcontract_returnable_qty(uuid)",
                "fn_subcontract_supplier_own_qty(uuid)", "fn_subcontract_material_qty(uuid)",
                "fn_subcontract_draw_needed_qty(uuid,numeric,numeric)",
                "fn_subcontract_receipt_basis(uuid)", "fn_subcontract_receipt_material_complete(uuid)",
                "fn_subcontract_take_component_entitlements(uuid,uuid,uuid,numeric,uuid)")) {
            assertNotNull(scalar("SELECT to_regprocedure(?)::text", function), "V798 读函数缺失: " + function);
        }

        List<String> retiredColumns = new ArrayList<>();
        for (Map<String, Object> row : rows("""
                SELECT table_name || '.' || column_name AS name FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND ((table_name = 'subcontract_material_plan_items' AND column_name IN (
                            'flow_mode', 'prepared_qty', 'preparation_status', 'preparation_warehouse_id',
                            'preparation_bom_fingerprint', 'preparation_analysis_id', 'preparation_analysis_item_id',
                            'preparation_started_by', 'preparation_started_at', 'preparation_version',
                            'bom_has_children_snapshot', 'loss_replacement_qty_base'))
                    OR (table_name = 'production_material_analysis_items'
                        AND column_name IN ('subcontract_order_item_id', 'subcontract_order_qty_base')))
                """)) {
            retiredColumns.add((String) row.get("name"));
        }
        assertTrue(retiredColumns.isEmpty(), "已删除的列仍存在: " + retiredColumns);
        for (String[] column : List.of(
                new String[]{"subcontract_material_plan_items", "draw_closed_at"},
                new String[]{"subcontract_material_plan_items", "draw_closed_by"},
                new String[]{"subcontract_material_plan_items", "draw_close_reason"},
                new String[]{"subcontract_material_issue_items", "requested_qty"},
                new String[]{"subcontract_receipt_items", "material_basis_qty"},
                new String[]{"subcontract_draw_notice_marks", "notified_drawable"},
                new String[]{"subcontract_draw_notice_marks", "epoch"})) {
            assertEquals(1, count("""
                    SELECT count(*) FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = ? AND column_name = ?
                    """, column[0], column[1]), "V798 新列缺失: " + column[0] + "." + column[1]);
        }
        assertEquals(1, count("SELECT count(*) FROM pg_constraint WHERE conname = 'preplan_aggregate_subcontract_external_chk'"),
                "汇总下单委外批次永远是外部批次的 CHECK 必须存在");

        // 后置扫描(与 V798 第 8 段同一口径): 迁到头之后任何幸存对象都不能再引用被删名字或取值。
        Object offending = scalar("""
                WITH patterns AS (
                    SELECT '\\m(preplan_subcontract_\\w+|subcontract_outbound_preparation_commands|v_subcontract_quantity_basis_issues'
                           || '|fn_subcontract_sole_component_goods|fn_subcontract_component_outbound_goods|fn_subcontract_component_edges'
                           || '|fn_subcontract_component_kit_capacity|fn_subcontract_component_available_stock'
                           || '|fn_workshop_direct_source_is_subcontract|fn_assert_subcontract_preparation_\\w+'
                           || '|fn_subcontract_preparation_reservation_has_qualified_origin|fn_preplan_aggregate_subcontract_task_source)\\M'
                           || '|fn_subcontract_component_entitled_lots\\s*\\(\\s*NULL' AS retired_names,
                           '''(SUBCONTRACT_MAKE|SUBCONTRACT_MAKE_TASK|SUBCONTRACT_PREPARATION|SUBCONTRACT_PREPARE_TASK'
                           || '|SUBCONTRACT_ORDER_PREPARATION|SUBCONTRACT_HANDOFF_IN|SUBCONTRACT_HANDOFF_OUT|MAKE_THEN_OUTBOUND'
                           || '|PREPARED_OUTBOUND|DIRECT_OUTBOUND|COMPONENT_OUTBOUND|LEGACY_BOM_COMPONENT|DIRECT_TARGET'
                           || '|subcontract_outbound:close)''' AS retired_values,
                           '\\m(flow_mode|prepared_qty|preparation_status|preparation_warehouse_id|preparation_bom_fingerprint'
                           || '|preparation_analysis_id|preparation_analysis_item_id|preparation_started_by|preparation_started_at'
                           || '|preparation_version|bom_has_children_snapshot|loss_replacement_qty_base)\\M' AS plan_columns,
                           '\\msubcontract_order_(item_id|qty_base)\\M' AS item_columns
                ), bodies AS (
                    SELECT 'function ' || p.oid::regprocedure::text AS name, p.prosrc AS body
                    FROM pg_proc p
                    WHERE p.pronamespace = 'public'::regnamespace
                      AND NOT EXISTS (SELECT 1 FROM pg_depend extension_member
                                      WHERE extension_member.classid = 'pg_proc'::regclass
                                        AND extension_member.objid = p.oid AND extension_member.deptype = 'e')
                    UNION ALL
                    SELECT 'view ' || c.relname, pg_get_viewdef(c.oid)
                    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('v', 'm')
                    UNION ALL
                    SELECT 'constraint ' || con.conrelid::regclass::text || '.' || con.conname, pg_get_constraintdef(con.oid)
                    FROM pg_constraint con WHERE con.connamespace = 'public'::regnamespace
                    UNION ALL
                    SELECT 'index ' || i.indexname, i.indexdef FROM pg_indexes i WHERE i.schemaname = 'public'
                    UNION ALL
                    SELECT 'trigger ' || t.tgrelid::regclass::text || '.' || t.tgname, pg_get_triggerdef(t.oid)
                    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                    WHERE NOT t.tgisinternal AND c.relnamespace = 'public'::regnamespace
                )
                SELECT string_agg(bodies.name, ', ' ORDER BY bodies.name)
                FROM bodies CROSS JOIN patterns
                WHERE bodies.body ~ patterns.retired_names
                   OR bodies.body ~ patterns.retired_values
                   OR (bodies.body ~ '\\msubcontract_material_plan_items\\M' AND bodies.body ~ patterns.plan_columns)
                   OR (bodies.body ~ '\\mproduction_material_analysis_items\\M' AND bodies.body ~ patterns.item_columns)
                """);
        assertNull(offending, "迁到头后仍有幸存对象引用被删的前置自制/唯一子件对象或取值: " + offending);

        assertTrue(((Number) scalar("""
                SELECT position('(''subcontract_draw_notice_marks'', ''CLEAR'')'
                                IN pg_get_functiondef('business_data_reset()'::regprocedure))
                """)).intValue() > 0, "显式测试清空必须清空可领提醒水位表");
        assertEquals(1, count("""
                SELECT count(*) FROM fn_goods_quantity_reference_sources() WHERE relation_name = 'subcontract_material_plan_items'
                """), "货品数量引用目录仍登记冻结计划行");
        assertEquals(0, count("""
                SELECT count(*) FROM fn_goods_quantity_reference_sources()
                WHERE to_regclass('public.' || relation_name) IS NULL
                """), "货品数量引用目录只能登记现存的表");
    }

    // ====================================================================================
    // 委外领料权限点
    // ====================================================================================

    @Test
    void drawPermissionIsCatalogedBoundToTheTaskCenterAndGrantedWhereverFinanceSubmitIs() throws SQLException {
        Map<String, Object> permission = one("""
                SELECT id, name, module, category, action_type, grant_policy::text AS grant_policy
                FROM permissions WHERE code = 'subcontract_order:draw'
                """);
        assertNotNull(permission, "委外领料权限点 subcontract_order:draw 必须存在");
        assertEquals("委外领料(提交、撤回、结束领料)", permission.get("name"), "权限名称用半角括号");
        assertEquals("委外管理", permission.get("module"));
        assertEquals("委外订货", permission.get("category"));
        assertEquals("EXECUTE", permission.get("action_type"));
        assertEquals(0, count("SELECT count(*) FROM permissions WHERE code = 'subcontract_outbound:close'"),
                "仓库「不再出仓」权限点随 ADR-143 退役");
        assertEquals(1, count("""
                SELECT count(*) FROM permission_surface_permissions mapping
                JOIN permission_surfaces surface ON surface.id = mapping.surface_id
                WHERE mapping.permission_id = ? AND surface.surface_key = 'operations.subcontract'
                """, permission.get("id")), "委外领料挂在委外任务中心页面权限面");

        List<String> departmentsMissingDraw = new ArrayList<>();
        for (Map<String, Object> row : rows("""
                SELECT holder.department_id::text AS department_id
                FROM department_permissions holder
                JOIN permissions submit ON submit.id = holder.permission_id AND submit.code = 'subcontract_order:submit_finance'
                WHERE NOT EXISTS (
                    SELECT 1 FROM department_permissions draw_grant
                    JOIN permissions draw ON draw.id = draw_grant.permission_id AND draw.code = 'subcontract_order:draw'
                    WHERE draw_grant.department_id = holder.department_id)
                """)) {
            departmentsMissingDraw.add((String) row.get("department_id"));
        }
        assertTrue(departmentsMissingDraw.isEmpty(),
                "能送财务的部门都必须能领料: " + departmentsMissingDraw);
        int submitDepartments = count("""
                SELECT count(DISTINCT holder.department_id) FROM department_permissions holder
                JOIN permissions submit ON submit.id = holder.permission_id AND submit.code = 'subcontract_order:submit_finance'
                """);
        int drawDepartments = count("""
                SELECT count(DISTINCT grant_row.department_id) FROM department_permissions grant_row
                JOIN permissions draw ON draw.id = grant_row.permission_id AND draw.code = 'subcontract_order:draw'
                """);
        assertTrue(drawDepartments >= submitDepartments,
                "领料授予部门数(" + drawDepartments + ")不能少于送财务授予部门数(" + submitDepartments + ")");
        assertEquals(0, count("""
                SELECT count(*) FROM user_permission_overrides holder
                JOIN permissions submit ON submit.id = holder.permission_id AND submit.code = 'subcontract_order:submit_finance'
                WHERE holder.effect = 'grant' AND holder.active
                  AND NOT EXISTS (
                      SELECT 1 FROM user_permission_overrides draw_grant
                      JOIN permissions draw ON draw.id = draw_grant.permission_id AND draw.code = 'subcontract_order:draw'
                      WHERE draw_grant.user_id = holder.user_id AND draw_grant.effect = 'grant' AND draw_grant.active)
                """), "个人加授了送财务的账号都必须同时加授领料");
        // 这些是系统种子授权配置, 不是业务事实: 空库(首导目标)迁移后部门授权不能留下永久记录身份或删除历史
        // (CLEAR 表), 否则首导守卫判「目标已有业务事实」; 两个保留触发器按 V775 原样恢复 ENABLE ALWAYS。
        assertEquals(0, count("SELECT count(*) FROM business_record_identities WHERE source_table = 'department_permissions'"),
                "V798 种子授权不绑定永久记录身份");
        assertEquals(0, count("SELECT count(*) FROM business_record_history WHERE source_table = 'department_permissions'"),
                "V798 退役「不再出仓」级联删的部门授权不留删除历史");
        assertEquals(2, count("""
                SELECT count(*) FROM pg_trigger
                WHERE tgrelid = 'department_permissions'::regclass
                  AND tgname IN ('trg_bind_business_record_parent', 'trg_retain_business_record')
                  AND tgenabled = 'A'
                """), "部门授权的永久记录触发器在 V798 之后仍是 ENABLE ALWAYS");
    }

    // ====================================================================================
    // rf_legacy_receipt.sql: 老库导入的已审核回厂行(legacy_id、没有冻结物料口径、明细没有计划行)
    // ====================================================================================

    @Test
    void aLegacyImportedApprovedReceiptLinePassesTheReceiptGuardWithoutFrozenBasisButANewFlowLineDoesNot()
            throws SQLException {
        Fixture f = fixture("legacy");
        UUID p = goods(f, "P", "委外");
        UUID orderId = UUID.randomUUID(), orderItem = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID(), receiptItem = UUID.randomUUID(), runId = UUID.randomUUID();
        UUID newReceiptId = UUID.randomUUID(), newReceiptItem = UUID.randomUUID();
        // 导入器自己的来源证明(fn_assert_legacy_receipt_import_source)不是这里要测的: 只为合成 INSERT 关掉这几个
        // 触发器, 并按导入器给导入单头写的值写 consideration_required = FALSE。V798 回厂守卫(ENABLE ALWAYS, 延迟)始终开着。
        exec("ALTER TABLE subcontract_receipts DISABLE TRIGGER trg_zz_legacy_receipt_source_facts");
        exec("ALTER TABLE subcontract_receipts DISABLE TRIGGER trg_subcontract_receipt_consideration_required");
        exec("ALTER TABLE subcontract_receipt_items DISABLE TRIGGER trg_zz_legacy_receipt_source_facts");
        replica(() -> {
            exec("""
                    INSERT INTO subcontract_orders(id, bill_no, bill_date, status, legacy_id)
                    VALUES (?, ?, current_date, 0, 990001)
                    """, orderId, "T-RF-LEGACY-" + f.tag());
            exec("""
                    INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, goods_id, goods_snapshot_source,
                        qty, unit_rate, unit_id, line_no, legacy_id)
                    VALUES (?, ?, current_date, ?, ?, 'LEGACY_IMPORT', 10, 1, ?, 1, 990002)
                    """, orderItem, "T-RF-LEGACY-" + f.tag(), orderId, p, f.unit());
            exec("""
                    INSERT INTO subcontract_receipts(id, bill_no, bill_date, status, legacy_id, legacy_import_run_id,
                        consideration_required)
                    VALUES (?, ?, current_date, 1, 990003, ?, FALSE)
                    """, receiptId, "T-RF-LEGACY-R-" + f.tag(), runId);
            exec("""
                    INSERT INTO subcontract_receipt_items(id, bill_no, bill_date, receipt_id, order_item_id, goods_id,
                        goods_snapshot_source, qty, unit_rate, unit_id, returned_qty, legacy_id, legacy_import_run_id)
                    VALUES (?, ?, current_date, ?, ?, ?, 'LEGACY_IMPORT', 5, 1, ?, 0, 990004, ?)
                    """, receiptItem, "T-RF-LEGACY-R-" + f.tag(), receiptId, orderItem, p, f.unit(), runId);
            // 导入器为每条导入的回厂行登记一条来源证明; 回厂表的 (run, id) 外键指向它。
            exec("ALTER TABLE legacy_procurement_receipt_import_sources DISABLE TRIGGER trg_guard_legacy_receipt_import_evidence");
            exec("""
                    INSERT INTO legacy_procurement_receipt_import_sources(run_id, source_kind, source_legacy_id, target_table,
                        target_id, source_file, source_row_sha256, source_file_sha256, target_fields,
                        target_snapshot_sha256, issued_txid)
                    SELECT ?, proof.kind, proof.legacy, proof.tbl, proof.target, 'rf_test.csv', repeat('a', 64),
                           repeat('b', 64), ARRAY['qty'], repeat('c', 64), txid_current()
                    FROM (VALUES ('SUBCONTRACT_HEADER', 990003, 'subcontract_receipts', CAST(? AS uuid)),
                                 ('SUBCONTRACT_ITEM', 990004, 'subcontract_receipt_items', CAST(? AS uuid)))
                         proof(kind, legacy, tbl, target)
                    """, runId, receiptId, receiptItem);
            exec("ALTER TABLE legacy_procurement_receipt_import_sources ENABLE ALWAYS TRIGGER trg_guard_legacy_receipt_import_evidence");
        });

        // RF 1 导入提交: 立即触发排队的全部延迟守卫(migrate_finalize_checks.sql 也是 SET CONSTRAINTS ALL IMMEDIATE)。
        exec("SET CONSTRAINTS ALL IMMEDIATE");
        exec("SET CONSTRAINTS ALL DEFERRED");
        assertNull(scalar("SELECT material_basis_qty FROM subcontract_receipt_items WHERE id = ?", receiptItem),
                "RF 1 导入行没有冻结物料口径");
        Map<String, Object> basis = one("SELECT * FROM fn_subcontract_receipt_basis(?)", orderItem);
        qty("0", basis.get("basis_qty"), "RF 1 导入行不计入物料口径回厂");
        assertEquals(0, ((Number) basis.get("reversed_line_count")).intValue(), "RF 1 没有红冲行");

        exec("ALTER TABLE subcontract_receipts ENABLE ALWAYS TRIGGER trg_zz_legacy_receipt_source_facts");
        exec("ALTER TABLE subcontract_receipts ENABLE ALWAYS TRIGGER trg_subcontract_receipt_consideration_required");
        exec("ALTER TABLE subcontract_receipt_items ENABLE ALWAYS TRIGGER trg_zz_legacy_receipt_source_facts");

        // RF 2 之后的委外退货在全部触发器生效(origin 角色)下改导入行的 returned_qty: 回厂守卫放行。
        exec("UPDATE subcontract_receipt_items SET returned_qty = 2 WHERE id = ?", receiptItem);
        exec("SET CONSTRAINTS ALL IMMEDIATE");
        exec("SET CONSTRAINTS ALL DEFERRED");
        qty("2", scalar("SELECT returned_qty FROM subcontract_receipt_items WHERE id = ?", receiptItem),
                "RF 2 导入行退货量已写入");

        // RF 3a 只有单头带来源(行上 legacy_id / run 都清空)也算导入。
        replica(() -> {
            exec("ALTER TABLE subcontract_receipt_items DISABLE TRIGGER trg_zz_legacy_receipt_source_facts");
            exec("UPDATE subcontract_receipt_items SET legacy_id = NULL, legacy_import_run_id = NULL WHERE id = ?",
                    receiptItem);
        });
        exec("SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
        // RF 3b 只有行上带 legacy_id(单头来源清空)也算导入。
        replica(() -> {
            exec("ALTER TABLE subcontract_receipts DISABLE TRIGGER trg_zz_legacy_receipt_source_facts");
            exec("UPDATE subcontract_receipt_items SET legacy_id = 990004 WHERE id = ?", receiptItem);
            exec("UPDATE subcontract_receipts SET legacy_id = NULL, legacy_import_run_id = NULL WHERE id = ?", receiptId);
        });
        exec("SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);

        // RF 4 没有任何来源时同一行就是新流程行, 必须带冻结物料口径。
        replica(() -> exec("UPDATE subcontract_receipt_items SET legacy_id = NULL WHERE id = ?", receiptItem));
        expectViolation("RF 4 新流程已审核回厂行没有冻结物料口径", "lacks its frozen material basis",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);

        // RF 5 恢复导入行, 同一订货明细上再加一条没有口径的新流程已审核行: 照样拒绝(豁免不外溢)。
        replica(() -> {
            exec("UPDATE subcontract_receipts SET legacy_id = 990003, legacy_import_run_id = ? WHERE id = ?",
                    runId, receiptId);
            exec("UPDATE subcontract_receipt_items SET legacy_id = 990004, legacy_import_run_id = ? WHERE id = ?",
                    runId, receiptItem);
            exec("INSERT INTO subcontract_receipts(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 1)",
                    newReceiptId, "T-RF-NEW-R-" + f.tag());
            exec("""
                    INSERT INTO subcontract_receipt_items(id, bill_no, bill_date, receipt_id, order_item_id, goods_id,
                        goods_snapshot_source, qty, unit_rate, unit_id)
                    VALUES (?, ?, current_date, ?, ?, ?, 'MASTER_AT_SAVE', 2, 1, ?)
                    """, newReceiptItem, "T-RF-NEW-R-" + f.tag(), newReceiptId, orderItem, p, f.unit());
        });
        expectViolation("RF 5 导入行旁边的新流程行没有冻结物料口径", "lacks its frozen material basis",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);

        // RF 6 新流程行带口径 > 0, 但明细没有冻结计划行: 仍 fail-closed(可回厂 0)。
        replica(() -> exec("UPDATE subcontract_receipt_items SET material_basis_qty = 2 WHERE id = ?", newReceiptItem));
        expectViolation("RF 6 没有计划行却有物料口径回厂", "no frozen draw plan lines",
                "SELECT fn_assert_subcontract_target_outbound_receipt(?)", orderItem);
    }

    // ====================================================================================
    // rf_warehouse_dropped.sql: 仓库整行删掉计划行领料 = 软删 + warehouse_dropped_at, 申领量保留, 哪里都不再计数
    // ====================================================================================

    @Test
    void aWholeLineTheWarehouseDropsIsSoftDeletedWithItsMarkerKeepsItsRequestAndCountsNowhere() throws SQLException {
        Fixture f = fixture("wd");
        UUID p = goods(f, "P", "委外");
        UUID x1 = goods(f, "X1", "采购");
        UUID x2 = goods(f, "X2", "采购");
        bom(p, x1, "2");
        bom(p, x2, "0.1");
        UUID orderId = UUID.randomUUID(), orderItem = UUID.randomUUID(), planId = UUID.randomUUID();
        UUID issueId = UUID.randomUUID(), line1 = UUID.randomUUID(), line2 = UUID.randomUUID();
        UUID item1 = UUID.randomUUID(), item2 = UUID.randomUUID();
        replica(() -> {
            exec("INSERT INTO subcontract_orders(id, bill_no, bill_date, status) VALUES (?, ?, current_date, 0)",
                    orderId, "T-RF-WD-" + f.tag());
            exec("""
                    INSERT INTO subcontract_order_items(id, bill_no, bill_date, order_id, goods_id, goods_snapshot_source,
                        qty, unit_rate, unit_id, line_no)
                    VALUES (?, ?, current_date, ?, ?, 'MASTER_AT_SAVE', 10, 1, ?, 1)
                    """, orderItem, "T-RF-WD-" + f.tag(), orderId, p, f.unit());
            exec("INSERT INTO subcontract_material_plans(id, order_id, order_bill_no) VALUES (?, ?, ?)",
                    planId, orderId, "T-RF-WD-" + f.tag());
            exec("""
                    INSERT INTO subcontract_material_issues(id, bill_no, bill_date, status, warehouse_id)
                    VALUES (?, ?, current_date, 0, ?)
                    """, issueId, "T-RF-WD-I-" + f.tag(), f.warehouse());
        });
        exec("""
                INSERT INTO subcontract_material_plan_items(id, plan_id, order_item_id, line_no, parent_goods_id, goods_id,
                    color_id, unit_id, unit_rate, bom_unit_qty, planned_qty)
                VALUES (?, ?, ?, 1, ?, ?, NULL, ?, 1, 2, 20),
                       (?, ?, ?, 2, ?, ?, NULL, ?, 1, 0.1, 1)
                """, line1, planId, orderItem, p, x1, f.unit(), line2, planId, orderItem, p, x2, f.unit());
        // 提交领料: X1 8(4 套)、X2 0.4(4 套)。
        exec("""
                INSERT INTO subcontract_material_issue_items(id, bill_no, bill_date, issue_id, order_item_id, goods_id, color_id,
                    unit_id, unit_rate, qty, goods_snapshot_source, plan_item_id, requested_qty)
                VALUES (?, 'T', current_date, ?, ?, ?, NULL, ?, 1, 8, 'MASTER_AT_SAVE', ?, 8),
                       (?, 'T', current_date, ?, ?, ?, NULL, ?, 1, 0.4, 'MASTER_AT_SAVE', ?, 0.4)
                """, item1, issueId, orderItem, x1, f.unit(), line1, item2, issueId, orderItem, x2, f.unit(), line2);
        qty("4", summary(orderItem).get("pending_qty"), "WD0 待仓库发 4 套");

        // WD1 活行单独打删除标记被 CHECK 拒绝。
        expectViolation("WD1 活行带 warehouse_dropped_at", "subcontract_material_issue_item_warehouse_dropped_chk",
                "UPDATE subcontract_material_issue_items SET warehouse_dropped_at = now() WHERE id = ?", item2);

        // WD2 仓库删掉 X2 整行: 软删 + 标记, qty / requested_qty 不动; 延迟守卫立即触发也通过。
        exec("UPDATE subcontract_material_issue_items SET is_deleted = TRUE, warehouse_dropped_at = now() WHERE id = ?",
                item2);
        Map<String, Object> dropped = one("""
                SELECT qty, requested_qty, is_deleted, warehouse_dropped_at IS NOT NULL AS dropped
                FROM subcontract_material_issue_items WHERE id = ?
                """, item2);
        qty("0.4", dropped.get("qty"), "WD2 删掉的行发料量保留");
        qty("0.4", dropped.get("requested_qty"), "WD2 删掉的行申领量保留");
        assertEquals(Boolean.TRUE, dropped.get("is_deleted"), "WD2 软删");
        assertEquals(Boolean.TRUE, dropped.get("dropped"), "WD2 带仓库删除标记");
        exec("SET CONSTRAINTS ALL IMMEDIATE");
        exec("SET CONSTRAINTS ALL DEFERRED");

        // WD3 待仓库发只数活的草稿行。
        qty("0", scalar("SELECT pending_qty FROM fn_subcontract_draw_facts(?) WHERE plan_item_id = ?", orderItem, line2),
                "WD3 删掉的行不再待发");
        qty("8", scalar("SELECT pending_qty FROM fn_subcontract_draw_facts(?) WHERE plan_item_id = ?", orderItem, line1),
                "WD3 活行仍待发 8");
        Map<String, Object> s = summary(orderItem);
        qty("0", s.get("pending_qty"), "WD3 按短板 X2 待发 0 套");
        qty("0", s.get("complete_qty"), "WD3 已覆盖 0 套");
        assertIdentity(s, "WD3");

        // WD4 不清标记就把删掉的行恢复成活行被拒绝。
        expectViolation("WD4 恢复成活行却保留删除标记", "subcontract_material_issue_item_warehouse_dropped_chk",
                "UPDATE subcontract_material_issue_items SET is_deleted = FALSE WHERE id = ?", item2);

        // WD5 审核发出后删掉的行不计入委外商处可用 / 可回厂(X2 可用 0 → 可回厂 0)。
        replica(() -> {
            exec("UPDATE subcontract_material_issues SET status = 1 WHERE id = ?", issueId);
            exec("UPDATE subcontract_material_issue_items SET at_supplier_qty = qty WHERE issue_id = ? AND NOT is_deleted",
                    issueId);
            exec("UPDATE subcontract_material_plan_items SET issued_qty = 8 WHERE id = ?", line1);
        });
        qty("0", scalar("SELECT usable_qty FROM fn_subcontract_draw_facts(?) WHERE plan_item_id = ?", orderItem, line2),
                "WD5 删掉的行不算委外商处可用");
        qty("0", scalar("SELECT fn_subcontract_returnable_qty(?)", orderItem), "WD5 可回厂 0");
        s = summary(orderItem);
        qty("0", s.get("drawn_qty"), "WD5 已领 0 套");
        qty("0", s.get("pending_qty"), "WD5 待仓库发 0 套");
        assertIdentity(s, "WD5");

        // WD6 回厂通知的少发口径: 活行 + 仓库删掉的行的申领量 - 活行发料量。
        qty("0.4", scalar("""
                SELECT COALESCE(SUM(item.requested_qty), 0) - COALESCE(SUM(item.qty) FILTER (WHERE NOT item.is_deleted), 0)
                FROM subcontract_material_issue_items item
                WHERE item.issue_id = ? AND item.plan_item_id = ?
                  AND (NOT item.is_deleted OR item.warehouse_dropped_at IS NOT NULL)
                """, issueId, line2), "WD6 X2 少发 = 删掉的行的申领量");
    }

    // ===================== 夹具 =====================

    private record Fixture(String tag, UUID department, UUID employee, UUID user, UUID unit, UUID warehouse) {
    }

    /** 主档按真实触发器写入(与 FullChainEndToEndTest.seedWorld 同一组 SQL)。 */
    private Fixture fixture(String label) throws SQLException {
        String tag = "v798-" + label + "-" + SEQUENCE.incrementAndGet() + "-" + UUID.randomUUID().toString().substring(0, 8);
        UUID department = UUID.randomUUID(), employee = UUID.randomUUID(), user = UUID.randomUUID();
        UUID unit = UUID.randomUUID(), warehouse = UUID.randomUUID();
        exec("INSERT INTO departments(id, code, name, level) VALUES (?, ?, ?, '一级部门')",
                department, "DEPT-" + tag, "测试部门-" + tag);
        exec("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "EMP-" + tag, "测试员工-" + tag, department);
        exec("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password, is_super_admin, status)
                VALUES (?, ?, ?, 'x', FALSE, FALSE, 'active')
                """, user, employee, "USR-" + tag);
        exec("INSERT INTO units(id, code, name, status) VALUES (?, ?, '个', '使用')", unit, "PCS-" + tag);
        exec("INSERT INTO warehouses(id, code, name, status) VALUES (?, ?, ?, '使用')",
                warehouse, "WH-" + tag, "测试仓库-" + tag);
        assertEquals(Boolean.TRUE, scalar("SELECT fn_warehouse_is_operational_leaf(?)", warehouse),
                "夹具仓库必须是作业叶仓");
        return new Fixture(tag, department, employee, user, unit, warehouse);
    }

    private UUID goods(Fixture f, String code, String sourceType) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("""
                INSERT INTO goods(id, code, name, source_type, status, unit_id, price, code_sequence)
                VALUES (?, ?, ?, ?, '使用', ?, 100, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, id, code + "-" + f.tag(), code + "-" + f.tag(), sourceType, f.unit());
        return id;
    }

    private void bom(UUID parent, UUID component, String qty) throws SQLException {
        exec("INSERT INTO goods_bom_items(goods_id, component_goods_id, qty) VALUES (?, ?, ?)",
                parent, component, new BigDecimal(qty));
    }

    private static UUID id(String suffix) {
        return UUID.fromString("00000000-0000-4000-8000-000000000" + suffix);
    }

    private void assertLots(UUID orderItem, UUID planItem, String expected) throws SQLException {
        List<Map<String, Object>> lots = rows(
                "SELECT plan_item_id, warehouse_id, remaining_qty FROM fn_subcontract_component_entitled_lots(?)", orderItem);
        assertEquals(1, lots.size(), "订货明细 " + orderItem + " 的精确批次条数: " + lots);
        assertEquals(planItem, lots.getFirst().get("plan_item_id"), "精确批次挂在冻结计划行上");
        assertNotNull(lots.getFirst().get("warehouse_id"), "精确批次带仓库");
        qty(expected, lots.getFirst().get("remaining_qty"), "订货明细 " + orderItem + " 可接管批次");
    }

    private Map<String, Object> summary(UUID orderItem) throws SQLException {
        Map<String, Object> row = one("SELECT * FROM fn_subcontract_draw_summary(?)", orderItem);
        assertNotNull(row, "已存在的订货明细必须返回一行汇总");
        return row;
    }

    /**
     * ADR-143 §三.4/§三.4a 行级恒等式: 已领 + 待仓库发 + 可领 + 还缺 = 我方供料套数 material_qty
     * (有计划行时; 没有财务批准的委外商自带料时 material_qty = 订货数量)。
     */
    private static void assertIdentity(Map<String, Object> s, String step) {
        BigDecimal sum = decimal(s.get("drawn_qty")).add(decimal(s.get("pending_qty")))
                .add(decimal(s.get("drawable_qty"))).add(decimal(s.get("short_qty")));
        assertEquals(0, decimal(s.get("material_qty")).compareTo(sum),
                step + " 恒等式 已领+待仓库发+可领+还缺=我方供料套数 不成立: " + s);
        assertTrue(decimal(s.get("material_qty")).compareTo(decimal(s.get("order_qty"))) <= 0,
                step + " 我方供料套数不超过订货数量: " + s);
    }

    // ===================== JDBC 小工具 =====================

    @FunctionalInterface
    private interface SqlAction {
        void run() throws SQLException;
    }

    private void replica(SqlAction action) throws SQLException {
        exec("SET LOCAL session_replication_role = replica");
        try {
            action.run();
        } finally {
            exec("SET LOCAL session_replication_role = origin");
        }
    }

    private void exec(String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = prepare(sql, args)) {
            statement.execute();
        }
    }

    private PreparedStatement prepare(String sql, Object... args) throws SQLException {
        PreparedStatement statement = db.prepareStatement(sql);
        for (int index = 0; index < args.length; index++) {
            statement.setObject(index + 1, args[index]);
        }
        return statement;
    }

    private List<Map<String, Object>> rows(String sql, Object... args) throws SQLException {
        try (PreparedStatement statement = prepare(sql, args); ResultSet result = statement.executeQuery()) {
            ResultSetMetaData meta = result.getMetaData();
            List<Map<String, Object>> rows = new ArrayList<>();
            while (result.next()) {
                Map<String, Object> row = new LinkedHashMap<>();
                for (int column = 1; column <= meta.getColumnCount(); column++) {
                    row.put(meta.getColumnLabel(column), result.getObject(column));
                }
                rows.add(row);
            }
            return rows;
        }
    }

    private Map<String, Object> one(String sql, Object... args) throws SQLException {
        List<Map<String, Object>> rows = rows(sql, args);
        assertTrue(rows.size() <= 1, "期望至多一行, 实际 " + rows.size() + ": " + sql);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private Object scalar(String sql, Object... args) throws SQLException {
        Map<String, Object> row = one(sql, args);
        return row == null ? null : row.values().iterator().next();
    }

    private int count(String sql, Object... args) throws SQLException {
        Object value = scalar(sql, args);
        return value == null ? 0 : ((Number) value).intValue();
    }

    /** 在保存点里执行, 期望数据库守卫以 23514(check_violation) 拒绝; 之后回到保存点继续。 */
    private void expectViolation(String what, String messageFragment, String sql, Object... args) throws SQLException {
        Savepoint savepoint = db.setSavepoint();
        try {
            exec(sql, args);
        } catch (SQLException rejected) {
            db.rollback(savepoint);
            assertEquals("23514", rejected.getSQLState(), what + ": 必须是数据库守卫(23514)拒绝, 实际 "
                    + rejected.getSQLState() + " " + rejected.getMessage());
            if (messageFragment != null) {
                assertTrue(String.valueOf(rejected.getMessage()).contains(messageFragment),
                        what + ": 拒绝原因不对: " + rejected.getMessage());
            }
            return;
        } finally {
            try {
                db.releaseSavepoint(savepoint);
            } catch (SQLException alreadyReleased) {
                // 回滚到保存点后保存点仍有效; 已释放时忽略。
            }
        }
        fail(what + ": 数据库守卫没有拒绝");
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return null;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static void qty(String expected, Object actual, String what) {
        assertNotNull(actual, what + ": 实际为 NULL, 期望 " + expected);
        assertEquals(0, new BigDecimal(expected).compareTo(decimal(actual)),
                what + ": 实际 " + actual + ", 期望 " + expected);
    }
}
