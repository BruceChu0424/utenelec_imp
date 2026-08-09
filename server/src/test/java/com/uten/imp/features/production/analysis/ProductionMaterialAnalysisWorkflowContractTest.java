package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionMaterialAnalysisWorkflowContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void notifyUsesOpenExternalCoverageAndDoesNotCountDoneActions() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(source).contains("activeOpenActionQty");
        assertThat(source).contains("status IN ('OPEN','CREATED','IN_PROGRESS')");
        assertThat(source).contains("inspection.passed_base_qty");
        assertThat(source).contains("inspection.status = 'RESOLVED'");
        assertThat(source).contains("returned_qty");
        assertThat(source).doesNotContain("action.status IN ('OPEN','CREATED','IN_PROGRESS','DONE')");
        assertThat(source).contains("Comparator.comparingInt(ActionGroup::sourcePriority)");
    }

    @Test
    void generationHashAndFormalPreviewIncludeAllAuthoritativeInputs() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(source).contains("request.departmentId()");
        assertThat(source).contains("request.workshopName()");
        assertThat(source).contains("request.workerId()");
        assertThat(source).contains("itemBillDate(quantity, request)");
        assertThat(source).contains("item.teamDepartmentId()");
        assertThat(source).contains("Objects.toString(item.workshopName(), \"\")");
        assertThat(source).contains("expectedQty.compareTo(proposedQty) != 0");
        assertThat(source).contains("!\"READY\".equals(segment.suggestedStatus())");
        assertThat(source).contains("line.setUnitRate(product.unitRate())");
    }

    @Test
    void approvalAndLegacyWriteEntrypointsAreFailClosed() throws Exception {
        String controller = source("features/production/plan/ProductionPlanController.java");
        String service = source("features/production/plan/ProductionPlanService.java");
        String schedule = source("features/production/schedule/ProductionScheduleController.java");

        assertThat(controller).contains("public PlanDetail create(");
        assertThat(controller).contains("ErrorCode.CONFLICT");
        assertThat(controller).doesNotContain("legacy-direct-plan-create");
        assertThat(controller).contains("hasAuthority('production_plan:approve')");
        assertThat(service).contains("access.requireWritable(p.getMakerId()");
        assertThat(schedule).contains("@PostMapping(\"/merge-plan\")");
        assertThat(schedule).doesNotContain("service.createMergePlan(req)");
    }

    @Test
    void reusablePreviewIsEmployeeLockedAndRequiresExactCanonicalPayload() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisService.java");

        assertThat(source).contains("currentUser.requireEmployeeId() + \":\" + request.idempotencyKey()");
        assertThat(source).contains("requireReusablePayloadMatches(");
        assertThat(source).contains("Objects.equals(header.warehouseId(), warehouseId)");
        assertThat(source).contains("decimal(existing[6]).compareTo(item.requestedQty()) != 0");
        assertThat(source).contains("Objects.equals(date(existing[7]), expectedDelivery)");
        int exactMatch = source.indexOf("requireReusablePayloadMatches(",
                source.indexOf("analysisId = findReusableAnalysis(normalized)"));
        int commandWrite = source.indexOf("recordSimpleCommand(analysisId, \"PREVIEW\"", exactMatch);
        assertThat(exactMatch).isGreaterThanOrEqualTo(0);
        assertThat(commandWrite).isGreaterThan(exactMatch);
    }

    @Test
    void committedSourceQuantityCannotBeExpandedInPlace() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisService.java");

        assertThat(source).contains("BigDecimal committed = decimal(row[7]).add(decimal(row[8]))");
        assertThat(source).contains("committed.signum() > 0");
        assertThat(source).contains("requested.compareTo(decimal(row[9])) > 0");
        assertThat(source).contains("requested.compareTo(committed) < 0");
    }

    @Test
    void reallocationIsCasIdempotentAndDrivesEverySharedStockOrdering() throws Exception {
        String contracts = source("features/production/analysis/MaterialAnalysisContracts.java");
        String controller = source("features/production/analysis/MaterialAnalysisController.java");
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(contracts).contains("record AllocationPriorityRequest(");
        assertThat(contracts).contains("int allocationPriority");
        assertThat(controller).contains("@PutMapping(\"/{id}/allocation-priorities\")");
        assertThat(controller).contains("production_material_analysis:reallocate");
        assertThat(service).contains("analysisId, \"REALLOCATE\", request.idempotencyKey()");
        assertThat(service).contains("requireCurrent(header, request.version(), request.fingerprint())");
        assertThat(service).contains("priorityValues.equals(expectedPriorities)");
        assertThat(service).contains("ORDER BY ai.line_priority, ai.delivery_date NULLS LAST, ai.id");
        assertThat(service).contains("result.add(\"REALLOCATE\")");
        assertThat(commands).contains("Comparator.comparingInt(ActionGroup::sourcePriority)");
    }

    @Test
    void pendingBoardReceivesServerAuthoredReadinessProjection() throws Exception {
        String dto = source("features/production/schedule/dto/PendingPlanRow.java");
        String service = source("features/production/schedule/ProductionScheduleService.java");

        assertThat(dto).contains("UUID materialAnalysisId");
        assertThat(dto).contains("BigDecimal readyNowQty");
        assertThat(dto).contains("BigDecimal readyByDateQty");
        assertThat(dto).contains("BigDecimal readinessRatio");
        assertThat(service).contains("latest_analysis.analysis_id");
        assertThat(service).contains("latest_analysis.ready_now_qty");
        assertThat(service).contains("ai.ready_now_qty");
        assertThat(service).doesNotContain("analysis_readiness");
        assertThat(service).contains("a.status IN ('ACTIVE','PARTIALLY_PLANNED')");
    }

    @Test
    void planPreviewAndNotifyConsumeOnlyPersistedDirectLayerAllocation() throws Exception {
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(service).contains("authoritativeReadyForPlanPreview(");
        assertThat(service).contains("material.allocatedAvailableQty()");
        assertThat(service).contains("depth == 1");
        assertThat(commands).contains(".filter(MaterialView::actionable)");
        assertThat(commands).contains("map(MaterialView::shortageQty)");
        assertThat(commands).contains("analysisService.refreshLocked(analysisId)");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
