package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V486（2026-09-05 委外收敛批次）目标库迁移契约：
 * 1）procurement_order_qty_change_logs 事实账 + case_id + fn_audit 触发器；
 * 2）采购/委外「批准后改量」权限码登记到既有 surface，默认不授任何部门；
 * 3）subcontract_preparation:view/start 停用（不可分配）、surface 下线，
 *    且未改动历史授权行数（V441 同口径）；
 * 4）系统测试清空白名单已注册 procurement_order_qty_change_logs=CLEAR。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementQtyChangeMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp_v486_qty_change")
                    .withUsername("uten")
                    .withPassword("uten-test-only");

    @BeforeAll
    static void migrateThroughLatest() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
    }

    @AfterAll
    static void stopDatabase() {
        POSTGRES.stop();
    }

    @Test
    void qtyChangeLedgerExistsWithoutRowAudit() throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalar(statement, """
                    select count(*) from information_schema.columns
                    where table_name = 'procurement_order_qty_change_logs'
                      and column_name = 'case_id'
                    """));
            // ADR-105: 改量事实账是只追加、带改量人的流水(NONE), 行本身即留痕, 不再挂行审计。
            assertEquals(0, scalar(statement, """
                    select count(distinct trigger_name) from information_schema.triggers
                    where event_object_table = 'procurement_order_qty_change_logs'
                      and trigger_name like 'trg_audit%'
                    """));
            // CHECK 约束：order_type 只允许采购/委外。
            assertEquals(1, scalar(statement, """
                    select count(*) from pg_constraint
                    where conrelid = 'procurement_order_qty_change_logs'::regclass
                      and contype = 'c'
                      and pg_get_constraintdef(oid) like '%PURCHASE%'
                      and pg_get_constraintdef(oid) like '%SUBCONTRACT%'
                    """));
        }
    }

    @Test
    void changeQtyPermissionsRegisteredWithoutGrantsAndPreparationRetired()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            // V677(ADR-109)：目录只剩活码、授权策略由 grant_policy 表达。
            assertEquals(2, scalar(statement, """
                    select count(*) from permissions
                    where code in ('purchase_order:change_qty',
                                   'subcontract_order:change_qty')
                      and grant_policy = array['NORMAL']::text[]
                    """));
            assertEquals(2, scalar(statement, """
                    select count(*)
                    from permission_surface_permissions link
                    join permission_surfaces surface on surface.id = link.surface_id
                    join permissions permission on permission.id = link.permission_id
                    where (surface.surface_key, permission.code) in (
                        ('purchase.order', 'purchase_order:change_qty'),
                        ('subcontract.order', 'subcontract_order:change_qty'))
                    """));
            // V486 登记时零授权；V677 起「批准后改量」与「提交财务」同口径默认发放：
            // 持有提交财务的部门恰好也持有改量，没有别的部门、没有个人/委派授权。
            assertEquals(0, scalar(statement, """
                    select count(*) from (
                        select department_id, submit.code as submit_code
                        from department_permissions grant_row
                        join permissions submit on submit.id = grant_row.permission_id
                        where submit.code in ('purchase_order:submit_finance',
                                              'subcontract_order:submit_finance')
                    ) submit_holder
                    where not exists (
                        select 1 from department_permissions change_row
                        join permissions change on change.id = change_row.permission_id
                        where change_row.department_id = submit_holder.department_id
                          and change.code = replace(submit_holder.submit_code,
                                                    'submit_finance', 'change_qty'))
                    """));
            assertEquals(0, scalar(statement, """
                    select count(*) from (
                        select permission_id from user_permission_overrides
                        union all select permission_id from manager_permission_delegations
                    ) grant_row
                    join permissions permission on permission.id = grant_row.permission_id
                    where permission.code in ('purchase_order:change_qty',
                                   'subcontract_order:change_qty')
                    """));
            // 委外准备中心两个停用码：V677 起停用即删除。
            assertEquals(0, scalar(statement, """
                    select count(*) from permissions
                    where code in ('subcontract_preparation:view',
                                   'subcontract_preparation:start')
                    """));
            assertEquals(0, scalar(statement, """
                    select count(*) from permission_surfaces
                    where surface_key = 'subcontract.preparation' and enabled
                    """));
        }
    }

    @Test
    void resetPolicyCoversQtyChangeLedger() throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalar(statement, """
                    select count(*) from pg_get_functiondef(
                        'business_data_reset()'::regprocedure)
                    where pg_get_functiondef('business_data_reset()'::regprocedure)
                        like '%procurement_order_qty_change_logs%, ''CLEAR''%'
                    """));
        }
    }

    private static long scalar(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }
}
