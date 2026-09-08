package com.uten.imp.migration;

import com.uten.imp.audit.AuditActorDirectory;
import com.uten.imp.audit.AuditEventInterpreter;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.audit.AuditLogRepository;
import com.uten.imp.audit.AuditQueryService;
import com.uten.imp.audit.AuditRetentionScheduler;
import com.uten.imp.audit.AuditRuntimeSettings;
import com.uten.imp.audit.AuditSearchCriteria;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.AuditSummary;
import com.uten.imp.audit.AuditSummaryAggregation;
import com.uten.imp.common.time.BusinessTime;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import org.postgresql.ds.PGSimpleDataSource;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.LocalDate;
import java.util.List;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

/**
 * Applies the complete migration chain to a clean PostgreSQL instance and verifies the
 * production security boundaries. This catches SQL that compiles in Java but cannot be deployed.
 */
@EnabledIfEnvironmentVariable(
        named = "UTEN_RUN_DB_TESTS",
        matches = "(?i)true")
class SecurityPermissionMigrationTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @BeforeAll
    static void migrate() throws Exception {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target("147")
                .load()
                .migrate();

        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.execute("""
                    CREATE TABLE audit_log_archive
                        (LIKE audit_log INCLUDING DEFAULTS INCLUDING INDEXES);
                    ALTER TABLE clients DROP CONSTRAINT IF EXISTS clients_status_chk;
                    ALTER TABLE suppliers DROP CONSTRAINT IF EXISTS suppliers_status_chk;
                    INSERT INTO clients (legacy_id, code, name, status, remark) VALUES
                        (9001, 'LEGACY-FIN-CL-9001', '??????????', '??', '????'),
                        (9002, 'LEGACY-FIN-CL-9002', 'Manual client', chr(31105) || chr(29992), 'Manual remark'),
                        (9004, 'LEGACY-FIN-CL-ARCHIVE-9004', '??????????',
                            chr(31105) || chr(29992), '????'),
                        (NULL, 'LEGACY-FIN-CL-NO-LEGACY-ID', '??????????', NULL, 'Manual remark');
                    INSERT INTO suppliers (legacy_id, code, name, status, remark) VALUES
                        (9003, 'LEGACY-FIN-SP-9003', '??????????', '??', '????'),
                        (9005, 'LEGACY-FIN-SP-ARCHIVE-9005', '??????????',
                            chr(31105) || chr(29992), '????');
                    """);
        }

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
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void installsNarrowPermissionsAndValidatesLedgerPartyShape()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {

            assertEquals(5, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code in (
                        'account:support',
                        'authorization:manage',
                        'finance_asset:edit',
                        'finance_post:execute',
                        'finance_shipment_audit'
                    )
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join departments d on d.id = dp.department_id
                    join permissions p on p.id = dp.permission_id
                    where d.code = 'DEPT_HR'
                      and p.code = 'account:support'
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join permissions p on p.id = dp.permission_id
                    where p.code in ('user:manage', 'authorization:manage')
                    """));
            assertTrue(scalarBoolean(statement, """
                    select convalidated
                    from pg_constraint
                    where conname = 'ar_ap_ledger_party_shape_chk'
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code = 'expense:pay'
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code in (
                        'employee:pii:edit',
                        'employee:compensation:edit'
                    )
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join departments d on d.id = dp.department_id
                    join permissions p on p.id = dp.permission_id
                    where d.code = 'DEPT_HR'
                      and p.code in (
                          'employee:pii:edit',
                          'employee:compensation:edit'
                      )
                    """));
            assertEquals(15, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'jwt_access_ttl_minutes'
                    """));
            assertEquals(5, scalarLong(statement, """
                    select count(*)
                    from information_schema.tables
                    where table_schema = 'public'
                      and table_name in (
                          'payroll_batches',
                          'expense_claims',
                          'legacy_migration_run_files',
                          'legacy_migration_rejects',
                          'authorization_state'
                      )
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*)
                    from pg_attribute a
                    join pg_class c on c.oid = a.attrelid
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public'
                      and c.relname = 'sales_monthly_mv'
                      and c.relkind = 'm'
                      and a.attname = 'owner_employee_id'
                      and a.attnum > 0
                      and not a.attisdropped
                    """));
            assertEquals(7, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'mv_sales_monthly_uidx',
                          'mv_sales_monthly_owner_ym',
                          'idx_sq_maker_date_active',
                          'idx_so_owner_date_active',
                          'idx_ss_owner_date_active',
                          'idx_sos_owner_date_active',
                          'idx_sr_owner_date_active'
                      )
                    """));
            assertTrue(scalarString(statement, """
                    select indexdef
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname = 'mv_sales_monthly_uidx'
                    """).contains("owner_employee_id"));
            assertEquals(6, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_visitor_app_account_created_active',
                          'idx_visitor_app_account_status_created_active',
                          'idx_visitor_app_status_created_active',
                          'idx_visitor_app_host_status_created_active',
                          'idx_fixed_assets_code_active',
                          'idx_deferred_expenses_code_active'
                      )
                    """));
            assertEquals(4, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_suggestions_submitted_stable',
                          'idx_suggestions_submitter_submitted_stable',
                          'idx_suggestions_category_submitted_stable',
                          'idx_suggestion_likes_user_suggestion'
                      )
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from pg_indexes
                    where schemaname = 'public'
                      and indexname in (
                          'idx_suggestions_submitted',
                          'idx_suggestions_submitter',
                          'idx_suggestion_likes_user'
                      )
                    """));
            assertEquals("numeric(18,4)", scalarString(statement, """
                    select format_type(a.atttypid, a.atttypmod)
                    from pg_attribute a
                    join pg_class c on c.oid = a.attrelid
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public'
                      and c.relname = 'goods'
                      and a.attname = 'price'
                      and a.attnum > 0
                      and not a.attisdropped
                    """));
            assertEquals(300, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'login_ip_rate_limit_per_minute'
                    """));
            assertEquals(6, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'audit_hot_retention_months'
                    """));
            assertEquals(30, scalarLong(statement, """
                    select value::bigint
                    from system_settings
                    where key = 'audit_archive_retention_months'
                    """));
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from permissions
                    where code in ('audit_log:view', 'audit_log:export')
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from department_permissions dp
                    join permissions p on p.id = dp.permission_id
                    where p.code in ('audit_log:view', 'audit_log:export')
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from user_permission_overrides upo
                    join permissions p on p.id = upo.permission_id
                    join users u on u.id = upo.user_id
                    where p.code in ('audit_log:view', 'audit_log:export')
                      and upo.effect = 'grant'
                      and u.is_super_admin = false
                    """));
            assertTrue(scalarBoolean(statement, """
                    select fn_audit_redact_row(
                        'employees',
                        '{"id_card_enc":"secret","phone_hash":"hash","full_name":"张三","status":"active"}'::jsonb
                    ) = '{"status":"active"}'::jsonb
                    """));
            assertEquals(26, scalarLong(statement, """
                    select count(*)
                    from information_schema.columns
                    where table_schema = 'public'
                      and table_name = 'audit_log'
                      and column_name in (
                          'request_id', 'event_source', 'http_method', 'http_path',
                          'status_code', 'duration_ms', 'risk_level', 'event_category',
                          'client_event_id', 'device_installation_id', 'device_name',
                          'device_manufacturer', 'device_model', 'device_platform',
                          'device_os_version', 'app_version', 'app_build',
                          'device_form_factor', 'device_browser', 'device_locale',
                          'device_time_zone', 'device_time_zone_offset_minutes',
                          'device_is_physical', 'client_event_at',
                          'device_capture_status', 'device_profile_hash'
                      )
                    """));
            assertEquals(26, scalarLong(statement, """
                    select count(*)
                    from information_schema.columns
                    where table_schema = 'public'
                      and table_name = 'audit_log_archive'
                      and column_name in (
                          'request_id', 'event_source', 'http_method', 'http_path',
                          'status_code', 'duration_ms', 'risk_level', 'event_category',
                          'client_event_id', 'device_installation_id', 'device_name',
                          'device_manufacturer', 'device_model', 'device_platform',
                          'device_os_version', 'app_version', 'app_build',
                          'device_form_factor', 'device_browser', 'device_locale',
                          'device_time_zone', 'device_time_zone_offset_minutes',
                          'device_is_physical', 'client_event_at',
                          'device_capture_status', 'device_profile_hash'
                      )
                    """));
            assertEquals("", scalarString(statement, """
                    select coalesce(string_agg(c.relname, ',' order by c.relname), '')
                    from pg_class c
                    join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public'
                      and c.relkind in ('r', 'p')
                      and not c.relispartition
                      and c.relname not in (
                          'audit_log', 'audit_log_archive', 'flyway_schema_history',
                          'spatial_ref_sys', 'authorization_state', 'doc_number_sequences', 'master_code_sequences',
                          'category_master_code_sequences', 'business_document_sequences',
                          'production_product_no_sequences',
                          'report_materialized_view_refresh_state', 'password_history',
                          'refresh_tokens', 'visitor_refresh_tokens', 'visitor_sms_codes',
                          'notices', 'notice_user_states', 'notice_acknowledgments',
                          'notice_blessings', 'notice_celebration_subjects',
                          'business_outbox',
                          'attachment_object_outbox', 'account_flow_monthly_summaries',
                          'production_daily_report_commands',
                          'production_fqc_release_commands',
                          'warehouse_arrival_registration_commands',
                          'production_material_analysis_commands'
                      )
                      and c.relname not like 'legacy_migration_%'
                      and ((select count(*) from pg_trigger t where t.tgrelid=c.oid
                              and not t.tgisinternal and t.tgname like 'trg_audit%')<>1
                        or not exists (
                          select 1
                          from pg_trigger t
                          join pg_proc p on p.oid=t.tgfoid
                          join pg_namespace pn on pn.oid=p.pronamespace
                          where t.tgrelid = c.oid
                            and not t.tgisinternal
                            and t.tgname like 'trg_audit%'
                            and t.tgenabled in ('O','A') and t.tgtype=29
                            and t.tgnargs=0 and t.tgqual is null and t.tgattr=''::int2vector
                            and not t.tgdeferrable and not t.tginitdeferred and t.tgconstraint=0
                            and t.tgoldtable is null and t.tgnewtable is null
                            and pn.nspname='public' and p.proname in ('fn_audit','fn_audit_redacted')
                            and t.tgfoid in('public.fn_audit()'::regprocedure,'public.fn_audit_redacted()'::regprocedure)
                      ))
                    """),
                    "Every public business table must have an audit trigger");
            statement.execute("""
                    insert into audit_log (
                        action, target_type, target_id, http_method, http_path,
                        result, event_source
                    ) values
                        ('http_get', 'api/admin/permissions', 'risk-rule-read',
                         'GET', '/api/admin/permissions', 'success', 'request'),
                        ('http_patch', 'api/admin/permissions', 'risk-rule-write',
                         'PATCH', '/api/admin/permissions', 'success', 'request')
                    """);
            assertEquals("low", scalarString(statement, """
                    select risk_level from audit_log
                    where target_id = 'risk-rule-read'
                    """));
            assertEquals("high", scalarString(statement, """
                    select risk_level from audit_log
                    where target_id = 'risk-rule-write'
                    """));
            statement.execute("""
                    insert into audit_log_archive
                    select * from audit_log
                    where target_id = 'risk-rule-read'
                    on conflict (id) do nothing
                    """);
            assertEquals("low", scalarString(statement, """
                    select risk_level from audit_log_archive
                    where target_id = 'risk-rule-read'
                    """));
            assertEquals(4, scalarLong(statement, """
                    select count(*)
                    from flyway_schema_history
                    where version in ('169', '171', '172', '173')
                      and success
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*)
                    from flyway_schema_history
                    where not success
                    """));
            statement.execute("select refresh_sales_monthly_mv()");
        }
    }

    @Test
    void databaseRejectsDepartmentWideAuditPermissions() throws Exception {
        for (String permissionCode : List.of("audit_log:view", "audit_log:export")) {
            SQLException insertFailure = assertThrows(
                    SQLException.class,
                    () -> executeDepartmentPermissionWrite(
                            """
                            insert into department_permissions (department_id, permission_id)
                            select d.id, p.id
                            from departments d
                            cross join permissions p
                            where d.code = 'DEPT_HR'
                              and p.code = ?
                            """,
                            permissionCode));
            assertTrue(insertFailure.getMessage()
                    .contains("审计权限仅允许个人授权"));

            SQLException updateFailure = assertThrows(
                    SQLException.class,
                    () -> executeDepartmentPermissionWrite(
                            """
                            update department_permissions
                            set permission_id = (
                                select id from permissions where code = ?
                            )
                            where (department_id, permission_id) = (
                                select department_id, permission_id
                                from department_permissions
                                limit 1
                            )
                            """,
                            permissionCode));
            assertTrue(updateFailure.getMessage()
                    .contains("审计权限仅允许个人授权"));
        }
    }

    @Test
    @SuppressWarnings("unchecked")
    void auditTrendAggregationUsesEffectiveRiskAndInvestigationCategory() throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
             Statement statement = connection.createStatement()) {
            statement.execute("""
                    insert into audit_log (
                        action, target_type, target_id, result, event_source
                    ) values
                        ('view_audit_log_list', 'audit_log', 'trend-list',
                         'success', 'business'),
                        ('view_audit_log_detail', 'audit_log', 'trend-detail',
                         'success', 'business')
                    """);
        }

        // 旧的 AuditLogRepository.summarizeDaily 原生 SQL 已演进为
        // AuditQueryService 过滤规格 + AuditSummaryAggregation 的 JPA Criteria 聚合。
        // 这里用真实 Hibernate/PostgreSQL 执行同一读路径：Asia/Shanghai 分组、
        // 有效风险（view_audit_log_detail 提升为中风险）与调查动作强制归 security
        // 只在真库上能被完整验证。
        PGSimpleDataSource dataSource = new PGSimpleDataSource();
        dataSource.setUrl(POSTGRES.getJdbcUrl());
        dataSource.setUser(POSTGRES.getUsername());
        dataSource.setPassword(POSTGRES.getPassword());
        LocalContainerEntityManagerFactoryBean factory =
                new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.audit");
        Properties jpaProperties = new Properties();
        jpaProperties.setProperty("hibernate.hbm2ddl.auto", "none");
        jpaProperties.setProperty("hibernate.show_sql", "false");
        jpaProperties.setProperty("hibernate.jdbc.time_zone", "UTC");
        factory.setJpaProperties(jpaProperties);
        factory.afterPropertiesSet();
        EntityManagerFactory entityManagerFactory = factory.getObject();
        assertNotNull(entityManagerFactory);
        EntityManager entityManager = entityManagerFactory.createEntityManager();
        try {
            AuditSummaryAggregation aggregation = new AuditSummaryAggregation();
            Field entityManagerField =
                    AuditSummaryAggregation.class.getDeclaredField("entityManager");
            entityManagerField.setAccessible(true);
            entityManagerField.set(aggregation, entityManager);

            AuditQueryService queryService = new AuditQueryService(
                    mock(AuditLogRepository.class),
                    mock(AuditEventInterpreter.class),
                    mock(AuditActorDirectory.class),
                    aggregation);

            LocalDate today = LocalDate.now(BusinessTime.ZONE);
            AuditSearchCriteria criteria = new AuditSearchCriteria(
                    "view_audit_log_", null, null, null, "security",
                    null, null, null, null, null, null, null,
                    today.minusDays(1), today, null, null, false);
            Method specification = AuditQueryService.class.getDeclaredMethod(
                    "specification", AuditSearchCriteria.class);
            specification.setAccessible(true);
            Specification<AuditLog> base = (Specification<AuditLog>)
                    specification.invoke(queryService, criteria);
            Method riskSpecification = AuditQueryService.class.getDeclaredMethod(
                    "riskSpecification", String.class);
            riskSpecification.setAccessible(true);
            Specification<AuditLog> risky = (Specification<AuditLog>)
                    riskSpecification.invoke(queryService, "risky");
            Specification<AuditLog> critical = (Specification<AuditLog>)
                    riskSpecification.invoke(queryService, "critical");
            Method outcomeSpecification = AuditQueryService.class.getDeclaredMethod(
                    "outcomeSpecification", String.class);
            outcomeSpecification.setAccessible(true);
            Specification<AuditLog> failed = (Specification<AuditLog>)
                    outcomeSpecification.invoke(queryService, "failure");
            Method operationSpecification = AuditQueryService.class.getDeclaredMethod(
                    "operationSpecification", String.class);
            operationSpecification.setAccessible(true);
            Specification<AuditLog> dataChange = (Specification<AuditLog>)
                    operationSpecification.invoke(queryService, "write");

            Method summarize = AuditSummaryAggregation.class.getDeclaredMethod(
                    "summarize",
                    Specification.class, Specification.class,
                    Specification.class, Specification.class,
                    Specification.class,
                    LocalDate.class, LocalDate.class);
            summarize.setAccessible(true);
            AuditSummary summary = (AuditSummary) summarize.invoke(
                    aggregation, base, risky, critical, failed, dataChange,
                    today.minusDays(1), today);

            long total = summary.dailyTrend().stream()
                    .mapToLong(AuditSummary.DailyPoint::total).sum();
            long risk = summary.dailyTrend().stream()
                    .mapToLong(AuditSummary.DailyPoint::riskCount).sum();
            assertEquals(2L, total,
                    "both investigation rows must be counted in the trend window");
            assertEquals(1L, risk,
                    "only the forced-medium-risk detail view counts as risky");
        } finally {
            entityManager.close();
            entityManagerFactory.close();
        }
    }

    @Test
    void repairsOnlyUntouchedFinancePlaceholderParties() throws Exception {
        try (Connection connection = openConnection();
             Statement statement = connection.createStatement()) {
            assertEquals(
                    "\u94b1\u6d41\u5386\u53f2\u5ba2\u6237\uff08\u539fID 9001\uff09",
                    scalarString(statement,
                            "select name from clients where legacy_id = 9001"));
            assertEquals(
                    "\u7981\u7528",
                    scalarString(statement,
                            "select status from clients where legacy_id = 9001"));
            assertEquals(
                    "Manual client",
                    scalarString(statement,
                            "select name from clients where legacy_id = 9002"));
            assertEquals(
                    "Manual remark",
                    scalarString(statement,
                            "select remark from clients where legacy_id = 9002"));
            assertEquals(
                    "\u94b1\u6d41\u5386\u53f2\u4f9b\u5e94\u5546\uff08\u539fID 9003\uff09",
                    scalarString(statement,
                            "select name from suppliers where legacy_id = 9003"));
            assertEquals(
                    "\u94b1\u6d41\u5386\u53f2\u5ba2\u6237\uff08\u539fID 9004\uff09",
                    scalarString(statement,
                            "select name from clients where legacy_id = 9004"),
                    "V165 must repair untouched placeholder clients missed by V148");
            assertEquals(
                    "\u94b1\u6d41\u5386\u53f2\u4f9b\u5e94\u5546\uff08\u539fID 9005\uff09",
                    scalarString(statement,
                            "select name from suppliers where legacy_id = 9005"),
                    "V165 must repair untouched placeholder suppliers missed by V148");
            assertEquals(
                    "??????????",
                    scalarString(statement,
                            "select name from clients where code = 'LEGACY-FIN-CL-NO-LEGACY-ID'"),
                    "V165 must not null out placeholder names when legacy_id is absent");
            assertEquals(2, scalarLong(statement, """
                    select count(*)
                    from pg_constraint
                    where conname in ('clients_status_chk', 'suppliers_status_chk')
                      and convalidated
                    """));
        }
    }

    @Test
    void scheduledRetentionArchivesHotRowsBeforeDeletionAndPurgesExpiredArchive()
            throws Exception {
        try (Connection connection = openConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("""
                    insert into audit_log (
                        action, target_type, target_id, result, created_at,
                        client_event_id, device_installation_id, device_name,
                        device_model, device_platform, device_capture_status
                    ) values
                        ('update', 'retention_test', 'retention-current',
                         'success', now() - interval '1 month',
                         '123e4567-e89b-42d3-a456-426614174010',
                         '123e4567-e89b-42d3-a456-426614174011',
                         '车间平板', 'UT-PAD-1', 'android', 'present'),
                        ('update', 'retention_test', 'retention-to-archive',
                         'success', now() - interval '7 months',
                         '123e4567-e89b-42d3-a456-426614174012',
                         '123e4567-e89b-42d3-a456-426614174013',
                         '车间平板', 'UT-PAD-1', 'android', 'present'),
                        ('update', 'retention_test', 'retention-to-delete',
                         'success', now() - interval '40 months',
                         '123e4567-e89b-42d3-a456-426614174014',
                         '123e4567-e89b-42d3-a456-426614174015',
                         '旧设备', 'UT-OLD', 'windows', 'present');

                    insert into audit_log_archive
                    select * from audit_log
                    where target_id = 'retention-to-delete'
                    on conflict (id) do nothing;

                    delete from audit_log
                    where target_id = 'retention-to-delete';
                    """);
        }

        PGSimpleDataSource dataSource = new PGSimpleDataSource();
        dataSource.setURL(POSTGRES.getJdbcUrl());
        dataSource.setUser(POSTGRES.getUsername());
        dataSource.setPassword(POSTGRES.getPassword());
        AuditRuntimeSettings settings = new AuditRuntimeSettings() {
            @Override
            public int exportMaxRows() {
                return 100_000;
            }

            @Override
            public int hotRetentionMonths() {
                return 6;
            }

            @Override
            public int archiveRetentionMonths() {
                return 30;
            }
        };
        AuditService audit = mock(AuditService.class);

        new AuditRetentionScheduler(dataSource, settings, audit).runScheduled();

        try (Connection connection = openConnection();
             Statement statement = connection.createStatement()) {
            assertEquals(1, scalarLong(statement, """
                    select count(*) from audit_log
                    where target_id = 'retention-current'
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*) from audit_log
                    where target_id = 'retention-to-archive'
                    """));
            assertEquals(1, scalarLong(statement, """
                    select count(*) from audit_log_archive
                    where target_id = 'retention-to-archive'
                      and device_name = '车间平板'
                      and device_model = 'UT-PAD-1'
                      and device_platform = 'android'
                      and device_installation_id =
                          '123e4567-e89b-42d3-a456-426614174013'::uuid
                    """));
            assertEquals(0, scalarLong(statement, """
                    select count(*) from audit_log_archive
                    where target_id = 'retention-to-delete'
                    """));
        }
        // V424 审计降噪口径：调度保留成功属于系统管道行为，不再写显式审计事件
        // （对齐 AuditRetentionSchedulerTest.successfulAutomaticRetentionDoesNotCreateUserActivityNoise）。
        verifyNoInteractions(audit);
    }

    @Test
    void databaseAuditTriggerCopiesSanitizedDeviceSessionContext()
            throws Exception {
        UUID requestId = UUID.randomUUID();
        UUID clientEventId = UUID.randomUUID();
        UUID installationId = UUID.randomUUID();
        try (Connection connection = openConnection()) {
            connection.setAutoCommit(false);
            try {
                setLocalConfig(connection, "app.audit_request_id", requestId.toString());
                setLocalConfig(connection, "app.audit_device_context", """
                        {
                          "clientEventId":"%s",
                          "installationId":"%s",
                          "deviceName":"迁移测试设备",
                          "manufacturer":"Uten",
                          "model":"QA-DB-1",
                          "platform":"windows",
                          "osVersion":"Windows Test",
                          "appVersion":"2.1.0",
                          "appBuild":"db-test",
                          "formFactor":"desktop",
                          "browserName":"edge",
                          "locale":"zh_CN",
                          "timeZone":"China Standard Time",
                          "timeZoneOffsetMinutes":480,
                          "physicalDevice":true,
                          "clientEventAt":"2026-07-31T02:00:00Z",
                          "captureStatus":"present",
                          "profileHash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                        }
                        """.formatted(clientEventId, installationId));
                try (Statement statement = connection.createStatement()) {
                    statement.executeUpdate("""
                            update system_settings
                            set description = description
                            where key = 'export_max_rows'
                            """);
                    assertTrue(scalarBoolean(statement, """
                            select exists (
                                select 1 from audit_log
                                where request_id = '%s'::uuid
                                  and client_event_id = '%s'::uuid
                                  and device_installation_id = '%s'::uuid
                                  and device_name = '迁移测试设备'
                                  and device_manufacturer = 'Uten'
                                  and device_model = 'QA-DB-1'
                                  and device_platform = 'windows'
                                  and device_time_zone_offset_minutes = 480
                                  and device_is_physical
                                  and client_event_at = '2026-07-31T02:00:00Z'::timestamptz
                                  and device_capture_status = 'present'
                            )
                            """.formatted(requestId, clientEventId, installationId)));
                }
            } finally {
                connection.rollback();
            }
            try (Statement statement = connection.createStatement()) {
                assertEquals("", scalarString(statement, """
                        select coalesce(
                            current_setting('app.audit_device_context', true),
                            '')
                        """));
            }
        }
    }

    /**
     * Verifies the PostgreSQL mutex used by SuggestionService.toggleLike.
     *
     * <p>The unit test asserts that the repository method carries PESSIMISTIC_WRITE; this
     * database test proves that two real connections cannot pass the parent-row lock together,
     * both toggles complete without a unique-key race, and two toggles restore the original state.
     */
    @Test
    void suggestionLikeParentRowLockSerializesConcurrentToggles() throws Exception {
        UUID suggestionId = UUID.randomUUID();
        String employeeCode = "SUGGESTION_LOCK_" + suggestionId.toString().replace("-", "");
        String loginAccount = "suggestion-lock-" + suggestionId;
        UUID userId;
        try (Connection connection = openConnection();
             Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    insert into employees (
                        code,
                        full_name,
                        gender,
                        id_type,
                        hire_date,
                        status,
                        employment_type,
                        department_id
                    )
                    select
                        '%s',
                        '建议并发测试员工',
                        'male',
                        '其他',
                        current_date,
                        'active',
                        'regular',
                        department_id
                    from employees
                    where code = 'ADMIN'
                    """.formatted(employeeCode));
            statement.executeUpdate("""
                    insert into users (employee_id, login_account, password_hash)
                    select id, '%s', 'test-only-not-a-real-password'
                    from employees
                    where code = '%s'
                    """.formatted(loginAccount, employeeCode));
            userId = UUID.fromString(scalarString(statement, """
                    select id::text
                    from users
                    where login_account = '%s'
                    """.formatted(loginAccount)));
            statement.executeUpdate("""
                    insert into suggestions (
                        id, submitter_id, submitter_name, category, title, content
                    ) values (
                        '%s'::uuid,
                        '%s'::uuid,
                        '并发测试员工',
                        'process',
                        '并发点赞测试',
                        '验证数据库父行锁能够串行化同一建议的点赞切换。'
                    )
                    """.formatted(suggestionId, userId));
        }

        CountDownLatch firstLocked = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        CountDownLatch secondStarted = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<Boolean> first = executor.submit(() -> toggleLike(
                    suggestionId, userId, null, firstLocked, releaseFirst));
            assertTrue(firstLocked.await(5, TimeUnit.SECONDS));

            Future<Boolean> second = executor.submit(() -> toggleLike(
                    suggestionId, userId, secondStarted, null, null));
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS));
            assertThrows(
                    TimeoutException.class,
                    () -> second.get(250, TimeUnit.MILLISECONDS),
                    "the second transaction must wait for the suggestion row lock");

            releaseFirst.countDown();
            assertTrue(first.get(5, TimeUnit.SECONDS));
            assertFalse(second.get(5, TimeUnit.SECONDS));

            try (Connection connection = openConnection();
                 Statement statement = connection.createStatement()) {
                assertEquals(0, scalarLong(statement, """
                        select count(*)
                        from suggestion_likes
                        where suggestion_id = '%s'::uuid
                          and user_id = '%s'::uuid
                        """.formatted(suggestionId, userId)));
            }
        } finally {
            releaseFirst.countDown();
            executor.shutdownNow();
            try (Connection connection = openConnection();
                 PreparedStatement cleanupSuggestion =
                         connection.prepareStatement("delete from suggestions where id = ?");
                 PreparedStatement cleanupEmployee =
                         connection.prepareStatement("delete from employees where code = ?")) {
                cleanupSuggestion.setObject(1, suggestionId);
                cleanupSuggestion.executeUpdate();
                cleanupEmployee.setString(1, employeeCode);
                cleanupEmployee.executeUpdate();
            }
        }
    }

    @Test
    void authorizationVersionsInvalidateDirectAndSharedPermissionSnapshots()
            throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
            Statement statement = connection.createStatement()) {
            connection.setAutoCommit(false);
            try {
                statement.executeUpdate("""
                        insert into users(employee_id, login_account, password_hash)
                        select id, 'migration-auth-version-test', 'test-only-not-a-real-password'
                        from employees
                        where code = 'ADMIN'
                        on conflict do nothing
                        """);
                String userId = scalarString(statement, """
                        select id::text
                        from users
                        where login_account = 'migration-auth-version-test'
                        """);
                long userVersionBefore = scalarLong(statement, """
                        select auth_version from users where id = '%s'::uuid
                        """.formatted(userId));
                statement.executeUpdate("""
                        insert into user_permission_overrides(user_id, permission_id, effect)
                        select '%s'::uuid, p.id, 'grant'
                        from permissions p
                        where not exists (
                            select 1
                            from user_permission_overrides o
                            where o.user_id = '%s'::uuid
                              and o.permission_id = p.id
                        )
                        order by p.code
                        limit 1
                        """.formatted(userId, userId));
                assertEquals(userVersionBefore + 1, scalarLong(statement, """
                        select auth_version from users where id = '%s'::uuid
                        """.formatted(userId)));

                long epochBefore = scalarLong(statement, """
                        select epoch from authorization_state where singleton_id = 1
                        """);
                statement.executeUpdate("""
                        update departments
                        set parent_id = parent_id
                        where id = (select id from departments order by id limit 1)
                        """);
                assertEquals(epochBefore + 1, scalarLong(statement, """
                        select epoch from authorization_state where singleton_id = 1
                        """));
            } finally {
                connection.rollback();
            }
        }
    }

    private long scalarLong(Statement statement, String sql) throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getLong(1);
        }
    }

    private boolean scalarBoolean(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getBoolean(1);
        }
    }

    private String scalarString(Statement statement, String sql)
            throws Exception {
        try (ResultSet result = statement.executeQuery(sql)) {
            result.next();
            return result.getString(1);
        }
    }

    private Connection openConnection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private void executeDepartmentPermissionWrite(
            String sql,
            String permissionCode) throws Exception {
        try (Connection connection = openConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, permissionCode);
            statement.executeUpdate();
        }
    }

    private void setLocalConfig(Connection connection, String name, String value)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(
                "select set_config(?, ?, true)")) {
            statement.setString(1, name);
            statement.setString(2, value);
            statement.executeQuery().close();
        }
    }

    private boolean toggleLike(
            UUID suggestionId,
            UUID userId,
            CountDownLatch beforeLock,
            CountDownLatch afterLock,
            CountDownLatch releaseAfterMutation) throws Exception {
        try (Connection connection = openConnection()) {
            connection.setAutoCommit(false);
            try {
                if (beforeLock != null) beforeLock.countDown();
                try (PreparedStatement lock = connection.prepareStatement(
                        "select id from suggestions where id = ? for update")) {
                    lock.setObject(1, suggestionId);
                    try (ResultSet result = lock.executeQuery()) {
                        assertTrue(result.next());
                    }
                }
                if (afterLock != null) afterLock.countDown();

                boolean exists;
                try (PreparedStatement query = connection.prepareStatement("""
                        select exists (
                            select 1
                            from suggestion_likes
                            where suggestion_id = ? and user_id = ?
                        )
                        """)) {
                    query.setObject(1, suggestionId);
                    query.setObject(2, userId);
                    try (ResultSet result = query.executeQuery()) {
                        result.next();
                        exists = result.getBoolean(1);
                    }
                }
                String mutation = exists
                        ? "delete from suggestion_likes where suggestion_id = ? and user_id = ?"
                        : "insert into suggestion_likes(suggestion_id, user_id) values (?, ?)";
                try (PreparedStatement update = connection.prepareStatement(mutation)) {
                    update.setObject(1, suggestionId);
                    update.setObject(2, userId);
                    update.executeUpdate();
                }
                if (releaseAfterMutation != null
                        && !releaseAfterMutation.await(5, TimeUnit.SECONDS)) {
                    throw new IllegalStateException("timed out waiting to release first toggle");
                }
                connection.commit();
                return !exists;
            } catch (Exception exception) {
                connection.rollback();
                throw exception;
            }
        }
    }
}
