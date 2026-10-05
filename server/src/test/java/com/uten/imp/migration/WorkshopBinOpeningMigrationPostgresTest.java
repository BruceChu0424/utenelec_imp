package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * V800 (ADR-147) 车间内料仓开通单一真源。
 *
 * <p>回填: 用过的内料仓(余额行、整批领料设置等任何引用)-> 已开通(有设置的仍整批领料中); 一次都没用过的软删除;
 * 同一车间还剩多个在用的内料仓 -> 迁移中止。
 *
 * <p>之后的数据库兜底: 内料仓仓库行与开通行同生共死(提交时校验)、一车间一个内料仓、来源仓只能是可选良品子仓、
 * 整批领料只能开在已开通的内料仓上、已开通的内料仓与发料来源仓不能在仓库资料里停用、默认发料来源仓的优先级、
 * 直送原因码 WORKSHOP_BIN_NOT_OPEN 的大白话、业务清空保留开通记录。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkshopBinOpeningMigrationPostgresTest {

    @Test
    void backfillsUsedBinsAsOpenedDropsUnusedOnesAndGuardsTheSingleSource() {
        try (var db = new PostgreSQLContainer<>("postgres:16-alpine")) {
            db.start();
            migrate(db, "799");
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    db.getJdbcUrl(), db.getUsername(), db.getPassword()));
            List<UUID> workshops = jdbc.queryForList("""
                    SELECT child.id FROM departments child
                    JOIN departments parent ON parent.id = child.parent_id
                    WHERE parent.code = 'DEPT_PROD' AND NOT child.is_deleted
                    ORDER BY child.code LIMIT 5
                    """, UUID.class);
            assertThat(workshops).hasSizeGreaterThanOrEqualTo(5);
            UUID assembly = workshops.get(0), molding = workshops.get(1), idle = workshops.get(2);
            UUID later = workshops.get(3), unopened = workshops.get(4);

            UUID root = warehouse(jdbc, "001", "仓库(14年版)", null, false);
            UUID plastic = warehouse(jdbc, "XW01", "塑胶仓库", root, false);
            UUID packing = warehouse(jdbc, "XW02", "包材仓库", root, false);
            UUID defective = warehouse(jdbc, "C0401", "成品不良品仓", root, true);
            UUID assemblyBin = bin(jdbc, "LS-A", "装配车间内料仓", assembly, root);
            UUID moldingBin = bin(jdbc, "LS-M", "注塑车间内料仓", molding, root);
            UUID idleBin = bin(jdbc, "LS-I", "空闲车间内料仓", idle, root);
            UUID goods = goods(jdbc, "plain", null);
            // 装配车间的内料仓收过直送(这里用一条清零的余额行代表「有引用」); 注塑车间开着整批领料; 空闲车间从没用过。
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + goods + "','"
                    + assemblyBin + "',0)");
            UUID enabler = UUID.randomUUID();
            replica(jdbc, "INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,"
                    + "periodic_bin_warehouse_id,go_live_date,enabled_by,enabled_at,created_by) VALUES ('" + molding
                    + "',true,'" + moldingBin + "',CURRENT_DATE,'" + enabler + "',now(),'" + enabler + "')");

            // 同一车间两个在用的内料仓: 中止交人工合并。
            UUID duplicate = bin(jdbc, "LS-A2", "装配车间内料仓二", assembly, root);
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + goods + "','"
                    + duplicate + "',0)");
            assertThatThrownBy(() -> migrate(db, null)).hasStackTraceContaining("同一个车间有多个在用的内料仓");
            replica(jdbc, "DELETE FROM stock_balances WHERE warehouse_id='" + duplicate + "'");
            migrate(db, null);

            assertThat(opened(jdbc, assembly)).isEqualTo(assemblyBin);
            assertThat(opened(jdbc, molding)).isEqualTo(moldingBin);
            assertThat(opened(jdbc, idle)).isNull();
            assertThat(deleted(jdbc, idleBin)).as("从没用过的内料仓软删除").isTrue();
            assertThat(deleted(jdbc, duplicate)).isTrue();
            assertThat(jdbc.queryForObject("SELECT opened_by FROM workshop_bins WHERE workshop_department_id=?",
                    UUID.class, molding)).as("开通人取开启人; 账号已不存在时留空, 不挂悬空引用").isNull();
            assertThat(jdbc.queryForObject("SELECT source_warehouse_id FROM workshop_bins WHERE workshop_department_id=?",
                    UUID.class, assembly)).isNull();

            // 一车间一个内料仓; 内料仓只能由开通命令建出(提交时校验)。
            assertThatThrownBy(() -> bin(jdbc, "LS-A3", "装配车间第二内料仓", assembly, root))
                    .hasStackTraceContaining("ux_warehouses_line_side_workshop");
            assertThatThrownBy(() -> bin(jdbc, "LS-L", "后来车间内料仓", later, root))
                    .hasStackTraceContaining("没有开通记录");
            UUID laterBin = UUID.randomUUID();
            transaction(jdbc, "INSERT INTO warehouses(id,code,name,status,is_accountable,is_line_side,"
                            + "workshop_department_id,parent_id) VALUES ('" + laterBin + "','LS-L','后来车间内料仓','使用',"
                            + "true,true,'" + later + "','" + root + "')",
                    "INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id,source_warehouse_id) VALUES ('"
                            + later + "','" + laterBin + "','" + plastic + "')");
            assertThat(opened(jdbc, later)).isEqualTo(laterBin);

            // 来源仓: 主仓、不良品仓、内料仓都不行; 改来源仓走版本号。
            for (UUID refused : new UUID[] {root, defective, moldingBin}) {
                assertThatThrownBy(() -> jdbc.update("""
                        UPDATE workshop_bins SET source_warehouse_id=?, row_version=row_version+1
                        WHERE workshop_department_id=?""", refused, assembly))
                        .hasStackTraceContaining("发料来源仓只能选启用中的良品子仓");
            }
            assertThatThrownBy(() -> jdbc.update(
                    "UPDATE workshop_bins SET source_warehouse_id=? WHERE workshop_department_id=?", packing, assembly))
                    .hasStackTraceContaining("已被别人改过");
            jdbc.update("UPDATE workshop_bins SET source_warehouse_id=?, row_version=row_version+1 "
                    + "WHERE workshop_department_id=?", packing, assembly);

            // 仓库资料: 已开通的内料仓、仍是发料来源仓的仓不能停用/删除。
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET status='禁用' WHERE id=?", assemblyBin))
                    .hasStackTraceContaining("是已开通的车间内料仓");
            assertThatThrownBy(() -> jdbc.update("UPDATE warehouses SET is_deleted=true WHERE id=?", plastic))
                    .hasStackTraceContaining("发料来源仓");

            // 撤销开通: 删开通行而不软删仓库行 -> 提交时拒绝; 同一事务一起做才行。
            assertThatThrownBy(() -> jdbc.update("DELETE FROM workshop_bins WHERE workshop_department_id=?", assembly))
                    .hasStackTraceContaining("没有开通记录");
            assertThat(jdbc.queryForObject("SELECT cardinality(fn_workshop_bin_revoke_blockers(?))", Integer.class,
                    assemblyBin)).isZero();
            transaction(jdbc, "DELETE FROM workshop_bins WHERE workshop_department_id='" + assembly + "'",
                    "UPDATE warehouses SET is_deleted=true, deleted_at=now() WHERE id='" + assemblyBin + "'");
            assertThat(opened(jdbc, assembly)).isNull();
            assertThat(jdbc.queryForObject("SELECT cardinality(fn_workshop_bin_revoke_blockers(?))", Integer.class,
                    moldingBin)).as("整批领料中不能直接撤销开通").isEqualTo(1);

            // 整批领料只能开在已开通的内料仓上。
            UUID unopenedBin = UUID.randomUUID();
            assertThatThrownBy(() -> jdbc.update("""
                    INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,periodic_bin_warehouse_id,
                        go_live_date,enabled_by,enabled_at,created_by)
                    VALUES (?,true,?,CURRENT_DATE,?,now(),?)""", unopened, unopenedBin, enabler, enabler))
                    .hasStackTraceContaining("还没开通内料仓");

            // 默认发料来源仓: 来源仓有可发量 -> 货品所属仓库 -> 可发量最大的良品子仓; 不良品仓永远不选。
            UUID owned = goods(jdbc, "owned", packing);
            UUID orphan = goods(jdbc, "orphan", null);
            assertThat(defaultSource(jdbc, laterBin, owned)).as("来源仓没货时取所属仓库").isEqualTo(packing);
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + owned + "','"
                    + plastic + "',5)");
            assertThat(defaultSource(jdbc, laterBin, owned)).as("来源仓有货优先").isEqualTo(plastic);
            replica(jdbc, "INSERT INTO stock_balances(goods_id,warehouse_id,qty) VALUES ('" + orphan + "','"
                    + defective + "',100), ('" + orphan + "','" + packing + "',3), ('" + orphan + "','" + plastic
                    + "',0)");
            assertThat(defaultSource(jdbc, moldingBin, orphan)).as("不良品仓再多也不选").isEqualTo(packing);
            assertThat(defaultSource(jdbc, null, owned)).as("没开通时从所属仓库起算").isEqualTo(packing);

            // 直送原因: 收料车间没开通内料仓。
            assertThat(jdbc.queryForObject("""
                    SELECT fn_workshop_direct_reason_text('WORKSHOP_BIN_NOT_OPEN', NULL, NULL, '装配车间', NULL, NULL, NULL)
                    """, String.class)).isEqualTo("装配车间还没开通内料仓，请仓库在「车间内料仓」开通后再直送，这次先送入仓库");
            assertThat(jdbc.queryForObject("SELECT fn_workshop_direct_reason_rank('WORKSHOP_BIN_NOT_OPEN')",
                    Integer.class)).isLessThan(jdbc.queryForObject(
                    "SELECT fn_workshop_direct_reason_rank('RECEIVER_STATUS')", Integer.class));

            // 业务清空: 开通记录随仓库主档保留; 整批领料设置照旧清空。
            String reset = jdbc.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",
                    String.class);
            assertThat(reset).contains("('workshop_bins', 'PRESERVE')", "('workshop_material_settings', 'CLEAR')");
        }
    }

    private static void migrate(PostgreSQLContainer<?> db, String target) {
        var flyway = Flyway.configure().dataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword())
                .locations("classpath:db/migration");
        if (target != null) flyway.target(target);
        flyway.load().migrate();
    }

    private static UUID warehouse(JdbcTemplate jdbc, String code, String name, UUID parent, boolean defective) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_defective,parent_id)
                VALUES (?,?,?,'使用',true,?,?)
                """, id, code, name, defective, parent);
        return id;
    }

    private static UUID bin(JdbcTemplate jdbc, String code, String name, UUID workshop, UUID root) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id,code,name,status,is_accountable,is_line_side,workshop_department_id,parent_id)
                VALUES (?,?,?,'使用',true,true,?,?)
                """, id, code, name, workshop, root);
        return id;
    }

    private static UUID goods(JdbcTemplate jdbc, String label, UUID owner) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,owning_warehouse_id,code_sequence) "
                        + "VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, "V800-" + label, label, owner);
        return id;
    }

    private static UUID opened(JdbcTemplate jdbc, UUID workshop) {
        List<UUID> rows = jdbc.queryForList("SELECT bin_warehouse_id FROM workshop_bins WHERE workshop_department_id=?",
                UUID.class, workshop);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private static boolean deleted(JdbcTemplate jdbc, UUID warehouse) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT is_deleted FROM warehouses WHERE id=?", Boolean.class,
                warehouse));
    }

    private static UUID defaultSource(JdbcTemplate jdbc, UUID bin, UUID goods) {
        return jdbc.queryForObject("SELECT fn_workshop_bin_default_source(CAST(? AS uuid), ?, NULL)", UUID.class,
                bin == null ? null : bin.toString(), goods);
    }

    /** 几条语句一个事务提交(延迟约束在提交时校验)。 */
    private static void transaction(JdbcTemplate jdbc, String... statements) {
        jdbc.execute((ConnectionCallback<Void>) connection -> {
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                for (String sql : statements) statement.execute(sql);
                connection.commit();
            } catch (RuntimeException | java.sql.SQLException error) {
                connection.rollback();
                throw error;
            } finally {
                connection.setAutoCommit(true);
            }
            return null;
        });
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
}
