package com.uten.imp.features.production.analysis;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Validate the actual migrated authority directory, rather than inventing a permission in a mock. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisForwardPermissionPostgresTest {
    @Test
    void forwardActionIsRegisteredOnAnalysisSurfaceWithoutRestoringRetiredPlanAuthorityOrDefaultGrants()
            throws Exception {
        try (var database = MigratedSchemaBaseline.openDatabase("material_forward_permission")) {
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),
                    database.getUsername(), database.getPassword()));
            String code = "production_material_analysis:forward_rd";
            assertThat(jdbc.queryForObject("SELECT count(*) FROM permissions WHERE code=? "
                    + "AND action_type='EXECUTE' AND grant_policy=ARRAY['NORMAL']::text[] "
                    + "AND NOT baseline AND NOT high_risk", Integer.class, code)).isEqualTo(1);
            assertThat(jdbc.queryForList("""
                    SELECT s.surface_key FROM permission_surface_permissions sp
                    JOIN permission_surfaces s ON s.id=sp.surface_id
                    JOIN permissions p ON p.id=sp.permission_id WHERE p.code=?
                    """, String.class, code)).containsExactly("production.material-analysis");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM permissions WHERE code='production_plan:forward_rd'",
                    Integer.class)).isZero();
            List<String> grantTables = jdbc.queryForList("""
                    SELECT DISTINCT relation.relname FROM pg_constraint fk
                    JOIN pg_class relation ON relation.oid=fk.conrelid
                    JOIN pg_attribute column_definition ON column_definition.attrelid=fk.conrelid
                        AND column_definition.attnum=ANY(fk.conkey)
                    WHERE fk.contype='f' AND fk.confrelid='permissions'::regclass
                        AND column_definition.attname='permission_id'
                        AND relation.relname<>'permission_surface_permissions'
                    ORDER BY relation.relname
                    """, String.class);
            assertThat(grantTables).contains("department_permissions", "user_permission_overrides",
                    "manager_permission_delegations");
            for (String grantTable : grantTables) {
                assertThat(jdbc.queryForObject("SELECT count(*) FROM " + grantTable
                        + " WHERE permission_id=(SELECT id FROM permissions WHERE code=?)", Integer.class, code))
                        .as(grantTable).isZero();
            }
        }
    }
}
