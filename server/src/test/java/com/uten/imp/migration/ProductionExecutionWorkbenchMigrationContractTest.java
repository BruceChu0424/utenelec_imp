package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionExecutionWorkbenchMigrationContractTest {

    private static String migration() throws Exception {
        Path direct = Path.of(
                "src/main/resources/db/migration/"
                        + "V470__production_execution_root_workbenches.sql");
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(
                Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }

    @Test
    void firstReportIsTheOnlyNewReadyToInProgressTransition() throws Exception {
        String sql = migration();

        assertThat(sql)
                .contains("fn_is_execution_report_auto_start_authorized")
                .contains("app.production_report_auto_start_segment_id")
                .contains("OLD.status = 'READY'")
                .contains("NEW.status = 'IN_PROGRESS'")
                .contains("'AUTO_START_ON_REPORT'")
                .contains("segment.status IN ('READY','DISPATCHED','IN_PROGRESS')")
                .contains("FALSE AS can_dispatch_fact")
                .contains("FALSE AS can_start_fact");
    }

    @Test
    void rootStatusAndPermissionSurfaceMatchTheReplacementFlow()
            throws Exception {
        String sql = migration();
        int workshopInsert = sql.lastIndexOf(
                "INSERT INTO permission_surface_permissions");
        String surfaceTail = sql.substring(workshopInsert);

        assertThat(sql)
                .contains("THEN 'PARTIALLY_SCHEDULED'")
                .contains("('production_plan:view', 'production_execution:overview')")
                .contains("('production_daily_report:create', 'production_execution:view')")
                .contains("v470_manager_delegation_expansion")
                .contains("'production.workshop-tasks'")
                .contains("production_plan:view:all");
        assertThat(surfaceTail)
                .contains("production_execution:view")
                .contains("production_daily_report:create")
                .doesNotContain("production_execution:dispatch")
                .doesNotContain("production_execution:start");
    }
}
