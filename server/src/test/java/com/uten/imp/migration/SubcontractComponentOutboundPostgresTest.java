package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V581 真库行为：委外「只有一个叶子子件」的形态判据与两道新守卫。
 *
 * <p>静态契约测试只能证明迁移文本里写了什么；判据是不是真的按四条判、守卫是不是真的
 * 拦得住畸形行，只有在真 PostgreSQL 上插一行才知道。目标版本钉在 581，不受后续
 * 并行会话的新迁移影响。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractComponentOutboundPostgresTest {

    private static final AtomicInteger SEQUENCE = new AtomicInteger();

    @Test
    void soleLeafComponentIsRecognisedAndMalformedComponentRowsAreRejected() throws Exception {
        try (var pg = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("sc_component_outbound")
                .withUsername("uten").withPassword("uten-test-only")) {
            pg.start();
            Flyway.configure()
                    .dataSource(pg.getJdbcUrl(), pg.getUsername(), pg.getPassword())
                    .locations("classpath:db/migration").target("581").load().migrate();

            try (Connection c = DriverManager.getConnection(
                    pg.getJdbcUrl(), pg.getUsername(), pg.getPassword())) {
                Fixture f = seed(c);

                // ① 一条 PER_UNIT 叶子边 → 命中
                assertTrue(sole(c, f.target()), "单条 PER_UNIT 叶子边应判为单一子件形态");
                assertFalse(sole(c, f.child()), "叶子子件自己没有 BOM，不该命中");

                // ② 合法 COMPONENT 行可以插：父=目标件、goods=子件、
                //    bom_unit_qty = 订货换算率(2) × BOM 单耗(3) = 6，计划量 = 订货量(10) × 6 = 60
                UUID componentLine = UUID.randomUUID();
                insertComponentLine(c, f, componentLine, f.child(), f.childUnit(),
                        "6", "60");
                assertEquals(1, count(c,
                        "select count(*) from subcontract_material_plan_items"
                                + " where id=? and flow_mode='COMPONENT_OUTBOUND'", componentLine));

                // ③ 同一订货明细再插一条目标件流向 → 混用被焊死
                SQLException mixed = assertThrows(SQLException.class, () -> execute(c, """
                        INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,
                            parent_goods_id,goods_id,unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,
                            flow_mode,preparation_status,prepared_qty,
                            bom_has_children_snapshot,preparation_bom_fingerprint)
                        VALUES (?,?,?,9,?,?,?,1,2,20,0,'DIRECT_OUTBOUND','READY_OUTBOUND',20,TRUE,?)
                        """, UUID.randomUUID(), f.plan(), f.orderItem(), f.target(), f.target(),
                        f.targetUnit(), "a".repeat(64)));
                assertEquals("23514", mixed.getSQLState());
                assertTrue(mixed.getMessage().contains("cannot mix component outbound"),
                        () -> "期望混用守卫，实际：" + mixed.getMessage());

                // ④ 畸形 COMPONENT 行（goods 填成目标件自己）→ 数量基准守卫拒绝
                SQLException malformed = assertThrows(SQLException.class, () ->
                        insertComponentLine(c, f, UUID.randomUUID(), f.target(), f.targetUnit(),
                                "6", "60"));
                assertEquals("23514", malformed.getSQLState());
                assertTrue(malformed.getMessage().contains("component outbound requires the single"),
                        () -> "期望单一子件基准守卫，实际：" + malformed.getMessage());

                // ⑤ 冻结单耗写错（未乘订货换算率）→ 同样拒绝
                SQLException wrongRate = assertThrows(SQLException.class, () ->
                        insertComponentLine(c, f, UUID.randomUUID(), f.child(), f.childUnit(),
                                "3", "30"));
                assertEquals("23514", wrongRate.getSQLState());

                // ⑥ 子件长出自己的 BOM → 不再是「一层」
                UUID grandChild = insertGoods(c, "GRANDCHILD", f.childUnit());
                insertBomEdge(c, f.child(), grandChild, "1", "PER_UNIT", "START");
                assertFalse(sole(c, f.target()), "子件有了下层就不该再判为单一叶子子件");

                // ⑦ 恢复后再加一条兄弟边 → 两颗子件同样不命中
                execute(c, "update goods_bom_items set is_deleted=TRUE where goods_id=?", f.child());
                assertTrue(sole(c, f.target()));
                UUID sibling = insertGoods(c, "SIBLING", f.childUnit());
                insertBomEdge(c, f.target(), sibling, "1", "PER_UNIT", "START");
                assertFalse(sole(c, f.target()), "两条活动边不该判为单一子件形态");

                // ⑧ 只剩一条边、但不是 PER_UNIT 投入 → 不命中（压不成标量单耗）
                execute(c, "update goods_bom_items set is_deleted=TRUE"
                        + " where goods_id=? and component_goods_id=?", f.target(), sibling);
                assertTrue(sole(c, f.target()));
                execute(c, "update goods_bom_items set consumption_basis='PER_PACKAGE'"
                        + " where goods_id=? and component_goods_id=?", f.target(), f.child());
                assertFalse(sole(c, f.target()), "PER_PACKAGE 带取整，不该判为单一子件形态");

                // ⑨ 只剩一条边、但只是参考料 → 不命中
                //（V247 的 hard_gate_stage_chk 不允许 REFERENCE 边还挂硬门禁，一起改）
                execute(c, "update goods_bom_items set consumption_basis='PER_UNIT',"
                        + " control_stage='REFERENCE', hard_gate=FALSE"
                        + " where goods_id=? and component_goods_id=?", f.target(), f.child());
                assertFalse(sole(c, f.target()), "SHIP/REFERENCE 不是发给委外商的投入料");
            }
        }
    }

    private record Fixture(UUID target, UUID child, UUID targetUnit, UUID childUnit,
                           UUID order, UUID orderItem, UUID plan) {
    }

    private static Fixture seed(Connection c) throws Exception {
        String suffix = String.format(Locale.ROOT, "20260914%06d", SEQUENCE.incrementAndGet());
        UUID baseUnit = UUID.randomUUID();
        UUID boxUnit = UUID.randomUUID();
        UUID order = UUID.randomUUID();
        UUID orderItem = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        String orderNo = "EO" + suffix;
        c.setAutoCommit(false);
        execute(c, "insert into units(id,code,name,status) values (?,?,'piece','使用'),(?,?,'box','使用')",
                baseUnit, "UNIT-" + baseUnit, boxUnit, "BOX-" + boxUnit);
        UUID target = insertGoods(c, "TARGET", baseUnit);
        UUID child = insertGoods(c, "CHILD", baseUnit);
        insertBomEdge(c, target, child, "3", "PER_UNIT", "START");
        execute(c, "insert into subcontract_orders(id,bill_no,bill_date,status)"
                + " values (?,?,DATE '2026-01-01',0)", order, orderNo);
        // 订货单位=箱，1 箱=2 件；订 10 箱 → 目标件基本量 20，子件 = 10×(2×3) = 60
        execute(c, """
                insert into subcontract_order_items(id,order_id,bill_no,bill_date,line_no,goods_id,unit_id,
                    unit_rate,qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source)
                values (?,?,?,DATE '2026-01-01',1,?,?,2,10,?,'component outbound fixture','MASTER_AT_SAVE')
                """, orderItem, order, orderNo, target, boxUnit, "GOODS-" + target);
        execute(c, "insert into subcontract_material_plans(id,order_id,order_bill_no,status)"
                + " values (?,?,?,'OPEN')", plan, order, orderNo);
        c.commit();
        c.setAutoCommit(true);
        return new Fixture(target, child, baseUnit, baseUnit, order, orderItem, plan);
    }

    private static UUID insertGoods(Connection c, String tag, UUID unitId) throws SQLException {
        UUID id = UUID.randomUUID();
        execute(c, "insert into goods(id,code,name,unit_id,code_sequence)"
                + " values (?,?,?,?,(select coalesce(max(code_sequence),0)+1 from goods))",
                id, tag + "-" + id, "component outbound " + tag.toLowerCase(Locale.ROOT), unitId);
        return id;
    }

    private static void insertBomEdge(Connection c, UUID parent, UUID component,
                                      String qty, String basis, String stage) throws SQLException {
        execute(c, "insert into goods_bom_items(id,goods_id,component_goods_id,qty,"
                + "consumption_basis,control_stage) values (?,?,?,CAST(? AS NUMERIC),?,?)",
                UUID.randomUUID(), parent, component, qty, basis, stage);
    }

    private static void insertComponentLine(Connection c, Fixture f, UUID id,
                                            UUID goodsId, UUID unitId,
                                            String bomUnitQty, String plannedQty)
            throws SQLException {
        execute(c, """
                INSERT INTO subcontract_material_plan_items(id,plan_id,order_item_id,line_no,
                    parent_goods_id,goods_id,unit_id,unit_rate,bom_unit_qty,planned_qty,issued_qty,
                    flow_mode,preparation_status,prepared_qty,
                    bom_has_children_snapshot,preparation_bom_fingerprint)
                VALUES (?,?,?,1,?,?,?,1,CAST(? AS NUMERIC),CAST(? AS NUMERIC),0,
                    'COMPONENT_OUTBOUND','READY_OUTBOUND',CAST(? AS NUMERIC),TRUE,?)
                """, id, f.plan(), f.orderItem(), f.target(), goodsId, unitId,
                bomUnitQty, plannedQty, plannedQty, "a".repeat(64));
    }

    private static boolean sole(Connection c, UUID goodsId) throws SQLException {
        try (var s = c.prepareStatement("select fn_subcontract_sole_component_goods(?)")) {
            s.setObject(1, goodsId);
            try (var r = s.executeQuery()) {
                r.next();
                return r.getBoolean(1);
            }
        }
    }

    private static void execute(Connection c, String sql, Object... args) throws SQLException {
        try (var s = c.prepareStatement(sql)) {
            for (int n = 0; n < args.length; n++) {
                s.setObject(n + 1, args[n]);
            }
            s.executeUpdate();
        }
    }

    private static int count(Connection c, String sql, UUID id) throws SQLException {
        try (var s = c.prepareStatement(sql)) {
            s.setObject(1, id);
            try (var r = s.executeQuery()) {
                r.next();
                return r.getInt(1);
            }
        }
    }
}
