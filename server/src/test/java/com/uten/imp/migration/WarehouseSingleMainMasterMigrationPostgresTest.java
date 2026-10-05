package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V800 (ADR-145) 仓库主档单主仓: 扁平/多主仓的存量收敛成「主仓 001 + 直属子仓」两层,
 * 禁用但仍被归属的仓改回使用, 没人引用的禁用仓软删除, 不良品仓上的货品归属置空;
 * 判断不了主仓、内料仓不在主仓下、规范化重名时迁移中止。之后守卫拦住停用/删除前置条件、
 * 两层树、仓库用途变更和货品所属仓库只能是可选良品子仓。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WarehouseSingleMainMasterMigrationPostgresTest {

    @Test
    void convergesLegacyMastersIntoOneMainAndGuardsTheShape() {
        try (var db = new PostgreSQLContainer<>("postgres:16-alpine")) {
            db.start();
            migrate(db, "797");
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    db.getJdbcUrl(), db.getUsername(), db.getPassword()));
            UUID workshop = jdbc.queryForObject("""
                    SELECT child.id FROM departments child
                    JOIN departments parent ON parent.id = child.parent_id
                    WHERE parent.code = 'DEPT_PROD' AND NOT child.is_deleted
                    ORDER BY child.code LIMIT 1
                    """, UUID.class);

            // 1. 没有 001、又有多个顶层仓: 判断不了主仓, 中止。
            UUID first = warehouse(jdbc, "A01", "甲仓", null, "使用", false);
            UUID second = warehouse(jdbc, "B01", "乙仓", null, "使用", false);
            assertThatThrownBy(() -> migrate(db, "800")).hasStackTraceContaining("没有编号 001 的主仓");

            // 2. 典型的老库形态: 001 下只挂了一部分, 其余仓各自是顶层; 五金仓库被停用却还被货品归属。
            UUID root = warehouse(jdbc, "001", "仓库（14年版）", null, "使用", false);
            UUID plastic = warehouse(jdbc, "XW01", "塑胶仓库", root, "使用", false);
            UUID hardware = warehouse(jdbc, "C01", "五金仓库", null, "禁用", false);
            UUID emptyDisabled = warehouse(jdbc, "C02", "停用空仓", null, "禁用", false);
            UUID historicalDisabled = warehouse(jdbc, "C03", "停用历史仓", null, "禁用", false);
            UUID defective = warehouse(jdbc, "002", "原材料不良仓（14年版）", null, "使用", true);
            UUID duplicate = warehouse(jdbc, "D01", "备件仓（旧）", null, "使用", false);
            warehouse(jdbc, "D02", " 备件仓(旧) ", null, "使用", false);
            UUID bin = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO warehouses(id,code,name,status,is_accountable,is_line_side,workshop_department_id,parent_id)
                    VALUES (?,'LS-T','测试车间内料仓','使用',true,true,?,?)
                    """, bin, workshop, second);
            UUID ownedHardware = goods(jdbc, "owned-hardware", hardware);
            UUID ownedDefective = goods(jdbc, "owned-defective", defective);
            UUID plain = goods(jdbc, "plain", null);
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + plain + "','"
                    + plastic + "',5)");
            // 停用历史仓只剩一条清零的余额行: 有引用(不能删), 但没有库存(可以保持停用)。
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + plain + "','"
                    + historicalDisabled + "',0)");

            assertThatThrownBy(() -> migrate(db, "800")).hasStackTraceContaining("不在主仓下面");
            jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?", root, bin);
            assertThatThrownBy(() -> migrate(db, "800")).hasStackTraceContaining("仓库名称重复");
            jdbc.update("UPDATE warehouses SET name='备件仓（新）' WHERE id=?", duplicate);
            migrate(db, "800");

            // 收敛结果: 只有 001 是顶层, 其余未删除仓都直挂 001。
            assertThat(jdbc.queryForObject(
                    "SELECT count(*) FROM warehouses WHERE NOT is_deleted AND parent_id IS NULL", Integer.class))
                    .isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT fn_warehouse_root_id()", UUID.class)).isEqualTo(root);
            assertThat(jdbc.queryForObject("""
                    SELECT count(*) FROM warehouses
                    WHERE NOT is_deleted AND id <> ? AND parent_id IS DISTINCT FROM ?
                    """, Integer.class, root, root)).isZero();
            assertThat(status(jdbc, hardware)).isEqualTo("使用");
            assertThat(jdbc.queryForObject("SELECT is_deleted FROM warehouses WHERE id=?", Boolean.class,
                    emptyDisabled)).isTrue();
            assertThat(status(jdbc, historicalDisabled)).isEqualTo("禁用");
            assertThat(jdbc.queryForObject("SELECT is_deleted FROM warehouses WHERE id=?", Boolean.class,
                    historicalDisabled)).isFalse();
            assertThat(owner(jdbc, ownedHardware)).isEqualTo(hardware);
            assertThat(owner(jdbc, ownedDefective)).as("不良品仓不能当所属仓库, 置空不猜仓").isNull();
            assertThat(selectable(jdbc, plastic)).isTrue();
            assertThat(selectable(jdbc, hardware)).isTrue();
            assertThat(selectable(jdbc, first)).isTrue();
            assertThat(selectable(jdbc, root)).as("主仓只作汇总").isFalse();
            assertThat(selectable(jdbc, defective)).as("不良品仓不是新选良品仓").isFalse();
            assertThat(selectable(jdbc, bin)).as("内料仓由车间内料仓管理").isFalse();
            assertThat(selectable(jdbc, historicalDisabled)).as("禁用仓不可选").isFalse();
            assertThat(jdbc.queryForObject("SELECT fn_warehouse_name_key(' 仓库（14年版） ')", String.class))
                    .isEqualTo("仓库(14年版)");

            // 停用/删除前置条件: 原因与服务层预检同一个函数。
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", root))
                    .hasStackTraceContaining("现在不能停用").hasStackTraceContaining("它是主仓");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", plastic))
                    .hasStackTraceContaining("1 种货品有库存");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", hardware))
                    .hasStackTraceContaining("1 个货品的所属仓库");
            UUID orderItem = UUID.randomUUID();
            replica(jdbc, "INSERT INTO stock_reservations(order_item_id,owner_type,owner_id,purpose,goods_id,"
                    + "warehouse_id,qty) VALUES ('" + orderItem + "','SALES_ORDER_ITEM','" + orderItem
                    + "','SALES_FULFILLMENT','" + plain + "','" + first + "',2)");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_deleted=true WHERE id=?", first))
                    .hasStackTraceContaining("现在不能删除").hasStackTraceContaining("没结束的库存预留");
            UUID enabler = UUID.randomUUID();
            replica(jdbc, "INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,"
                    + "periodic_bin_warehouse_id,go_live_date,enabled_by,enabled_at,created_by) VALUES ('" + workshop
                    + "',true,'" + bin + "',CURRENT_DATE,'" + enabler + "',now(),'" + enabler + "')");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", bin))
                    .hasStackTraceContaining("整批领料");
            assertThat(jdbc.queryForObject("SELECT cardinality(fn_warehouse_retirement_blockers(?))",
                    Integer.class, second)).isZero();
            jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", second);
            jdbc.update("UPDATE warehouses SET is_deleted=true WHERE id=?", second);

            // 两层树: 子仓不能变成第二个顶层, 也不能挂到子仓下面。
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET parent_id=NULL WHERE id=?", first))
                    .hasStackTraceContaining("不能改成独立的顶层仓");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET parent_id=? WHERE id=?", plastic, first))
                    .hasStackTraceContaining("只能挂在主仓下面");

            // 仓库用途: 改成不良品仓与改成「不核算」一样是退出新单可选, 与停用同一组前置条件
            // (库存、货品归属、未结预留); 主仓不能是不良品仓。
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_defective=true WHERE id=?", plastic))
                    .hasStackTraceContaining("现在不能改成不良品仓").hasStackTraceContaining("种货品有库存");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_defective=true WHERE id=?", hardware))
                    .hasStackTraceContaining("个货品的所属仓库");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_accountable=false WHERE id=?", hardware))
                    .hasStackTraceContaining("现在不能改成不核算").hasStackTraceContaining("个货品的所属仓库");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_accountable=false WHERE id=?", plastic))
                    .hasStackTraceContaining("现在不能改成不核算").hasStackTraceContaining("种货品有库存");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_defective=true WHERE id=?", first))
                    .hasStackTraceContaining("现在不能改成不良品仓").hasStackTraceContaining("没结束的库存预留");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_defective=true WHERE id=?", root))
                    .hasStackTraceContaining("不良品仓只能是子仓");
            // 主仓永远不能停用(没有子仓时也不行)。
            assertThat(jdbc.queryForObject("SELECT array_to_string(fn_warehouse_retirement_blockers(?), ';')",
                    String.class, root)).contains("它是主仓");
            replica(jdbc, "DELETE FROM stock_reservations WHERE order_item_id='" + orderItem + "'");
            jdbc.update("UPDATE warehouses SET is_defective=true WHERE id=?", first);
            assertThat(selectable(jdbc, first)).isFalse();

            // 货品所属仓库: 只能选可选良品子仓; 值不变的普通改档不重新判定。
            for (UUID refused : new UUID[]{root, defective, bin, historicalDisabled}) {
                assertThatThrownBy(() -> jdbc.update(
                        "UPDATE goods SET owning_warehouse_id=? WHERE id=?", refused, plain))
                        .hasStackTraceContaining("只能选启用中的良品子仓");
            }
            jdbc.update("UPDATE goods SET owning_warehouse_id=? WHERE id=?", plastic, plain);
            assertThat(owner(jdbc, plain)).isEqualTo(plastic);
            replica(jdbc, "UPDATE goods SET owning_warehouse_id='" + defective + "' WHERE id='" + ownedDefective + "'");
            jdbc.update("UPDATE goods SET name='改名不动归属' WHERE id=?", ownedDefective);
            assertThat(owner(jdbc, ownedDefective)).isEqualTo(defective);

            // 只有一个顶层仓又没有 001 的库(全新部署第一次建仓/升级彩排夹具)以它为主仓。
            jdbc.execute((ConnectionCallback<Void>) connection -> {
                connection.setAutoCommit(false);
                try (var statement = connection.createStatement()) {
                    statement.execute("UPDATE warehouses SET code='ROOT-RENAMED' WHERE id='" + root + "'");
                    try (var rows = statement.executeQuery("SELECT fn_warehouse_root_id()")) {
                        rows.next();
                        assertThat(rows.getObject(1, UUID.class)).isEqualTo(root);
                    }
                } finally {
                    connection.rollback();
                    connection.setAutoCommit(true);
                }
                return null;
            });
        }
    }

    @Test
    void emptyCatalogOnlyInstallsFunctions() {
        try (var db = new PostgreSQLContainer<>("postgres:16-alpine")) {
            db.start();
            migrate(db, "800");
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    db.getJdbcUrl(), db.getUsername(), db.getPassword()));
            assertThat(jdbc.queryForObject("SELECT fn_warehouse_root_id()", UUID.class)).isNull();
            assertThat(jdbc.queryForObject("""
                    SELECT count(*) FROM pg_trigger
                    WHERE tgname = 'trg_guard_warehouse_master_lifecycle' AND NOT tgisinternal
                    """, Integer.class)).isEqualTo(1);
        }
    }

    private static void migrate(PostgreSQLContainer<?> db, String target) {
        Flyway.configure().dataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword())
                .locations("classpath:db/migration").target(target).load().migrate();
    }

    private static UUID warehouse(JdbcTemplate jdbc, String code, String name, UUID parent,
                                  String status, boolean defective) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective,parent_id)
                VALUES (?,?,?,?,true,?,?)
                """, id, code, name, status, defective, parent);
        return id;
    }

    private static UUID goods(JdbcTemplate jdbc, String label, UUID owner) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,owning_warehouse_id,code_sequence) "
                        + "VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, "V800-" + label, label, owner);
        return id;
    }

    /** 造一条只有守卫才会拦住的历史事实(外键/业务触发器不参与, CHECK 照常生效)。 */
    private static void replica(JdbcTemplate jdbc, String sql) {
        jdbc.execute((ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role = replica");
                statement.execute(sql);
                statement.execute("SET session_replication_role = origin");
            }
            return null;
        });
    }

    private static String status(JdbcTemplate jdbc, UUID id) {
        return jdbc.queryForObject("SELECT status FROM warehouses WHERE id=?", String.class, id);
    }

    private static UUID owner(JdbcTemplate jdbc, UUID goods) {
        return jdbc.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?", UUID.class, goods);
    }

    private static boolean selectable(JdbcTemplate jdbc, UUID warehouse) {
        return Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT fn_warehouse_is_good_stock_leaf(?)", Boolean.class, warehouse));
    }
}
