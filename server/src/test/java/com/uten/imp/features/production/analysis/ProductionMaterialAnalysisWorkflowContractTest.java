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
    void issueHashAndFormalPreviewIncludeAllAuthoritativeInputs() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisCommandService.java");

        assertThat(source).contains("itemBillDate(quantity, defaults)");
        assertThat(source).contains("quantity.teamDepartmentId()");
        assertThat(source).contains("Objects.toString(line.workshopName(), \"\")");
        assertThat(source).contains("expectedQty.compareTo(proposedQty) != 0");
        // ADR-071：齐套结论只决定 READY/WAITING 两种合法状态，未知状态即冲突
        // 回滚（旧的全量拦截 !"READY" 已退役，缺料批次进 WAITING 由车间侧提升）。
        assertThat(source).contains("Set.of(\"READY\", \"WAITING\").contains(requestedStatus)");
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
        assertThat(source).contains("samePlanningWarehouseScope(");
        assertThat(source).contains("SELECT id, fn_warehouse_main_id(id) AS main_id");
        assertThat(source).contains("Objects.equals(mains.get(first), mains.get(second))");
        assertThat(source).contains("decimal(existing[6]).compareTo(item.requestedQty()) != 0");
        assertThat(source).contains("Objects.equals(date(existing[7]), expectedDelivery)");
        int exactMatch = source.indexOf("requireReusablePayloadMatches(",
                source.indexOf("analysisId = findReusableAnalysis(normalized)"));
        int commandWrite = source.indexOf("recordSimpleCommand(analysisId, \"PREVIEW\"", exactMatch);
        assertThat(exactMatch).isGreaterThanOrEqualTo(0);
        assertThat(commandWrite).isGreaterThan(exactMatch);
    }

    @Test
    void committedSourceIncreasePreservesCommitmentsAndRequiresCurrentAdmittedCapacity() throws Exception {
        String source = source("features/production/analysis/MaterialAnalysisService.java");

        assertThat(source).contains("BigDecimal committed = decimal(row[7]).add(decimal(row[8]))");
        assertThat(source).contains("requested.requestedQty().compareTo(decimal(row[9])) > 0");
        assertThat(source).contains("if (!sameWarehouseScope)");
        assertThat(source).contains("requireCurrentBomSnapshot(analysisId, committedIncreases)");
        assertThat(source).contains("requested.subtract(source.requestedQty()).compareTo(additionalCapacity) > 0");
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
    void issuePlansConsumesOnlyPersistedDirectLayerAllocation() throws Exception {
        String service = source("features/production/analysis/MaterialAnalysisService.java");
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");

        // ADR-071：READY/WAITING 由权威齐套结论决定，但不再拦截下达。
        assertThat(service).contains("authoritativeReadyQty(");
        assertThat(service).contains("canGenerateReadyBatch(");
        // 2026-09-06 锚点模型二简：issue-plans 单事务——候选路线以服务端已确认
        // 路线为准（只建锚点行，不搬权益），计划侧不做齐套判断，缺料批次由
        // 车间侧 WAITING→READY 自动提升。
        assertThat(commands).contains("candidateRoutesByMaterialLine(preArrange)");
        assertThat(commands).contains("只有自制路线的物料才能直接下达车间");
        assertThat(commands).contains("无自制子层的委外件请走委外下达，不能直接建生产计划");
        assertThat(commands).contains(
                "material.actionable() || \"ROOT_SUPPLY\".equals(material.nodeRole())");
        assertThat(commands).contains("rootSupply.fulfillExisting(analysisId");
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
                // 2026-09-05 顶层与子层同构：V478 根节点存在但路线未确认（NULL）
                // 时不可排产——顶层必须像子件一样显式确认为自制才能下达车间；
                // 无根节点的旧分析（rootMaterialLineId 为 null）沿用旧合同。
                .contains("boolean rootRoutePending = rootMaterialLineId != null && rootRoute == null")
                .contains("根产品供料路线未确认，请先确认为自制再下达车间");
        assertThat(commands)
                // V474 分批口径：混合「齐套 READY + 剩余 WAITING」按批次各归其位，
                // 不再强制整单 WAITING（旧 ANALYSIS-WAITING 前缀随全量压扁口径退役）。
                .contains("if (!Set.of(\"READY\", \"WAITING\").contains(requestedStatus))")
                .contains("把混合结果重新压成一个全量 WAITING 会吞掉可立即生产的批次")
                .contains("segment.setRequestedStatus(requestedStatus)")
                .contains("segment.setDeferUntilManualRelease(false)")
                // ADR-71：下达车间不再走联合预览，齐套结论不拦截（缺料=WAITING）。
                .doesNotContain("previewFingerprint")
                .doesNotContain("计划预览发现不可排产");
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
    void notificationNeverDelegatesEntitlementsAndRefreshRestoresLegacyOnes()
            throws Exception {
        // 2026-09-05 简化：子件只做计划锚点——notify 不再迁移 exact 权益，
        // 分析刷新入口先把旧模式遗留的委托整体归还（单份数据口径）。
        String commands = source(
                "features/production/analysis/MaterialAnalysisCommandService.java");
        assertThat(commands)
                .doesNotContain("stockEntitlement.delegateMakeEntitlements")
                .contains("analysisService.refreshLocked(analysisId)");
        String service = source(
                "features/production/analysis/MaterialAnalysisService.java");
        assertThat(service).contains(
                "stockEntitlement.restoreAllMakeDelegations(analysisId)");
        String entitlements = source(
                "features/production/analysis/PreplanStockEntitlementService.java");
        assertThat(entitlements).contains(
                "public void restoreAllMakeDelegations(UUID analysisId)");
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
        assertThat(commands).contains("activeBomParentIds");
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
    void analysisAndPlanningPackageMutationsShareCommercialInventoryAnalysisPrefix()
            throws Exception {
        String commands = source("features/production/analysis/MaterialAnalysisCommandService.java");
        String plans = source("features/production/plan/ProductionPlanService.java");
        String confirm = source(
                "features/production/mrp/ProductionExecutionPackageCommandService.java");
        String lifecycle = source(
                "features/production/mrp/ProductionPlanningPackageService.java");
        String analysisFootprint=source("features/production/analysis/ProductionMutationFootprintService.java");
        String planFootprint=source("features/production/plan/ProductionPlanMutationFootprintService.java");

        assertThat(commands).contains("lockAnalysisInventoryDimensions(analysisId);");
        assertThat(commands).contains("mutationLocks.acquire(() -> mutationFootprints.forAnalyses(List.of(analysisId)))");
        assertThat(analysisFootprint).contains("FROM stock_reservations reservation");
        assertThat(analysisFootprint.replaceAll("\\s+", "")).contains("reservation.owner_type='PREPLAN_ANALYSIS'", "reservation.status=0");
        assertThat(plans).contains("mutationFootprint.lockPlan(id, requested);");
        assertThat(planFootprint.indexOf("locks.acquire(() -> discoverPlans(ids,lines))"))
                .isGreaterThan(0).isLessThan(planFootprint.indexOf("SELECT id FROM production_plans WHERE id IN (:ids) ORDER BY id FOR UPDATE"));
        assertThat(planFootprint).contains("production.forAnalyses(analyses)");

        int confirmStart = confirm.indexOf("public PlanningPackageResult confirm(");
        int confirmInventory = confirm.indexOf(
                "mutationFootprint.beginPlan(planId, List.of());", confirmStart);
        int confirmPlan = confirm.indexOf("lockPlan(planId);", confirmStart);
        assertThat(confirmInventory).isGreaterThan(confirmStart).isLessThan(confirmPlan);

        int lifecycleStart = lifecycle.indexOf(
                "private PlanningPackageLifecycleResult lifecycle(");
        int lifecycleInventory = lifecycle.indexOf(
                "mutationFootprint.beginPlan(planId, List.of());", lifecycleStart);
        int lifecyclePlan = lifecycle.indexOf("lockPlan(planId);", lifecycleStart);
        int reversible = lifecycle.indexOf(
                "requirePlanningPackageLifecycleReversible(planId);", lifecycleStart);
        int documents = lifecycle.indexOf("ledger.lockPackageDocuments(packageId);", lifecycleStart);
        assertThat(lifecycleInventory)
                .isGreaterThan(lifecycleStart).isLessThan(lifecyclePlan);
        assertThat(reversible).isGreaterThan(lifecyclePlan).isLessThan(documents);
        assertThat(planFootprint).contains("FROM stock_reservations reservation", "release_reason='TRANSFERRED_TO_PLAN'");
        assertThat(confirm).contains("if (!sameKeyExists) sourceGuard.verifyUnchanged();");
        assertThat(lifecycle.indexOf("sourceGuard.verifyUnchanged();", lifecycleStart))
                .isGreaterThan(lifecycle.indexOf("if (handle.replayed())", lifecycleStart)).isLessThan(reversible);
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
        assertThat(commands).contains("prepareExternalDocuments(analysisId, created, subcontractBomParents)");
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
        int queryStart=service.indexOf("WITH history AS (",service.indexOf("lastRoutesPerGoods("));
        int queryEnd=service.indexOf("\"\"\""+");",queryStart);
        assertThat(queryStart).isGreaterThanOrEqualTo(0);
        assertThat(queryEnd).isGreaterThan(queryStart);
        String memoryQuery=service.substring(queryStart,queryEnd);
        assertThat(memoryQuery)
                .contains("DENSE_RANK() OVER")
                .contains("PARTITION BY m.goods_id,m.color_id,m.unit_id")
                .contains("COALESCE(m.route_confirmed_at,m.created_at) DESC")
                .contains("m.confirmed_route IS NOT NULL")
                .contains("a.is_deleted=FALSE")
                .contains("a.status<>'CANCELLED'")
                .contains("WHERE recency=1")
                .contains("HAVING COUNT(DISTINCT confirmed_route)=1")
                .doesNotContain("m.active");
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
