package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/** Static safety contract for V206 employee/position numbering and position seeds. */
class EmployeePositionNumberingManagementCenterMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V206__employee_position_numbering_and_management_centers.sql");

    @Test
    void advancesEmployeeAndPositionSequencesFromTheTrueHistoricalMaximum() throws IOException {
        String sequenceSync = section(sql(), "sequence-sync");

        assertThat(sequenceSync)
                .contains("SELECT 'UT', COALESCE(MAX(substring(code FROM 3)::INTEGER), 0)")
                .contains("FROM employees")
                .contains("WHERE code ~ '^UT[0-9]+$'")
                .contains("SELECT 'ZW', COALESCE(MAX(substring(code FROM 3)::INTEGER), 0)")
                .contains("FROM positions")
                .contains("WHERE code ~ '^ZW[0-9]+$'")
                .contains("INSERT INTO master_code_sequences (prefix, last_seq)")
                .contains("ON CONFLICT (prefix) DO UPDATE")
                .contains("GREATEST(master_code_sequences.last_seq, EXCLUDED.last_seq)")
                .doesNotContain("is_deleted");
    }

    @Test
    void seedsOnlyActiveManagementCentersWithNeutralPositionMasterData() throws IOException {
        String seed = section(sql(), "management-center-position-seed");

        assertThat(seed)
                .contains("('MGT_HEAD',       '负责人',   '领导层', 1)")
                .contains("('MGT_DEPUTY',     '副负责人', '领导层', 2)")
                .contains("('MGT_SPECIALIST', '专员',     '员工',   3)")
                .contains("WHERE d.level = '管理中心'")
                .contains("AND d.is_deleted = FALSE")
                .contains("FALSE,\n       NULL")
                .contains("ON CONFLICT (code, department_id) DO NOTHING");
    }

    @Test
    void avoidsActiveNormalizedNameDuplicatesAndExistingCodeCollisions() throws IOException {
        String seed = section(sql(), "management-center-position-seed");

        assertThat(seed)
                .contains("existing.department_id = d.id")
                .contains("existing.is_deleted = FALSE")
                .contains("lower(btrim(existing.name)) = lower(btrim(t.name))")
                .contains("CROSS JOIN LATERAL")
                .contains("generate_series(")
                .contains("occupied.department_id = m.department_id")
                .contains("occupied.code = candidate.code")
                .contains("ORDER BY candidate.ordinal")
                .contains("LIMIT 1");
    }

    @Test
    void positionTitlesDoNotAssignDepartmentAuthority() throws IOException {
        String seed = section(sql(), "management-center-position-seed");

        assertThat(seed)
                .contains("authority remains assigned exclusively by")
                .contains("departments.manager_id")
                .doesNotContain("UPDATE departments")
                .doesNotContain("INSERT INTO role_permissions")
                .doesNotContain("INSERT INTO user_permissions");
    }

    private static String sql() throws IOException {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }

    private static String section(String sql, String marker) {
        String start = "-- " + marker + ":start";
        String end = "-- " + marker + ":end";
        int startIndex = sql.indexOf(start);
        int endIndex = sql.indexOf(end);

        assertThat(startIndex).as("start marker %s", start).isGreaterThanOrEqualTo(0);
        assertThat(endIndex).as("end marker %s", end).isGreaterThan(startIndex);
        return sql.substring(startIndex, endIndex);
    }
}
