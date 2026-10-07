package com.uten.imp.migration;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** V759 repairs page discoverability without changing who already holds a cost action. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsCostPermissionSurfaceMigrationPostgresTest {
    private static final List<String> ACTIONS = List.of(
            "goods:cost:edit", "goods:cost:confirm", "goods:cost:export", "goods:cost:template");
    private static final String ACTION_SQL =
            "('goods:cost:edit','goods:cost:confirm','goods:cost:export','goods:cost:template')";
    private static final String MIGRATION = "V759__goods_cost_permission_surfaces.sql";

    @Test
    void freshHeadOffersCostActionsOnTheGoodsPageButNotInBulkGrants() {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            flyway(postgres, null).migrate();
            JdbcTemplate db = database(postgres);
            assertCatalog(db);
            assertThat(db.queryForObject("SELECT max(version::int) FROM flyway_schema_history WHERE success", Integer.class))
                    .isEqualTo(Integer.parseInt(MigrationRehearsalSupport.CURRENT_HEAD_VERSION));
            assertThat(db.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success", Integer.class))
                    .isEqualTo(MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT);
            assertNoImplicitCostGrants(db);
        }
    }

    @Test
    void v758UpgradePreservesIdentitiesPoliciesAndViewOnlyGrantsAndCanReplay() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            flyway(postgres, "758").migrate();
            JdbcTemplate db = database(postgres);
            assertThat(costMappingCount(db)).isZero();
            UUID employee = db.queryForObject("SELECT id FROM employees WHERE code='ADMIN'", UUID.class);
            UUID department = db.queryForObject("SELECT id FROM departments ORDER BY id LIMIT 1", UUID.class);
            UUID actor = UUID.randomUUID();
            db.update("""
                    INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status)
                    VALUES(?,?,?,'not-a-login-hash',false,false,'active')
                    """, actor, employee, "cost-surface-upgrade-" + actor);
            db.update("""
                    INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                    SELECT ?,id,'grant' FROM permissions WHERE code='goods:cost:view'
                    """, actor);
            db.update("""
                    INSERT INTO department_permissions(department_id,permission_id)
                    SELECT ?,id FROM permissions WHERE code='goods:cost:view' ON CONFLICT DO NOTHING
                    """, department);
            List<String> catalogBefore = catalogSnapshot(db);
            List<String> surfacesBefore = surfaceSnapshot(db);
            List<String> grantsBefore = grantSnapshot(db);
            List<String> historyBefore = db.queryForList(
                    "SELECT version||':'||script||':'||checksum FROM flyway_schema_history WHERE success ORDER BY installed_rank", String.class);

            // A disabled page is not silently enabled and no partial mapping is left behind.
            try (var connection = DriverManager.getConnection(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                connection.setAutoCommit(false);
                try (var statement = connection.createStatement()) {
                    statement.executeUpdate("UPDATE permission_surfaces SET enabled=false WHERE surface_key='basic.goods'");
                    assertThatThrownBy(() -> statement.execute(migrationSql()))
                            .isInstanceOf(SQLException.class).hasMessageContaining("requires the enabled basic.goods");
                } finally {
                    connection.rollback();
                }
            }
            assertThat(costMappingCount(db)).isZero();
            assertThat(flyway(postgres, "759").migrate().migrationsExecuted).isEqualTo(1);
            assertCostCatalogFacts(db);
            assertThat(catalogSnapshot(db)).isEqualTo(catalogBefore);
            assertThat(surfaceSnapshot(db)).isEqualTo(surfacesBefore);
            assertThat(grantSnapshot(db)).isEqualTo(grantsBefore);
            assertThat(db.queryForList("""
                    SELECT version||':'||script||':'||checksum FROM flyway_schema_history
                    WHERE success AND version::int<=758 ORDER BY installed_rank
                    """, String.class)).isEqualTo(historyBefore);
            assertNoImplicitCostGrants(db);

            assertThat(flyway(postgres, "759").migrate().migrationsExecuted).isZero();
            List<String> mappings = mappingSnapshot(db);
            db.execute(migrationSql());
            db.execute(migrationSql());
            assertThat(mappingSnapshot(db)).isEqualTo(mappings);
            assertThat(catalogSnapshot(db)).isEqualTo(catalogBefore);
            assertThat(grantSnapshot(db)).isEqualTo(grantsBefore);
            assertCostCatalogFacts(db);
            // 重放出来的 759 态能一路升到当前 head：共享目录注册表(含 V812 层级列)照常装载。
            assertThat(flyway(postgres, null).migrate().migrationsExecuted).isPositive();
            assertCatalog(db);
            assertNoImplicitCostGrants(db);
        }
    }

    private static void assertCatalog(JdbcTemplate db) {
        var surfaces = new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(db));
        assertThat(surfaces.permissionsFor("basic.goods")).containsAll(ACTIONS).contains("goods:cost:view");
        var policies = new PermissionGrantPolicyCatalog(db);
        for (String code : ACTIONS) {
            surfaces.requireContains("basic.goods", code);
            assertThatThrownBy(() -> surfaces.requireContains("basic.client", code)).isInstanceOf(ApiException.class);
            var policy = policies.policyOf(code).orElseThrow();
            assertThat(policy).containsExactly(GrantPolicy.BULK_EXCLUDED);
            assertThat(GrantPolicy.delegable(policy)).isTrue();
            assertThat(GrantPolicy.bulkEligible(policy)).isFalse();
            assertThat(GrantPolicy.baselineEligible(policy)).isFalse();
        }
        assertCostCatalogFacts(db);
    }

    /**
     * Raw-SQL subset of {@link #assertCatalog} that stays valid on schemas older
     * than the surface hierarchy (V812): the 758→759 replay test freezes the
     * schema at V759, where the shared catalog repository column set no longer
     * matches. The registry itself is exercised after that test upgrades the
     * replayed schema to head.
     */
    private static void assertCostCatalogFacts(JdbcTemplate db) {
        assertThat(costMappingCount(db)).isEqualTo(4);
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code IN " + ACTION_SQL
                + " AND sensitivity='SENSITIVE_COMMERCIAL' AND grant_policy=ARRAY['BULK_EXCLUDED']::text[] AND NOT baseline", Integer.class))
                .isEqualTo(4);
        assertThat(db.queryForList("""
                SELECT surface.surface_key FROM permission_surface_permissions mapping
                JOIN permission_surfaces surface ON surface.id=mapping.surface_id
                JOIN permissions permission ON permission.id=mapping.permission_id
                WHERE permission.code IN
                """ + ACTION_SQL + " ORDER BY permission.code", String.class))
                .containsExactly("basic.goods", "basic.goods", "basic.goods", "basic.goods");
    }

    private static void assertNoImplicitCostGrants(JdbcTemplate db) {
        for (String table : List.of("department_permissions", "user_permission_overrides")) {
            assertThat(db.queryForObject("SELECT count(*) FROM " + table
                    + " grant_row JOIN permissions permission ON permission.id=grant_row.permission_id WHERE permission.code IN "
                    + ACTION_SQL, Integer.class)).isZero();
        }
    }

    private static int costMappingCount(JdbcTemplate db) {
        return db.queryForObject("SELECT count(*) FROM permission_surface_permissions mapping JOIN permissions permission"
                + " ON permission.id=mapping.permission_id WHERE permission.code IN " + ACTION_SQL, Integer.class);
    }

    private static List<String> catalogSnapshot(JdbcTemplate db) {
        return db.queryForList("SELECT to_jsonb(permission)::text FROM permissions permission ORDER BY code", String.class);
    }

    private static List<String> surfaceSnapshot(JdbcTemplate db) {
        return db.queryForList("SELECT to_jsonb(surface)::text FROM permission_surfaces surface ORDER BY surface_key", String.class);
    }

    private static List<String> mappingSnapshot(JdbcTemplate db) {
        return db.queryForList("SELECT surface_id::text||':'||permission_id FROM permission_surface_permissions ORDER BY surface_id,permission_id", String.class);
    }

    private static List<String> grantSnapshot(JdbcTemplate db) {
        return db.queryForList("""
                SELECT 'department:'||to_jsonb(grant_row)::text AS grant_fact FROM department_permissions grant_row
                UNION ALL SELECT 'individual:'||to_jsonb(grant_row)::text FROM user_permission_overrides grant_row
                ORDER BY grant_fact
                """, String.class);
    }

    private static String migrationSql() throws Exception {
        try (var in = GoodsCostPermissionSurfaceMigrationPostgresTest.class.getResourceAsStream("/db/migration/" + MIGRATION)) {
            return new String(Objects.requireNonNull(in).readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static JdbcTemplate database(PostgreSQLContainer<?> postgres) {
        return new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
    }

    private static Flyway flyway(PostgreSQLContainer<?> postgres, String target) {
        var config = Flyway.configure().dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration").initSql("SET client_min_messages = WARNING");
        if (target != null) config.target(target);
        return config.load();
    }
}
