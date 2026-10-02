package com.uten.imp.migration;

import com.uten.imp.features.rbac.GrantPolicy;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** 以真实 V677 授权守卫执行 V767，确认新模式默认不授及各授权通道约束。 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class StockCountApprovalPermissionsPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;

    @BeforeAll static void setup() throws Exception {
        PG.start();
        db = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        com.uten.imp.support.MigratedProjectionSchema.createTables(db, "766",
                "permissions", "permission_surfaces", "permission_surface_permissions",
                "department_permissions", "user_permission_overrides", "manager_permission_delegations");
        db.execute("ALTER TABLE permissions ADD CONSTRAINT permissions_code_format_chk CHECK (code ~ '^[a-z][a-z_]*(:[a-z][a-z_]*){1,2}$')");
        db.execute("""
                INSERT INTO permission_surfaces(id,surface_key) VALUES (gen_random_uuid(),'warehouse.stock-balance'), (gen_random_uuid(),'warehouse.stock-item'),
                    (gen_random_uuid(),'production.workshop-material'), (gen_random_uuid(),'warehouse.workshop-material');
                INSERT INTO permissions(code,grant_policy) VALUES ('stock:balance:adjust', ARRAY['INDIVIDUAL_ONLY']);
                INSERT INTO permissions(code,grant_policy,baseline) VALUES ('workshop_material:count', ARRAY['NORMAL'], true);
                INSERT INTO department_permissions(department_id,permission_id) SELECT gen_random_uuid(),id FROM permissions WHERE code='workshop_material:count';
                INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,enabled) SELECT gen_random_uuid(),id,gen_random_uuid(),true FROM permissions WHERE code='workshop_material:count';
                INSERT INTO user_permission_overrides(user_id,permission_id,active,effect) SELECT gen_random_uuid(),id,true,'grant' FROM permissions WHERE code='workshop_material:count';
                """);
        String governance = Files.readString(Path.of("src/main/resources/db/migration/V677__permission_catalog_single_source.sql"));
        int start = governance.indexOf("CREATE FUNCTION fn_guard_permission_grant_policy()");
        int end = governance.indexOf("-- 13.", start);
        db.execute(governance.substring(start, end));
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V767__stock_count_approval_permissions.sql")));
    }

    @AfterAll static void stop() { PG.stop(); }

    @Test void threeNamedPermissionsHaveNoImplicitGrantsAndCorrectReviewRisk() {
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'stock:count:%' "
                + "AND grant_policy=ARRAY['INDIVIDUAL_ONLY']::text[] AND NOT baseline", Integer.class)).isEqualTo(3);
        assertThat(db.queryForObject("SELECT count(*) FROM department_permissions", Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id "
                + "WHERE p.code LIKE 'stock:count:%'", Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'stock:count:%review' AND high_risk",
                Integer.class)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions", Integer.class)).isEqualTo(7);
        assertThat(db.queryForObject("SELECT grant_policy[1] FROM permissions WHERE code='stock:balance:adjust'", String.class))
                .isEqualTo("INDIVIDUAL_ONLY");
        assertThat(db.queryForObject("SELECT grant_policy[1] FROM permissions WHERE code='workshop_material:count'", String.class))
                .isEqualTo("INDIVIDUAL_ONLY");
        assertThat(db.queryForObject("SELECT count(*) FROM manager_permission_delegations", Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id "
                + "WHERE p.code='workshop_material:count'", Integer.class)).isEqualTo(1);
    }

    @Test void departmentAndManagerGrantsAreRejectedButExplicitPersonalGrantIsAllowed() {
        UUID permission = db.queryForObject("SELECT id FROM permissions WHERE code='stock:count:submit'", UUID.class);
        assertThatThrownBy(() -> db.update("INSERT INTO department_permissions(department_id,permission_id) VALUES (?,?)", UUID.randomUUID(), permission))
                .hasMessageContaining("只能逐人授予");
        assertThatThrownBy(() -> db.update("INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,enabled) VALUES (gen_random_uuid(),?,gen_random_uuid(),true)", permission))
                .hasMessageContaining("不能由负责人转授");
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,active,effect) VALUES (?,?,true,'grant')", UUID.randomUUID(), permission);
        assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE permission_id=?", Integer.class,
                permission)).isEqualTo(1);
        db.update("DELETE FROM user_permission_overrides WHERE permission_id=?", permission);
    }

    @Test void existingGrantPolicyExcludesModeFromBulkAndBaselineWithoutAdditionalFlags() {
        Set<GrantPolicy> policy = Set.of(GrantPolicy.INDIVIDUAL_ONLY);
        assertThat(GrantPolicy.departmentGrantable(policy)).isFalse();
        assertThat(GrantPolicy.delegable(policy)).isFalse();
        assertThat(GrantPolicy.bulkEligible(policy)).isFalse();
        assertThat(GrantPolicy.baselineEligible(policy)).isFalse();
        assertThat(GrantPolicy.individuallyGrantable(policy)).isTrue();
    }
}
