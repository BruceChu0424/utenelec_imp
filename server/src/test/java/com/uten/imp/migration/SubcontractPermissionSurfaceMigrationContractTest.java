package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SubcontractPermissionSurfaceMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V437__subcontract_permission_surfaces.sql");

    @Test
    void catalogIsPageSpecificVisibleInSettingsAndGrantsNobody() throws IOException {
        String sql = Files.readString(MIGRATION);

        assertTrue(sql.contains("'subcontract.preparation'"));
        assertTrue(sql.contains("'subcontract_preparation:view'"));
        assertTrue(sql.contains("'subcontract_preparation:start'"));
        assertTrue(sql.contains("'subcontract_inquiry:price:view'"));
        assertTrue(sql.contains("'subcontract_order:price:view'"));
        assertTrue(sql.contains("'subcontract_return:price:view'"));
        assertTrue(sql.contains("'subcontract_waste:suggestion:view'"));
        assertTrue(sql.contains("'subcontract_report:price:view'"));
        assertTrue(sql.contains("'warehouse.subcontract-outbound',"
                + " 'subcontract_material_issue:approve'"));
        assertTrue(sql.contains("permission_surface_permissions"));
        assertTrue(sql.contains("action_type = EXCLUDED.action_type"));
        assertTrue(sql.contains("active = TRUE"));
        assertTrue(sql.contains("assignable = TRUE"));
        assertTrue(sql.contains(
                "V437 refuses to activate pre-existing subcontract permission grants"));
        assertTrue(sql.contains("manager_permission_delegations source"));

        assertFalse(sql.contains("INSERT INTO department_permissions"));
        assertFalse(sql.contains("INSERT INTO role_permissions"));
        assertFalse(sql.contains("INSERT INTO user_permission_overrides"));
        assertFalse(sql.contains("INSERT INTO manager_permission_delegations"));
        assertFalse(sql.contains("'subcontract_outbound:handle',\n"
                + "     '执行"));
        assertFalse(sql.contains("procurement_iqc_rejection:"));
        assertFalse(sql.contains("quality.iqc-rejection"));
    }
}
