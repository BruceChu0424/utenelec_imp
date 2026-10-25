package com.uten.imp.ops;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real fresh installation and V918 upgrade. Synthetic isolated databases only; never invokes reset. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDataResetRetirementPostgresTest {
    private static final List<String> REFRESHES = List.of("finance_ar_ap", "production_monthly", "purchase_monthly",
            "sales_monthly", "stock_monthly", "subcontract_monthly");

    @Test
    void freshInstallationRemovesEntriesAndLegacyFlagsCannotBypassPermanentHistory() throws Exception {
        try (var database = MigratedSchemaBaseline.openDatabase("business_reset_removed")) {
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),
                    database.getUsername(), database.getPassword()));
            assertNoReset(jdbc);
            String source = UUID.randomUUID().toString();
            jdbc.update("""
                    INSERT INTO business_record_history(source_table,source_id,payload,operation)
                    VALUES ('sales_order_items',?,jsonb_build_object('original','retained'),'DELETE')
                    """, source);
            long generation = jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
            try (var connection = database.openConnection(); var statement = connection.createStatement()) {
                connection.setAutoCommit(false);
                statement.execute("SET LOCAL app.test_business_reset='CLEAR_TEST_BUSINESS_WITH_HISTORY'");
                statement.execute("SET LOCAL app.business_test_reset_verified='0:legacy-flag'");
                for (String command : List.of("DELETE FROM business_record_history", "TRUNCATE business_record_history",
                        "UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1")) {
                    var savepoint = connection.setSavepoint();
                    SQLException rejected = assertThrows(SQLException.class, () -> statement.execute(command));
                    assertThat(rejected.getSQLState()).isEqualTo("55000");
                    connection.rollback(savepoint);
                }
                connection.rollback();
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history WHERE source_id=?", Long.class, source)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class)).isEqualTo(generation);
        }
    }

    @Test
    void upgradingActualV918DeletesCapabilityAndPreservesDataAndRuntimeRefresh() throws Exception {
        try (var postgres = new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var dataSource = new DriverManagerDataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
            var jdbc = new JdbcTemplate(dataSource);
            jdbc.execute("CREATE ROLE uten LOGIN NOINHERIT NOSUPERUSER PASSWORD 'retirement-fixture-only'");
            var old = TestFlyway.configure().dataSource(dataSource).locations("classpath:db/migration").target("918").load();
            old.migrate();
            assertThat(jdbc.queryForObject("SELECT to_regprocedure('public.business_data_reset()')::text", String.class)).isNotNull();
            UUID retiredPermission = jdbc.queryForObject("SELECT id FROM permissions WHERE code='system:business_data_reset'", UUID.class);
            // Preserve a real prior maintenance membership boundary whose owner differs from all refresh owners.
            jdbc.execute("CREATE ROLE retirement_reset_owner NOLOGIN NOSUPERUSER");
            jdbc.execute("ALTER FUNCTION public.business_data_reset() OWNER TO retirement_reset_owner");
            jdbc.execute("CREATE ROLE retirement_maintainer LOGIN NOINHERIT NOSUPERUSER PASSWORD 'maintainer-fixture-only'");
            jdbc.execute("GRANT retirement_reset_owner TO retirement_maintainer");
            jdbc.execute("GRANT USAGE ON SCHEMA public TO retirement_maintainer");
            for (String view : REFRESHES) jdbc.execute("GRANT EXECUTE ON FUNCTION public.refresh_" + view + "_mv() TO retirement_maintainer");
            var maintainer = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "retirement_maintainer", "maintainer-fixture-only"));
            for (String view : REFRESHES) maintainer.execute("SELECT public.refresh_" + view + "_mv()");
            UUID client = UUID.randomUUID(), goods = UUID.randomUUID(), order = UUID.randomUUID();
            jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence) VALUES (?,'RETIRE-CLIENT','保留客户','使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))", client);
            jdbc.update("INSERT INTO goods(id,code,name,code_sequence,min_qty) VALUES (?,'RETIRE-GOODS','保留货品',(SELECT coalesce(max(code_sequence),0)+1 FROM goods),17)", goods);
            jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,total_original,total_local) VALUES (?,'XD20261023919001','2026-10-23',?,123,123)", order, client);
            UUID accountStyle = UUID.randomUUID();
            jdbc.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES (?,'RETIRE-ACCOUNT-STYLE','保留账户科目','ACCOUNT',0,'使用')", accountStyle);
            UUID currency = jdbc.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted LIMIT 1", UUID.class);
            jdbc.update("INSERT INTO accounts(code,name,account_type,currency_id,style_id,init_balance,balance_current) VALUES ('RETIRE-ACCOUNT','保留余额','BANK',?,?,456,456)", currency, accountStyle);
            jdbc.update("INSERT INTO business_record_history(source_table,source_id,payload,operation) VALUES ('sales_order_items',?,jsonb_build_object('original','retained'),'DELETE')", order.toString());
            UUID delegatedUser = seedDelegations(jdbc);
            UUID templateActor = jdbc.queryForObject("SELECT id FROM users WHERE login_account='retirement-grantor'", UUID.class);
            UUID activeTemplate = UUID.randomUUID(), historicalTemplate = UUID.randomUUID();
            jdbc.update("INSERT INTO permission_templates(id,name,permission_codes,created_by,updated_by,is_deleted) VALUES (?,'现有模板残留','[\"goods:view\",\"system:business_data_reset\"]'::jsonb,?,?,false),(?,'已删除历史模板','[\"goods:view\",\"system:business_data_reset\"]'::jsonb,?,?,true)", activeTemplate,templateActor,templateActor,historicalTemplate,templateActor,templateActor);
            String historicalTemplateBefore = jdbc.queryForObject("SELECT row_to_json(t)::text FROM permission_templates t WHERE id=?", String.class, historicalTemplate);
            jdbc.update("INSERT INTO staff_mfa(user_id,secret_ciphertext,enabled_at,failed_attempts,locked_until) VALUES (?,'g1:synthetic-fixture-only',now(),3,now()+interval '10 minutes')", delegatedUser);
            var resolver = permissionResolver(jdbc);
            Map<UUID, Set<String>> effectiveBefore = resolver.grantedPermissionsFor(List.of(delegatedUser), Set.of("goods:view", "goods:edit"));
            assertThat(effectiveBefore.get(delegatedUser)).contains("goods:view").doesNotContain("goods:edit");
            long epochBefore = jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
            List<Map<String, Object>> staleBefore = jdbc.queryForList("SELECT delegation.* FROM manager_permission_delegations delegation JOIN permissions p ON p.id=delegation.permission_id WHERE user_id=? AND p.code='goods:edit'", delegatedUser);
            Map<String, String> refreshBefore = refreshSecurity(jdbc);
            Map<String, String> before = snapshot(jdbc);
            List<String> history = jdbc.queryForList("SELECT row_to_json(h)::text FROM flyway_schema_history h ORDER BY installed_rank", String.class);
            long generation = jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
            var upgrade = TestFlyway.configure().dataSource(dataSource).locations("classpath:db/migration").target("920").load();
            assertThat(upgrade.migrate().migrationsExecuted).isEqualTo(2);
            upgrade.validate();
            assertThat(upgrade.migrate().migrationsExecuted).isZero();
            assertNoReset(jdbc);
            for (String table : List.of("department_permissions","user_permission_overrides","manager_permission_delegations","permission_surface_permissions")) {
                assertThat(jdbc.queryForObject("SELECT count(*) FROM public." + table + " WHERE permission_id=?", Long.class, retiredPermission)).as(table + " must not retain the removed permission UUID").isZero();
            }
            assertThat(jdbc.queryForObject("SELECT permission_codes::text FROM permission_templates WHERE id=?", String.class, activeTemplate)).isEqualTo("[\"goods:view\"]");
            assertThat(jdbc.queryForObject("SELECT row_version FROM permission_templates WHERE id=?", Long.class, activeTemplate)).isEqualTo(1);
            assertThat(jdbc.queryForObject("SELECT row_to_json(t)::text FROM permission_templates t WHERE id=?", String.class, historicalTemplate)).isEqualTo(historicalTemplateBefore);
            assertThat(snapshot(jdbc)).isEqualTo(before);
            assertThat(refreshSecurity(jdbc)).isEqualTo(refreshBefore);
            assertThat(jdbc.queryForObject("SELECT proowner::regrole::text FROM pg_proc WHERE oid='public.fn_require_runtime_refresh()'::regprocedure", String.class)).isEqualTo("retirement_reset_owner");
            for (String view : REFRESHES) maintainer.execute("SELECT public.refresh_" + view + "_mv()");
            assertThat(resolver.grantedPermissionsFor(List.of(delegatedUser), Set.of("goods:view", "goods:edit"))).isEqualTo(effectiveBefore);
            assertThat(jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class)).isGreaterThan(epochBefore);
            assertThat(jdbc.queryForList("SELECT delegation.* FROM manager_permission_delegations delegation JOIN permissions p ON p.id=delegation.permission_id WHERE user_id=? AND p.code='goods:edit'", delegatedUser)).isEqualTo(staleBefore);
            assertThat(jdbc.queryForObject("SELECT delegation.grantor_authorization_epoch=state.epoch FROM manager_permission_delegations delegation JOIN permissions p ON p.id=delegation.permission_id CROSS JOIN authorization_state state WHERE user_id=? AND p.code='goods:view' AND state.singleton_id=1", Boolean.class, delegatedUser)).isTrue();
            assertThat(jdbc.queryForObject("SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='manager_permission_delegations'::regclass AND tgname='trg_manager_permission_delegations_auth_version'", String.class)).isEqualTo("O");
            assertThat(jdbc.queryForList("SELECT row_to_json(h)::text FROM flyway_schema_history h ORDER BY installed_rank", String.class))
                    .startsWith(history.toArray(String[]::new)).hasSize(history.size() + 2);
            assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class)).isEqualTo(generation);
            var runtime = new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), "uten", "retirement-fixture-only"));
            for (String view : REFRESHES) runtime.execute("SELECT public.refresh_" + view + "_mv()");
            jdbc.execute("CREATE ROLE retirement_outsider LOGIN NOSUPERUSER NOINHERIT PASSWORD 'outsider-fixture-only'");
            jdbc.execute("GRANT USAGE ON SCHEMA public TO retirement_outsider");
            var outsider = new DriverManagerDataSource(postgres.getJdbcUrl(), "retirement_outsider", "outsider-fixture-only");
            try (var connection = outsider.getConnection(); var statement = connection.createStatement()) {
                for (String view : REFRESHES) {
                    assertThat(assertThrows(SQLException.class, () -> statement.execute("SELECT public.refresh_" + view + "_mv()")).getSQLState()).isEqualTo("42501");
                }
                assertThat(assertThrows(SQLException.class, () -> statement.execute("SELECT public.fn_require_runtime_refresh()")).getSQLState()).isEqualTo("42501");
            }
            assertThat(jdbc.queryForObject("SELECT has_function_privilege('uten','public.fn_require_runtime_refresh()','EXECUTE')", Boolean.class)).isFalse();
            try (Connection connection = runtime.getDataSource().getConnection(); var statement = connection.createStatement()) {
                assertThat(assertThrows(SQLException.class, () -> statement.execute("SELECT * FROM public.business_data_reset()")).getSQLState())
                        .isEqualTo("42883");
            }
        }
    }

    private static UUID seedDelegations(JdbcTemplate jdbc) {
        UUID department=UUID.randomUUID(), employee=UUID.randomUUID(), grantorEmployee=UUID.randomUUID(), recipient=UUID.randomUUID(), grantor=UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,level) VALUES (?,'RETIRE-DELEGATION','独立权限回归部门','一级部门')", department);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES (?,'RETIRE-EMPLOYEE','权限保留回归','其他',?,CURRENT_DATE,'active','regular')", employee, department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES (?,?,'retirement-recipient','fixture-only',false,'active')", recipient, employee);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES (?,'RETIRE-GRANTOR','授权人回归','其他',?,CURRENT_DATE,'active','regular')", grantorEmployee, department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES (?,?,'retirement-grantor','fixture-only',false,'active',true)", grantor, grantorEmployee);
        jdbc.update("""
                INSERT INTO manager_permission_delegations(
                    user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,
                    target_user_generation,target_employee_generation,target_department_generation,
                    grantor_user_generation,grantor_employee_generation,grantor_auth_version,
                    grantor_authorization_epoch,scope_source,scope_department_id,scope_generation)
                SELECT target.id,p.id,d.id,true,'basic.goods',grantor.id,
                    target.permission_delegation_generation,e.permission_delegation_generation,d.permission_delegation_generation,
                    grantor.permission_delegation_generation,NULL,grantor.auth_version,
                    state.epoch-CASE WHEN p.code='goods:edit' THEN 1 ELSE 0 END,'SUPER_ADMIN',NULL,NULL
                FROM users target JOIN employees e ON e.id=target.employee_id JOIN departments d ON d.id=e.department_id
                CROSS JOIN users grantor CROSS JOIN permissions p CROSS JOIN authorization_state state
                WHERE target.id=? AND grantor.id=? AND p.code IN ('goods:view','goods:edit') AND state.singleton_id=1
                """, recipient, grantor);
        return recipient;
    }

    private static PermissionResolver permissionResolver(JdbcTemplate jdbc) {
        var catalog = mock(PermissionRepository.class);
        when(catalog.findAll()).thenReturn(jdbc.query("SELECT code,action_type FROM permissions", (rows, index) -> {
            var permission = new Permission();
            permission.setCode(rows.getString("code"));
            permission.setActionType(rows.getString("action_type"));
            return permission;
        }));
        var resolver = new PermissionResolver(catalog, mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class), mock(EmployeeRepository.class), mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class), mock(DepartmentRepository.class), mock(ManagerPermissionDelegationRepository.class),
                new PermissionDelegationPolicy(new PermissionGrantPolicyCatalog(jdbc)),
                new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc)),
                new PagePermissionDelegationFeatureGate(true), jdbc);
        resolver.initializeDependencyCatalog();
        return resolver;
    }

    private static Map<String, String> refreshSecurity(JdbcTemplate jdbc) {
        var result = new LinkedHashMap<String, String>();
        for (String view : REFRESHES) result.put(view, jdbc.queryForObject(
                "SELECT jsonb_build_array(proowner,proacl,prosecdef,proconfig)::text FROM pg_proc WHERE oid=CAST(? AS regprocedure)",
                String.class, "public.refresh_" + view + "_mv()"));
        return result;
    }

    private static Map<String, String> snapshot(JdbcTemplate jdbc) {
        var result = new LinkedHashMap<String, String>();
        for (String table : List.of("clients", "goods", "sales_orders", "accounts", "payment_styles", "stock_balances",
                "business_record_history", "users", "departments", "user_data_scopes", "system_settings", "staff_mfa")) {
            result.put(table, jdbc.queryForObject("SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text,'[]') FROM public." + table + " t", String.class));
        }
        return result;
    }

    private static void assertNoReset(JdbcTemplate jdbc) {
        assertThat(jdbc.queryForList("""
                SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                WHERE n.nspname='public' AND p.prokind IN ('f','p')
                  AND (p.proname='business_data_reset' OR p.proname LIKE 'fn_business_test_reset%'
                    OR p.prosrc LIKE '%fn_business_test_reset_active%'
                    OR p.prosrc LIKE '%app.test_business_reset%'
                    OR p.prosrc LIKE '%app.business_test_reset%')
                """, String.class)).isEmpty();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM permissions WHERE code='system:business_data_reset'", Long.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT to_regprocedure('public.fn_require_runtime_maintenance(boolean)')::text", String.class)).isNull();
        assertThat(jdbc.queryForObject("SELECT to_regprocedure('public.fn_require_runtime_refresh()')::text", String.class)).isNotNull();
    }
}
