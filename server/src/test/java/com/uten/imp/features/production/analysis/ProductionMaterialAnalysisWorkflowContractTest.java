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
    void planApprovalReusesV192AtomicWorkshopLearning() throws Exception {
        String planService = source(
                "features/production/plan/ProductionPlanService.java");
        String planningDraft = source(
                "features/production/mrp/ProductionPlanningDraftService.java");
        String packageCommand = source(
                "features/production/mrp/ProductionExecutionPackageCommandService.java");

        assertThat(planService)
                .contains("planningDraftService.applyActive(id)")
                .doesNotContain("learnDefaultWorkshops")
                .doesNotContain("default_workshop_department_id");
        assertThat(planningDraft).contains(
                "executionCommand.confirm(planId, request)");
        assertThat(packageCommand).contains(
                "workshopPreferences.learnFromConfirmedSegments(");
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

    @Test
    void makeNotificationIsRejectedWhileLowerLevelMaterialsArePending() throws Exception {
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(commands).contains("\"MAKE\".equals(route)");
        assertThat(commands).contains("lines.stream().anyMatch(MaterialView::lowerLevelPending)");
        assertThat(commands).contains("自制件的下层物料尚未齐套，请先完成底层备料再安排生产");
    }

    @Test
    void makeNotificationMovesExactEntitlementBetweenTwoAuthoritativeRefreshes()
            throws Exception {
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        int notifyStart = commands.indexOf(
                "public AnalysisView notifySupply(UUID analysisId");
        int notifyEnd = commands.indexOf(
                "private List<ActionGroup> selectedGroups", notifyStart);
        String notify = commands.substring(notifyStart, notifyEnd);
        assertThat(notify.indexOf("lockAnalysisInventoryDimensions(analysisId)"))
                .isLessThan(notify.indexOf(
                        "analysisService.lockHeader(analysisId)"));
        int external = notify.indexOf(
                "for (ActionDraft action : created)");
        int firstRefresh = notify.indexOf(
                "analysisService.refreshLocked(analysisId)", external);
        int delegate = notify.indexOf(
                "stockEntitlement.delegateMakeEntitlements", firstRefresh);
        int secondRefresh = notify.indexOf(
                "analysisService.refreshLocked(analysisId)", delegate);
        assertThat(external).isGreaterThanOrEqualTo(0);
        assertThat(firstRefresh).isGreaterThan(external);
        assertThat(delegate).isGreaterThan(firstRefresh);
        assertThat(secondRefresh).isGreaterThan(delegate);
        assertThat(commands)
                .contains("stockEntitlement.restoreMakeDelegationsForAction(")
                .contains("CASE WHEN route = 'MAKE' THEN 0 ELSE 1 END");
    }

    @Test
    void legacyGroupedActionsRemainOpenCoverageAfterPerPathKeyUpgrade() throws Exception {
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(commands).contains("activeOpenActionQty(UUID analysisId, ActionGroup group)");
        assertThat(commands).contains("JOIN preplan_supply_actions action ON action.id = allocation.action_id");
        assertThat(commands).contains("allocation.analysis_material_id IN (:materialIds)");
        assertThat(commands).contains("groupKeys.addAll(legacyKeys)");
        assertThat(commands).contains("activeOpenActionQtyByGroup(");
        assertThat(commands).contains("status IN ('OPEN','CREATED','IN_PROGRESS')");
    }

    @Test
    void notifyAcceptsExplicitQuantitiesCappedByLiveResidual() throws Exception {
        String contracts = source("features/production/analysis/MaterialAnalysisContracts.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        // 协议：可选的逐组指定数量（缺省 = 缺口−在途 全量）。
        assertThat(contracts).contains("record SupplyQuantityInput(");
        assertThat(contracts).contains("List<@Valid SupplyQuantityInput> quantities");
        // 服务端按操作组解析并以实时余量复核：0 < qty <= 缺口−在途。
        assertThat(commands).contains("quantityOverrides(view, request, groups)");
        assertThat(commands).contains("quantityOverrides.get(group.groupKey())");
        assertThat(commands).contains("requested.compareTo(delta) > 0");
        assertThat(commands).contains("缺口扣除在途任务后的余量");
        // 落库与分摊都用复核后的数量，不再默认 delta。
        assertThat(commands).contains(
                "allocateAction(actionId, analysisId, group.materials(), qty)");
        // 幂等哈希必须覆盖数量，防止同键不同量误重放。
        assertThat(commands).contains("\"QTY|\"");
    }

    @Test
    void generateResultCarriesDrawDocumentsWithReadableBillNo() throws Exception {
        String contracts = source("features/production/analysis/MaterialAnalysisContracts.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        // 生成结果携带物料提货单（领料单 DRAW）的可读单号，供分析页直接列出。
        assertThat(contracts).contains("record GeneratedDraw(UUID drawId, String billNo)");
        assertThat(contracts).contains("List<GeneratedDraw> drawDocuments");
        assertThat(commands).contains("drawDocuments(UUID packageId)");
        assertThat(commands).contains(
                "JOIN stock_documents stock ON stock.id = doc.document_id");
    }

    @Test
    void analysisAndPlanningPackageMutationsShareInventoryFirstLockOrder()
            throws Exception {
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");
        String plans = source("features/production/plan/ProductionPlanService.java");
        String confirm = source(
                "features/production/mrp/ProductionExecutionPackageCommandService.java");
        String lifecycle = source(
                "features/production/mrp/ProductionPlanningPackageService.java");

        assertThat(commands).contains("lockAnalysisInventoryDimensions(analysisId);");
        assertThat(commands).contains("FROM stock_reservations reservation");
        assertThat(commands).contains("reservation.owner_type = 'PREPLAN_ANALYSIS'");
        assertThat(commands).contains("reservation.status = 0");
        int approveStart = plans.indexOf("public PlanDetail approve(UUID id)");
        int prelock = plans.indexOf("lockSourceAnalysisInventoryDimensions(id);", approveStart);
        int planRowLock = plans.indexOf("requirePlanForUpdate(id);", approveStart);
        assertThat(prelock).isGreaterThan(approveStart).isLessThan(planRowLock);

        int confirmStart = confirm.indexOf("public PlanningPackageResult confirm(");
        int confirmInventory = confirm.indexOf(
                "lockPlanningPackageInventoryDimensions(planId);", confirmStart);
        int confirmPlan = confirm.indexOf("lockPlan(planId);", confirmStart);
        assertThat(confirmInventory).isGreaterThan(confirmStart).isLessThan(confirmPlan);

        int lifecycleStart = lifecycle.indexOf(
                "private PlanningPackageLifecycleResult lifecycle(");
        int lifecycleInventory = lifecycle.indexOf(
                "lockPlanningPackageInventoryDimensions(planId);", lifecycleStart);
        int lifecyclePlan = lifecycle.indexOf("lockPlan(planId);", lifecycleStart);
        int reversible = lifecycle.indexOf(
                "requirePlanningPackageLifecycleReversible(planId);", lifecycleStart);
        int documents = lifecycle.indexOf("ledger.lockPackageDocuments(packageId);", lifecycleStart);
        assertThat(lifecycleInventory)
                .isGreaterThan(lifecycleStart).isLessThan(lifecyclePlan);
        assertThat(reversible).isGreaterThan(lifecyclePlan).isLessThan(documents);
        assertThat(plans).contains("FROM stock_reservations reservation");
    }

    @Test
    void preplanEntitlementsMoveOnlyForReadyDemandsAndBindFormalReservations()
            throws Exception {
        String command = source(
                "features/production/mrp/ProductionExecutionPackageCommandService.java");

        assertThat(command).contains("Set<UUID> readySegmentIds");
        assertThat(command).contains("List<ProductionMaterialDemand> readyDemands");
        assertThat(command).contains("readySegmentIds.contains(");
        assertThat(command).contains("preplanAnalysisPeg.transferToPlanDemands(");
        assertThat(command).contains("demand.getId(),");
        assertThat(command).contains("formalizePlanDemandTransfers(");
        assertThat(command).contains("readyAllocation.formalReservations()");
        assertThat(command.indexOf("transferToPlanDemands("))
                .isLessThan(command.indexOf("allocateReady("));
        assertThat(command.indexOf("allocateReady("))
                .isLessThan(command.indexOf("formalizePlanDemandTransfers("));
    }

    @Test
    void externalSupplyDocumentsPublishTheirNoticeOnlyAfterTheActionLinkExists()
            throws Exception {
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        String notifyCall =
                "chainNotice.notifyPreplanSupplyActionCreated(action.actionId());";

        int purchaseMark = commands.indexOf(
                "markCreated(action.actionId(), \"PURCHASE_REQUEST\"");
        int purchaseNotice = commands.indexOf(notifyCall, purchaseMark);
        int subcontractMark = commands.indexOf(
                "markCreated(action.actionId(), \"SUBCONTRACT_APPLICATION\"");
        int subcontractNotice = commands.indexOf(
                notifyCall, purchaseNotice + notifyCall.length());

        assertThat(purchaseMark).isGreaterThanOrEqualTo(0);
        assertThat(purchaseNotice).isGreaterThan(purchaseMark);
        assertThat(subcontractMark).isGreaterThan(purchaseNotice);
        assertThat(subcontractNotice).isGreaterThan(subcontractMark);
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
