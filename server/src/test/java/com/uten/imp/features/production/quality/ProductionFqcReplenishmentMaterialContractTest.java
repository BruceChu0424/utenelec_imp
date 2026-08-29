package com.uten.imp.features.production.quality;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcReplenishmentMaterialContractTest {

    @Test
    void plannerCommandIsIdempotentRetriesOnlyShortageAndCreatesOneDraw()
            throws IOException {
        String source = source("main/java/com/uten/imp/features/production/quality/"
                + "ProductionFqcReplenishmentMaterialService.java");

        assertThat(source)
                .contains("WHERE attempt.idempotency_key = :key")
                .contains("相同幂等键已用于另一补产物料确认请求")
                .contains("demand.requiredQty()")
                .contains(".subtract(demand.committedQty())")
                .contains("stockAllocation.allocate(requests)")
                .contains("shortages.isEmpty() && drawId(cycleId) == null")
                .contains("FQC-MATERIAL-ALLOCATE:")
                .contains("外购物料库存不足；采购到货入库后使用新幂等键重试")
                .contains("当前不自动伪造子计划")
                .contains("须先完成独立委外供应并入库");
    }

    @Test
    void routesArePagedPermissionedAndExposeDurableStatus() throws IOException {
        String controller = source("main/java/com/uten/imp/features/production/quality/"
                + "ProductionFqcReplenishmentController.java");
        String service = source("main/java/com/uten/imp/features/production/quality/"
                + "ProductionFqcReplenishmentMaterialService.java");

        assertThat(controller)
                .contains("/material-tasks")
                .contains("/material-tasks/count")
                .contains("/{authorizationId}/material-confirmations")
                .contains("production_fqc_replenishment:view")
                .contains("production_fqc_replenishment:confirm");
        assertThat(service)
                .contains("PageResponse<MaterialTaskView>")
                .contains("AWAITING_ANALYSIS")
                .contains("AWAITING_CONFIRMATION")
                .contains("BLOCKED")
                .contains("AWAITING_WAREHOUSE")
                .contains("READY")
                .contains("CANCELLED")
                .contains("requireScopedOperationWritable");
        String reportable = source(
                "main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java");
        assertThat(reportable)
                .contains("WHEN recovery_auth.disposition_code = 'REWORK'")
                .contains("WHEN fn_fqc_replenishment_material_ready(")
                .contains("THEN 1")
                .contains("ELSE 2");
    }

    @Test
    void recoveryAnalysisCannotGenerateParallelNormalPlan() throws IOException {
        String command = source("main/java/com/uten/imp/features/production/analysis/"
                + "MaterialAnalysisCommandService.java");
        String contracts = source("main/java/com/uten/imp/features/production/analysis/"
                + "MaterialAnalysisContracts.java");

        assertThat(command)
                .contains("requireNotFqcRecoveryWorkspace(analysisId)")
                .contains("production_fqc_replenishment_analysis_links")
                .contains("禁止重复生成普通计划或供给单");
        assertThat(contracts)
                .contains("boolean fqcReplenishmentOnly")
                .contains("UUID fqcRecoveryAuthorizationId");
    }

    @Test
    void recoveryLotPriorityIsReworkThenMaterialReadyThenBlocked()
            throws IOException {
        String reportable = source(
                "main/java/com/uten/imp/features/production/dailyreport/"
                        + "ReportablePlanLineQueryService.java")
                .replaceAll("\\s+", " ");
        assertThat(reportable).contains(
                "ORDER BY CASE WHEN recovery_auth.disposition_code = 'REWORK' "
                        + "THEN 0 WHEN fn_fqc_replenishment_material_ready( "
                        + "recovery_auth.id) THEN 1 ELSE 2 END");
    }

    private static String source(String serverRelative) throws IOException {
        Path direct = Path.of("src").resolve(serverRelative);
        Path path = Files.exists(direct)
                ? direct : Path.of("server/src").resolve(serverRelative);
        return Files.readString(path, StandardCharsets.UTF_8);
    }
}
