package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ManualSubcontractMaterialIssueCreateRetirementMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V441__retire_manual_subcontract_material_issue_create.sql");

    @Test
    void migrationRetiresOnlyManualCreateAndPreservesGrantProvenance()
            throws IOException {
        String sql = Files.readString(MIGRATION);

        assertTrue(sql.contains("code = 'subcontract_material_issue:create'"));
        assertTrue(sql.contains("active = FALSE"));
        assertTrue(sql.contains("assignable = FALSE"));
        assertTrue(sql.contains("historical_grants_after <> historical_grants_before"));
        assertTrue(sql.contains("subcontract_material_issue:edit"));
        assertTrue(sql.contains("subcontract_material_issue:approve"));
        assertTrue(sql.contains("subcontract_material_issue:reverse"));
        assertTrue(sql.contains("UPDATE authorization_state"));

        assertFalse(sql.contains("DELETE FROM department_permissions"));
        assertFalse(sql.contains("DELETE FROM role_permissions"));
        assertFalse(sql.contains("DELETE FROM user_permission_overrides"));
        assertFalse(sql.contains("DELETE FROM manager_permission_delegations"));
    }
}
