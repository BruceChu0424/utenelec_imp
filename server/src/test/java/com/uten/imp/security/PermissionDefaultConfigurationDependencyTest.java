package com.uten.imp.security;

import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionDependencyCatalog;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/** Every shipped department configuration is checked against the same runtime dependency rules. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionDefaultConfigurationDependencyTest {
    @Test void allConfiguredDefaultActionsHaveTheirNecessaryReadsAfterInheritanceAndBaseline() {
        var jdbc = PermissionCatalogTestSupport.database();
        List<Permission> permissions = jdbc.query("SELECT code, action_type FROM permissions", (row, index) -> {
            Permission permission = new Permission();
            permission.setCode(row.getString(1)); permission.setActionType(row.getString(2));
            return permission;
        });
        assertThat(permissions).as("The migrated permission catalog must exist").isNotEmpty();
        var dependencies = new PermissionDependencyCatalog(permissions);
        Map<String, Set<String>> configured = new LinkedHashMap<>();
        jdbc.query("""
                WITH RECURSIVE ancestry(department_id, parent_id, ancestor_id) AS (
                    SELECT id, parent_id, id FROM departments WHERE NOT is_deleted
                    UNION ALL
                    SELECT child.department_id, parent.parent_id, parent.id
                    FROM ancestry child JOIN departments parent ON parent.id=child.parent_id
                    WHERE NOT parent.is_deleted
                ), held AS (
                    SELECT department.code AS department, permission.code
                    FROM departments department CROSS JOIN permissions permission
                    WHERE NOT department.is_deleted AND permission.baseline
                    UNION
                    SELECT department.code, permission.code
                    FROM ancestry JOIN departments department ON department.id=ancestry.department_id
                    JOIN department_permissions allocation ON allocation.department_id=ancestry.ancestor_id
                    JOIN permissions permission ON permission.id=allocation.permission_id
                ) SELECT department, code FROM held ORDER BY department, code
                """, row -> {
            configured.computeIfAbsent(row.getString(1), ignored -> new LinkedHashSet<>()).add(row.getString(2));
        });
        assertThat(configured).as("Seeded department authorization must be included").isNotEmpty();
        Map<String, Map<String, List<String>>> incomplete = new LinkedHashMap<>();
        configured.forEach((department, held) -> {
            Set<String> usable = dependencies.usablePermissions(held);
            for (String code : held) {
                List<String> missing = dependencies.missingDependencies(code, held);
                if (!usable.contains(code) || !missing.isEmpty()) {
                    incomplete.computeIfAbsent(department, ignored -> new LinkedHashMap<>())
                            .put(code, missing);
                }
            }
        });
        assertThat(incomplete).as("Default configured actions cannot silently lose functionality through another module read")
                .isEmpty();
    }
}
