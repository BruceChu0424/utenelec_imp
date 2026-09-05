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
        assertThat(source).contains("inspection.warehouse_stocked_base_qty");
        assertThat(source).contains("'PARTIAL','RESOLVED'");
        assertThat(source).doesNotContain("THEN inspection.passed_base_qty");
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
        assertThat(commands).contains("map(MaterialView::demandSupplyGapQty)");
        assertThat(commands).contains("analysisService.refreshLocked(analysisId)");
    }

    @Test
    void rootSchedulingEligibilityIsSeparateFromMaterialReadiness() throws Exception {
        String contracts = source(
                "features/production/analysis/MaterialAnalysisContracts.java");
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(contracts)
                .contains("boolean canSchedule")
                .contains("BigDecimal maxSchedulableQty")
                .contains("String scheduleBlockedReason");
        assertThat(service)
                .contains("MATERIAL-ANALYSIS-PLAN-PREVIEW-V3")
                .contains("canGenerate ? \"READY\" : \"WAITING\"")
                .contains("product.maxSchedulableQty()");
        assertThat(commands)
                .contains("preview.items().stream().anyMatch(item -> !item.canSchedule())")
                // V474 分批口径：混合「齐套 READY + 剩余 WAITING」按批次各归其位，
                // 不再强制整单 WAITING（旧 ANALYSIS-WAITING 前缀随全量压扁口径退役）。
                .contains("if (!Set.of(\"READY\", \"WAITING\").contains(requestedStatus))")
                .contains("把混合结果重新压成一个全量 WAITING 会吞掉可立即生产的批次")
                .contains("segment.setRequestedStatus(requestedStatus)")
                .contains("segment.setDeferUntilManualRelease(false)")
                .doesNotContain("if (!preview.allReady()");
    }

    @Test
    void lowerLevelShortageIsDiagnosticAndChildCreationRemainsExplicit() throws Exception {
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(commands)
                .doesNotContain("lines.stream().anyMatch(MaterialView::lowerLevelPending)")
                .contains("lowerLevelPending remains a diagnostic")
                .contains("createsChildOwnership")
                .contains("子件任务当前必须按全部剩余需求");

        // The diagnostic still covers child-bearing SUBCONTRACT so UI can
        // explain that approval will be WAITING rather than falsely READY.
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        assertThat(service).contains("SUBCONTRACT\".equals(effectiveRoute)");
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
    void subcontractMakeNotificationAlsoDelegatesExactEntitlements()
            throws Exception {
        // 2026-09-04 事故：有子层委外件下达后建 SUBCONTRACT_MAKE 任务行接管子树需求，
        // 但权益迁移只在 MAKE 路线执行——ORIGIN_MAKE/IQC 预留被钉死在需求已归零的
        // 旧父树节点（planExactPegs 按毛需求 secured/earmark 共享池），委外子树
        // 库存明明齐套却永远「还缺 X 种物料」。修复=迁移查询与 notify 循环同时
        // 覆盖 SUBCONTRACT；无子层委外申请无子任务行，查询自然无匹配。
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        assertThat(commands).contains(
                "!\"SUBCONTRACT\".equals(action.group().route())");
        String entitlements = source(
                "features/production/analysis/PreplanStockEntitlementService.java");
        assertThat(entitlements).contains(
                "('SUBCONTRACT', 'SUBCONTRACT_MAKE', 'SUBCONTRACT_MAKE_TASK')");
        assertThat(entitlements).contains(
                "parent_material.confirmed_route = action.route");
        // V467 事故复盘：Java 侧放开双路线后，V337 头触发器仍写死 MAKE 形状，
        // 真库 INSERT 被 23514 拒绝（源码断言测不到 DB 触发器，行为锁定在
        // SubcontractMakeDelegationRouteGuardPostgresTest）。此处锁迁移文件
        // 必须与 Java 配对口径一致，防止再出现「代码改了、守卫没跟」。
        String guard = migrationSource(
                "V467__subcontract_make_delegation_guard_route.sql");
        assertThat(guard).contains("WHEN 'SUBCONTRACT' THEN 'SUBCONTRACT_MAKE_TASK'");
        assertThat(guard).contains("WHEN 'SUBCONTRACT' THEN 'SUBCONTRACT_MAKE'");
        assertThat(guard).contains(
                "parent_material.confirmed_route IS DISTINCT FROM action.route");
        assertThat(guard).doesNotContain(
                "confirmed_route IS DISTINCT FROM 'MAKE'");
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

        // 协议：需求 exact 数量与固定公共安全补库确认量分开提交。
        assertThat(contracts).contains("record SupplyQuantityInput(");
        assertThat(contracts).contains("List<@Valid SupplyQuantityInput> quantities");
        assertThat(contracts).contains("BigDecimal safetyReplenishmentQty");
        // 服务端按操作组解析并以实时未绑定需求复核；安全量必须 echo 最新快照。
        assertThat(commands).contains("quantityInputs(view, request, groups)");
        assertThat(commands).contains("quantityInputs.get(group.groupKey())");
        assertThat(commands).contains("requested.compareTo(delta) > 0");
        assertThat(commands).contains("真实未绑定需求扣除在途后的余量");
        assertThat(commands).contains("公共安全库存补库已变化");
        // demand allocation 只用复核后的 exact 数量；安全量写独立采购明细。
        assertThat(commands).contains(
                "allocateAction(actionId, analysisId, group.materials(), plan.demandQty())");
        // 幂等哈希必须覆盖数量，防止同键不同量误重放。
        assertThat(commands).contains("\"QTY|\"");
        assertThat(commands).contains("\"|SAFETY|\"");
    }

    @Test
    void childOwnershipNotifyRequiresFullResidualUntilDelegatedQuantityExists()
            throws Exception {
        String contracts = source("features/production/analysis/MaterialAnalysisContracts.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(contracts).contains(
                "MAKE 在显式 delegated_qty 落地前必须等于全部实时余量");
        assertThat(commands).contains("boolean createsChildOwnership");
        assertThat(commands).contains("hasActiveBomChildren");
        assertThat(commands).contains(
                "createsChildOwnership && requested.compareTo(delta) != 0");
        assertThat(commands).contains("子件任务当前必须按全部剩余需求");
        assertThat(commands).contains("本批生产数量请在子件任务创建后的计划向导中填写");
    }

    @Test
    void materialViewExposesExactRequirementStateAndMakeChildOwner() throws Exception {
        String contracts = source("features/production/analysis/MaterialAnalysisContracts.java");
        String service = source("features/production/analysis/MaterialAnalysisService.java");

        assertThat(contracts).contains("String requirementState");
        assertThat(contracts).contains("UUID delegatedToAnalysisLineId");
        assertThat(contracts).contains("String delegatedToSourceRef");
        assertThat(contracts).contains("BigDecimal delegatedToRequestedQty");
        assertThat(contracts).contains(
                "REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD");
        assertThat(contracts).contains("REQUIREMENT_STATE_INACTIVE_PARENT_COVERED");
        assertThat(contracts).contains("REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE");
        assertThat(contracts).contains("REQUIREMENT_STATE_INACTIVE_REFERENCE");
        assertThat(contracts).contains("REQUIREMENT_STATE_TRANSFERRED_TO_PLAN");

        // Owner identity is the persisted MAKE_COMPONENT parent relation plus
        // the exact analysis-item/node-key ancestry; goods identity is display
        // context only and is never the ownership join.
        assertThat(service).contains("parent_material.id = child.parent_analysis_material_id");
        assertThat(service).contains(
                "child.id, child.source_ref, child.requested_qty");
        assertThat(service).contains("SELECT m.id, m.analysis_item_id, m.node_key");
        assertThat(service).contains(
                "cursor.analysisItemId(), cursor.parentNodeKey()");
        assertThat(service).contains("row.requiredQty().signum() > 0");
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

        // ADR-065 修订（2026-09-03）：通知按单据聚合——每张申请只提醒一次，
        // 且必须在逐 action 的 createExternalDocument 循环完成之后发布
        // （投递时单据链接已存在）。逐 action 通知已从命令侧下线。
        int createLoop = commands.indexOf(
                "createExternalDocument(analysisId, action, prepared)");
        int purchaseNotice = commands.indexOf(
                "chainNotice.notifyPreplanSupplyDocumentCreated(", createLoop);
        int subcontractNotice = commands.indexOf(
                "chainNotice.notifyPreplanSupplyDocumentCreated(", purchaseNotice + 1);

        assertThat(createLoop).isGreaterThanOrEqualTo(0);
        assertThat(purchaseNotice).isGreaterThan(createLoop);
        assertThat(subcontractNotice).isGreaterThan(purchaseNotice);
        assertThat(commands).doesNotContain(
                "chainNotice.notifyPreplanSupplyActionCreated(");
    }

    @Test
    void bulkNotifyMergesOneRequestPerRouteAndSharedDocumentCancelIsBatched()
            throws Exception {
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        String purchaseFacade = source(
                "features/purchase/request/ProductionPurchaseRequestFacade.java");
        String subcontractFacade = source(
                "features/subcontract/application/ProductionSubcontractRequestFacade.java");

        // ADR-065：一次通知先整批聚合（全部 BUY 一张采购申请 / 全部无子层委外一张
        // 委外申请，表头日期取最早），再逐 action 挂接明细锚点。
        assertThat(commands).contains("prepareExternalDocuments(analysisId, created)");
        assertThat(commands).contains(
                "createExternalDocument(analysisId, action, prepared)");
        assertThat(commands).contains("earliest(purchaseNeedDate, needDate)");
        assertThat(commands).contains("earliest(subcontractNeedDate, needDate)");
        assertThat(commands).contains("purchaseNeedDate, warehouseId,");
        assertThat(commands).contains("subcontractNeedDate, warehouseId,");
        // 有子层委外仍走 V458 前置自制，聚合前先按活动 BOM 分类。
        assertThat(commands).contains("prepared.subcontractLeafActionIds()");
        // 共享单据撤回：整批一并撤回，单据只红冲一次（Facade REVERSE 幂等）。
        assertThat(commands).contains(
                "sharedDocumentActionIds(analysisId, documentId)");
        assertThat(purchaseFacade).contains(
                "action == LifecycleAction.REVERSE && request.getStatus() == STATUS_REVERSED");
        assertThat(subcontractFacade).contains(
                "application.getStatus() == STATUS_REVERSED");
    }

    @Test
    void publicExtraNeverInflatesExactDemandAllocation() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(source)
                .contains("if (requested.compareTo(delta) > 0) {")
                .contains("publicExtraQty")
                .contains("production_material_analysis:over_supply")
                .contains("主动公共备货(不绑定来源物料分析)")
                .contains("plan.demandQty(), plan.publicExtraQty()")
                .contains("allocateAction(actionId, analysisId, group.materials(), plan.demandQty())")
                .contains("'SHARED_FUTURE_CLAIM', :sourceActionId");
        assertThat(source).doesNotContain(
                "allocateAction(actionId, analysisId, group.materials(), plan.publicExtraQty())");
    }

    @Test
    void routeLearningPrefetchReadsLatestConfirmedRoutePerGoodsDimension() throws Exception {
        // 2026-09-04 路线学习预填：按货品+颜色+单位维度取最近一张未删分析里
        // confirmed_route 的记忆；只读、跨分析共享。
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        assertThat(service).contains("lastRoutesPerGoods");
        assertThat(service).contains("DISTINCT ON (m.goods_id, m.color_id, m.unit_id)");
        assertThat(service).contains("m.confirmed_route IS NOT NULL");
        assertThat(service).contains("m.active = TRUE");
        String controller = source("features/production/analysis/MaterialAnalysisController.java");
        assertThat(controller).contains("\"/last-routes\"");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }

    private static String migrationSource(String fileName) throws Exception {
        return Files.readString(
                Path.of("src/main/resources/db/migration").resolve(fileName),
                StandardCharsets.UTF_8);
    }
}
