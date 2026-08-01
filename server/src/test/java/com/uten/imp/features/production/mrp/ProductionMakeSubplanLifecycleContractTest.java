package com.uten.imp.features.production.mrp;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionMakeSubplanLifecycleContractTest {

    @Test
    void v1ConfirmationRegistersEveryGeneratedSubplanAsPackageDocument()
            throws Exception {
        String source = source("ProductionExecutionPackageCommandService.java");

        int generate = source.indexOf("generateSelfMadeSubplansForPackage");
        int record = source.indexOf("ledger.recordDocument(", generate);
        int result = source.indexOf("return new PlanningPackageResult(", record);

        assertTrue(generate >= 0 && record > generate && result > record);
        assertTrue(source.substring(record, result).contains("\"SUBPLAN\""));
        assertTrue(source.substring(record, result).contains("subplan.planId()"));
        assertTrue(source.substring(record, result).contains("subplan.billNo()"));
    }

    @Test
    void genericPlanLifecycleCannotOrphanExecutionV1Subplan()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/plan/ProductionPlanService.java"));

        int delete = source.indexOf("public void delete(UUID id)");
        int approve = source.indexOf("public PlanDetail approve(UUID id)");
        int reverse = source.indexOf("public PlanDetail reverse(UUID id)");
        int progress = source.indexOf("// ====================== 生产进度看板聚合", reverse);

        assertTrue(delete >= 0 && approve > delete);
        assertTrue(reverse >= 0 && progress > reverse);
        assertTrue(source.substring(delete, approve).contains(
                "rejectDirectLifecycleOfExecutionV1Subplan(id, \"删除\")"));
        assertTrue(source.substring(reverse, progress).contains(
                "rejectDirectLifecycleOfExecutionV1Subplan(id, \"红冲\")"));
        assertTrue(source.contains("link.source = 'EXECUTION_V1'"));
        assertTrue(source.contains("请从父计划的计划包执行取消或红冲"));
    }

    @Test
    void parentPackageLifecycleRejectsChildWithConfirmedExecutionPackage()
            throws Exception {
        String source = source("ProductionPlanningPackageService.java");
        int downstream = source.indexOf("private boolean hasActiveSubplanDownstream");
        int replay = source.indexOf("private PlanningPackageResult replay", downstream);

        assertTrue(downstream >= 0 && replay > downstream);
        String method = source.substring(downstream, replay);
        assertTrue(method.contains("FROM production_planning_packages package"));
        assertTrue(method.contains("package.plan_id = :id"));
        assertTrue(method.contains("package.status = 'CONFIRMED'"));
    }

    private static String source(String file) throws Exception {
        return Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/mrp/" + file));
    }
}
