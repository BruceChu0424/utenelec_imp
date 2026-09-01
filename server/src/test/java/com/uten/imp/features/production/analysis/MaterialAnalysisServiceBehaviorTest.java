package com.uten.imp.features.production.analysis;

import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MaterialAnalysisServiceBehaviorTest {

    @Test
    void subcontractHandoffFutureCapacityPreventsDuplicateSupplyWithoutFakingStock() {
        assertThat(MaterialAnalysisService.unboundDemandSupplyGap(
                bd("10"), BigDecimal.ZERO, BigDecimal.ZERO, bd("6")))
                .isEqualByComparingTo("4.0000");
        assertThat(MaterialAnalysisService.unboundDemandSupplyGap(
                bd("10"), bd("2"), bd("4"), bd("6")))
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void manualSourceRequiresAStableReference() {
        MaterialAnalysisService service = service(mock(EntityManager.class),
                mock(ProductionDocumentAccessPolicy.class));
        PreviewItem missingReference = manualItem("   ");

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                service, "normalizePreviewItems",
                new Class<?>[]{List.class, boolean.class, UUID.class},
                List.of(missingReference), false, null));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void manualReferenceReopensTheSameActiveAnalysisIgnoringCase() {
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        MaterialAnalysisService service = service(em, access);
        UUID analysisId = UUID.randomUUID();
        PreviewItem requested = manualItem("req-2026-001");

        Query matches = query(Collections.singletonList(
                new Object[]{analysisId, MaterialAnalysisService.STATUS_ACTIVE}));
        Query identities = query(Collections.singletonList(new Object[]{
                requested.sourceType(), null, requested.goodsId(), requested.colorId(),
                requested.unitId(), "  REQ-2026-001  "}));
        when(em.createNativeQuery(anyString())).thenReturn(matches, identities);

        UUID reused = invokePrivate(service, "findReusableAnalysis",
                new Class<?>[]{List.class}, List.of(requested));

        assertThat(reused).isEqualTo(analysisId);
        verify(matches).setParameter("sourceRef", "req-2026-001");
    }

    @Test
    void completedManualReferenceMustBeOpenedFromHistoryInsteadOfDuplicated() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        Query matches = query(Collections.singletonList(
                new Object[]{UUID.randomUUID(), "COMPLETED"}));
        when(em.createNativeQuery(anyString())).thenReturn(matches);

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                service, "findReusableAnalysis", new Class<?>[]{List.class},
                List.of(manualItem("REQ-HISTORY-001"))));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void historyListAppliesOwnerScopeCapsPagingAndReturnsRecoveryFields() {
        EntityManager em = mock(EntityManager.class);
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        MaterialAnalysisService service = service(em, access);
        UUID ownerId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        OffsetDateTime analyzedAt = OffsetDateTime.of(
                2026, 8, 8, 8, 0, 0, 0, ZoneOffset.UTC);
        OffsetDateTime updatedAt = analyzedAt.plusHours(2);
        OwnerVisibility.OwnerScope scope = new OwnerVisibility.OwnerScope(
                false, Set.of(ownerId));
        DocumentAccessPolicy.NativeReadScope nativeScope =
                new DocumentAccessPolicy.NativeReadScope(
                        "analysis.maker_id IN (:analysisOwners)",
                        "analysisOwners", Set.of(ownerId));
        when(access.scope()).thenReturn(scope);
        when(access.nativeReadScope("analysis.maker_id", "analysisOwners", scope))
                .thenReturn(nativeScope);

        Query count = queryWithSingleResult(2L);
        Object[] row = new Object[]{
                analysisId, "ACTIVE", 7L, "a".repeat(64), warehouseId,
                "W-01", "Main warehouse", analyzedAt, updatedAt, ownerId, "Owner",
                1, "SALES_ORDER_ITEM", "SO-2026-001", "FG-01 Finished good",
                bd("100"), bd("10"), bd("20"), bd("70"), bd("10"), bd("15")
        };
        Query data = query(Collections.singletonList(row));
        List<String> sql = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            sql.add(statement);
            return statement.startsWith("SELECT COUNT(*)") ? count : data;
        });

        var page = service.list(
                " so-2026 ", " active ", " sales_order_item ", 99, 1000);

        assertThat(page.getPage()).isEqualTo(1);
        assertThat(page.getSize()).isEqualTo(100);
        assertThat(page.getTotal()).isEqualTo(2);
        assertThat(page.getItems()).singleElement().satisfies(item -> {
            assertThat(item.analysisId()).isEqualTo(analysisId);
            assertThat(item.updatedAt()).isEqualTo(updatedAt);
            assertThat(item.sourceRefs()).containsExactly("SO-2026-001");
            assertThat(item.remainingQty()).isEqualByComparingTo("70");
        });
        verify(count).setParameter("analysisOwners", Set.of(ownerId));
        verify(data).setParameter("analysisOwners", Set.of(ownerId));
        assertThat(sql).anySatisfy(statement ->
                assertThat(statement).contains(
                        "NULLIF(btrim(source.source_ref),''), sales_order.bill_no"));
    }

    @Test
    void changedDirectBomSignatureBlocksFormalPlanning() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        UUID analysisId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        UUID productId = UUID.randomUUID();
        UUID componentId = UUID.randomUUID();
        UUID productUnitId = UUID.randomUUID();
        UUID componentUnitId = UUID.randomUUID();
        UUID bomItemId = UUID.randomUUID();

        Query sources = query(Collections.singletonList(sourceRow(
                itemId, productId, productUnitId)));
        Query graphValidation = query(Collections.singletonList(
                new Object[]{false, false, false}));
        Query currentBom = query(Collections.singletonList(new Object[]{
                bomItemId, productId, componentId, null, componentUnitId, 1,
                bomItemId.toString(), null, BigDecimal.ONE, bd("2"), bd("2"),
                "C-01", "Component", null, null, "piece", BigDecimal.ZERO,
                "\u91c7\u8d2d", false, "START", "PER_UNIT", BigDecimal.ONE,
                true, true
        }));
        Query staleSnapshot = query(Collections.singletonList(new Object[]{
                bomItemId, componentId, null, componentUnitId,
                BigDecimal.ONE, bd("3"), bd("3"), "START", "PER_UNIT",
                BigDecimal.ONE, true, true, "BUY", "EDGE_RULE"
        }));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String statement = invocation.getArgument(0);
            if (statement.contains("FROM production_material_analysis_items ai")) {
                return sources;
            }
            if (statement.contains("WITH RECURSIVE walk AS")) {
                return graphValidation;
            }
            if (statement.contains("WITH RECURSIVE exp AS")) {
                return currentBom;
            }
            if (statement.contains("FROM production_material_analysis_materials")) {
                return staleSnapshot;
            }
            throw new AssertionError("unexpected SQL: " + statement);
        });

        ApiException error = assertThrows(ApiException.class,
                () -> service.requireCurrentBomSnapshot(analysisId, Set.of(itemId)));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void notifyStillRejectsAnUnconfirmedActionableRoute() {
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        UUID materialId = UUID.randomUUID();
        MaterialView material = material(materialId, false, null);
        AnalysisView view = new AnalysisView(
                UUID.randomUUID(), "ACTIVE", 1L, "a".repeat(64), "b".repeat(64),
                UUID.randomUUID(), OffsetDateTime.now(), List.of(), List.of(material),
                List.of(), List.of(), List.of(), false, null);
        NotifyRequest request = new NotifyRequest(
                1L, "a".repeat(64), "notify-0001", null,
                List.of(materialId), List.of(), null);

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                commands, "selectedGroups",
                new Class<?>[]{AnalysisView.class, NotifyRequest.class}, view, request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void notifyAllowsFiveHundredDistinctGroupsAfterMixedSelectorsAreDeduplicated() {
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        List<MaterialView> materials = new ArrayList<>();
        List<UUID> materialLineIds = new ArrayList<>();
        List<String> actionGroupKeys = new ArrayList<>();
        for (int index = 0; index < RequestLimits.DOCUMENT_LINES; index++) {
            UUID materialLineId = UUID.randomUUID();
            String groupKey = "group-" + index;
            materials.add(material(materialLineId, groupKey, true, "BUY"));
            materialLineIds.add(materialLineId);
            actionGroupKeys.add(groupKey);
        }
        AnalysisView view = new AnalysisView(
                UUID.randomUUID(), "ACTIVE", 1L, "a".repeat(64), "b".repeat(64),
                UUID.randomUUID(), OffsetDateTime.now(), List.of(), materials,
                List.of(), List.of(), List.of(), false, null);
        NotifyRequest request = new NotifyRequest(
                1L, "a".repeat(64), "notify-limit-500", "BUY",
                materialLineIds, actionGroupKeys, null);

        List<?> groups = invokePrivate(
                commands, "selectedGroups",
                new Class<?>[]{AnalysisView.class, NotifyRequest.class}, view, request);

        assertThat(groups).hasSize(RequestLimits.DOCUMENT_LINES);
    }

    @Test
    void notifyRejectsFiveHundredOneDistinctGroupsAcrossMixedSelectors() {
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        List<MaterialView> materials = new ArrayList<>();
        List<UUID> materialLineIds = new ArrayList<>();
        List<String> actionGroupKeys = new ArrayList<>();
        for (int index = 0; index <= RequestLimits.DOCUMENT_LINES; index++) {
            UUID materialLineId = UUID.randomUUID();
            String groupKey = "group-" + index;
            materials.add(material(materialLineId, groupKey, true, "BUY"));
            if (index < 300) {
                actionGroupKeys.add(groupKey);
            }
            if (index >= 299) {
                materialLineIds.add(materialLineId);
            }
        }
        AnalysisView view = new AnalysisView(
                UUID.randomUUID(), "ACTIVE", 1L, "a".repeat(64), "b".repeat(64),
                UUID.randomUUID(), OffsetDateTime.now(), List.of(), materials,
                List.of(), List.of(), List.of(), false, null);
        NotifyRequest request = new NotifyRequest(
                1L, "a".repeat(64), "notify-limit-501", "BUY",
                materialLineIds, actionGroupKeys, null);

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                commands, "selectedGroups",
                new Class<?>[]{AnalysisView.class, NotifyRequest.class}, view, request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(error.getMessage())
                .contains(Integer.toString(RequestLimits.DOCUMENT_LINES))
                .contains("去重后")
                .contains("分批");
    }

    @Test
    void eachPlanSheetOverridesTheGlobalScheduleAndRejectsAnInvertedDateRange() {
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        UUID analysisLineId = UUID.randomUUID();
        UUID workshopDepartmentId = UUID.randomUUID();
        UUID teamDepartmentId = UUID.randomUUID();
        UUID workerId = UUID.randomUUID();
        PlanQuantity item = new PlanQuantity(
                analysisLineId, bd("25"), LocalDate.of(2026, 8, 12),
                LocalDate.of(2026, 8, 11), workshopDepartmentId,
                "二车间", workerId, teamDepartmentId);
        GeneratePlanRequest request = new GeneratePlanRequest(
                3L, "a".repeat(64), "b".repeat(64), "plan-sheet-0001",
                UUID.randomUUID(), LocalDate.of(2026, 8, 9),
                LocalDate.of(2026, 8, 20), UUID.randomUUID(),
                "默认车间", UUID.randomUUID(), false,
                List.of(item), List.of());

        assertThat((LocalDate) invokePrivate(
                commands, "itemBillDate",
                new Class<?>[]{PlanQuantity.class, GeneratePlanRequest.class},
                item, request)).isEqualTo(LocalDate.of(2026, 8, 12));
        assertThat((UUID) invokePrivate(
                commands, "itemDepartmentId",
                new Class<?>[]{PlanQuantity.class, GeneratePlanRequest.class},
                item, request)).isEqualTo(workshopDepartmentId);
        assertThat((UUID) invokePrivate(
                commands, "itemWorkerId",
                new Class<?>[]{PlanQuantity.class, GeneratePlanRequest.class},
                item, request)).isEqualTo(workerId);

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                commands, "validatePlanSchedule",
                new Class<?>[]{PlanQuantity.class, GeneratePlanRequest.class},
                item, request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    @Test
    void explicitProductNumberParticipatesInGenerateIdempotencyHash() {
        UUID analysisId = UUID.randomUUID();
        UUID analysisLineId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();

        String automatic = generateHash(analysisId,
                generateRequest(analysisLineId, warehouseId, null));
        String blank = generateHash(analysisId,
                generateRequest(analysisLineId, warehouseId, "   "));
        String explicit = generateHash(analysisId,
                generateRequest(analysisLineId, warehouseId, "V6-0001"));
        String padded = generateHash(analysisId,
                generateRequest(analysisLineId, warehouseId, "  V6-0001  "));
        String changed = generateHash(analysisId,
                generateRequest(analysisLineId, warehouseId, "V6-0002"));

        assertThat(blank).isEqualTo(automatic);
        assertThat(padded).isEqualTo(explicit);
        assertThat(changed).isNotEqualTo(explicit);
    }

    @Test
    void completeKitPassKeepsScarceStockWithTheLineItDeclaredReady() {
        UUID unitId = UUID.randomUUID();
        UUID materialX = UUID.randomUUID();
        UUID materialY = UUID.randomUUID();
        UUID highPriorityId = UUID.randomUUID();
        UUID lowPriorityId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine highPriority = allocationSource(
                highPriorityId, UUID.randomUUID(), unitId, 0, "6");
        MaterialAnalysisService.SourceLine lowPriority = allocationSource(
                lowPriorityId, UUID.randomUUID(), unitId, 1, "6");
        MaterialAnalysisService.BomNode highX = bomNode(
                highPriorityId, materialX, unitId, "high-x", "6",
                "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode highY = bomNode(
                highPriorityId, materialY, unitId, "high-y", "6",
                "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode lowX = bomNode(
                lowPriorityId, materialX, unitId, "low-x", "6",
                "START", "PER_UNIT", "1", "1", true);
        Map<UUID, List<MaterialAnalysisService.BomNode>> nodes = Map.of(
                highPriorityId, List.of(highX, highY),
                lowPriorityId, List.of(lowX));
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> stock = Map.of(
                highX.dimension(), bd("6"), highY.dimension(), BigDecimal.ZERO);

        MaterialAnalysisService.StageAllocation completeKits =
                MaterialAnalysisService.allocateStageReadiness(
                        List.of(highPriority, lowPriority), nodes, stock,
                        Set.of("START", "ASSEMBLY", "FINISH"));
        Map<String, MaterialAnalysisService.NodeAllocation> rows =
                MaterialAnalysisService.allocateDirectMaterials(
                        List.of(highPriority, lowPriority), nodes,
                        completeKits.remainingPool(), completeKits.nodeAllocations());

        assertThat(completeKits.readyByItem().get(highPriorityId))
                .isEqualByComparingTo("0.0000");
        assertThat(completeKits.readyByItem().get(lowPriorityId))
                .isEqualByComparingTo("6.0000");
        assertThat(rows.get(lowPriorityId + "|low-x").allocatedQty())
                .isEqualByComparingTo("6.0000");
        assertThat(rows.get(highPriorityId + "|high-x").allocatedQty())
                .isEqualByComparingTo("0.0000");
        assertThat(rows.get(lowPriorityId + "|low-x").shortageQty())
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void refreshFailsClosedWhenAnActiveBorrowEndpointNoLongerMatchesTheBom() {
        EntityManager em = mock(EntityManager.class);
        Query invalidEndpointCount = queryWithSingleResult(1L);
        when(em.createNativeQuery(anyString())).thenReturn(invalidEndpointCount);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        UUID analysisId = UUID.randomUUID();

        ApiException error = assertThrows(ApiException.class,
                () -> service.validateActiveBorrowEndpointsAfterRefresh(analysisId));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        verify(invalidEndpointCount).setParameter("analysisId", analysisId);
    }

    @Test
    void refreshContinuesWhenEveryActiveBorrowEndpointStillMatchesTheBom() {
        EntityManager em = mock(EntityManager.class);
        Query invalidEndpointCount = queryWithSingleResult(0L);
        when(em.createNativeQuery(anyString())).thenReturn(invalidEndpointCount);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        UUID analysisId = UUID.randomUUID();

        service.validateActiveBorrowEndpointsAfterRefresh(analysisId);

        verify(invalidEndpointCount).setParameter("analysisId", analysisId);
    }

    @Test
    void borrowMovesCoverageExactlyBetweenProducts() {
        UUID unitId = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID highId = UUID.randomUUID();
        UUID lowId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine high = allocationSource(
                highId, UUID.randomUUID(), unitId, 0, "6");
        MaterialAnalysisService.SourceLine low = allocationSource(
                lowId, UUID.randomUUID(), unitId, 1, "6");
        MaterialAnalysisService.BomNode highNode = bomNode(
                highId, material, unitId, "high-m", "6",
                "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode lowNode = bomNode(
                lowId, material, unitId, "low-m", "6",
                "START", "PER_UNIT", "1", "1", true);
        List<MaterialAnalysisService.SourceLine> sources = List.of(high, low);
        Map<UUID, List<MaterialAnalysisService.BomNode>> nodes = Map.of(
                highId, List.of(highNode), lowId, List.of(lowNode));
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> stock =
                Map.of(highNode.dimension(), bd("6"));

        // 基线：高优先级产品拿满 6 件，低优先级为 0。
        MaterialAnalysisService.StageAllocation baselineKits =
                MaterialAnalysisService.allocateStageReadiness(
                        sources, nodes, stock, Set.of("START", "ASSEMBLY", "FINISH"));
        Map<String, MaterialAnalysisService.NodeAllocation> baseline =
                MaterialAnalysisService.allocateDirectMaterials(
                        sources, nodes, baselineKits.remainingPool(),
                        baselineKits.nodeAllocations());
        assertThat(baseline.get(highId + "|high-m").allocatedQty())
                .isEqualByComparingTo("6.0000");
        assertThat(baseline.get(lowId + "|low-m").allocatedQty())
                .isEqualByComparingTo("0.0000");

        // 借用 4 件：A(high) → B(low)。借出方精确降到 2，借入方精确升到 4，
        // 双方齐套可生产量同步变化（2 / 4），第三方无漂移。
        MaterialAnalysisService.BorrowPlanOutcome outcome =
                MaterialAnalysisService.BorrowTuning.plan(
                        List.of(borrowRecord(highId, "high-m", lowId, "low-m",
                                highNode.dimension(), "4")), baseline);
        MaterialAnalysisService.BorrowTuning tuning = outcome.tuning();
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> tunedStock = Map.of(
                highNode.dimension(), bd("6").subtract(tuning.earmarkedByDimension()
                        .getOrDefault(highNode.dimension(), BigDecimal.ZERO)));
        MaterialAnalysisService.StageAllocation tunedKits =
                MaterialAnalysisService.allocateStageReadiness(
                        sources, nodes, tunedStock,
                        Set.of("START", "ASSEMBLY", "FINISH"), tuning);
        Map<String, MaterialAnalysisService.NodeAllocation> tuned =
                MaterialAnalysisService.allocateDirectMaterials(
                        sources, nodes, tunedKits.remainingPool(),
                        tunedKits.nodeAllocations(), tuning);

        assertThat(tunedKits.readyByItem().get(highId))
                .isEqualByComparingTo("2.0000");
        assertThat(tunedKits.readyByItem().get(lowId))
                .isEqualByComparingTo("4.0000");
        assertThat(tuned.get(highId + "|high-m").allocatedQty())
                .isEqualByComparingTo("2.0000");
        assertThat(tuned.get(highId + "|high-m").shortageQty())
                .isEqualByComparingTo("4.0000");
        assertThat(tuned.get(lowId + "|low-m").allocatedQty())
                .isEqualByComparingTo("4.0000");
        assertThat(tuned.get(lowId + "|low-m").shortageQty())
                .isEqualByComparingTo("2.0000");
        assertThat(outcome.effectiveByBorrow().values().iterator().next())
                .isEqualByComparingTo("4.0000");
    }

    @Test
    void borrowLeavesThirdPartyAllocationUntouched() {
        UUID unitId = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID aId = UUID.randomUUID();
        UUID bId = UUID.randomUUID();
        UUID cId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine a = allocationSource(
                aId, UUID.randomUUID(), unitId, 0, "6");
        MaterialAnalysisService.SourceLine c = allocationSource(
                cId, UUID.randomUUID(), unitId, 1, "6");
        MaterialAnalysisService.SourceLine b = allocationSource(
                bId, UUID.randomUUID(), unitId, 2, "6");
        MaterialAnalysisService.BomNode aNode = bomNode(
                aId, material, unitId, "a-m", "6", "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode cNode = bomNode(
                cId, material, unitId, "c-m", "6", "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode bNode = bomNode(
                bId, material, unitId, "b-m", "6", "START", "PER_UNIT", "1", "1", true);
        List<MaterialAnalysisService.SourceLine> sources = List.of(a, c, b);
        Map<UUID, List<MaterialAnalysisService.BomNode>> nodes = Map.of(
                aId, List.of(aNode), cId, List.of(cNode), bId, List.of(bNode));
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> stock =
                Map.of(aNode.dimension(), bd("12"));

        MaterialAnalysisService.StageAllocation baselineKits =
                MaterialAnalysisService.allocateStageReadiness(
                        sources, nodes, stock, Set.of("START", "ASSEMBLY", "FINISH"));
        Map<String, MaterialAnalysisService.NodeAllocation> baseline =
                MaterialAnalysisService.allocateDirectMaterials(
                        sources, nodes, baselineKits.remainingPool(),
                        baselineKits.nodeAllocations());
        assertThat(baseline.get(cId + "|c-m").allocatedQty())
                .isEqualByComparingTo("6.0000");

        MaterialAnalysisService.BorrowPlanOutcome outcome =
                MaterialAnalysisService.BorrowTuning.plan(
                        List.of(borrowRecord(aId, "a-m", bId, "b-m",
                                aNode.dimension(), "4")), baseline);
        MaterialAnalysisService.BorrowTuning tuning = outcome.tuning();
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> tunedStock = Map.of(
                aNode.dimension(), bd("12").subtract(tuning.earmarkedByDimension()
                        .getOrDefault(aNode.dimension(), BigDecimal.ZERO)));
        MaterialAnalysisService.StageAllocation tunedKits =
                MaterialAnalysisService.allocateStageReadiness(
                        sources, nodes, tunedStock,
                        Set.of("START", "ASSEMBLY", "FINISH"), tuning);
        Map<String, MaterialAnalysisService.NodeAllocation> tuned =
                MaterialAnalysisService.allocateDirectMaterials(
                        sources, nodes, tunedKits.remainingPool(),
                        tunedKits.nodeAllocations(), tuning);

        // 借用 4：A 6→2、B 0→4，而中间的 C 保持 6 件完全不变。
        assertThat(tuned.get(aId + "|a-m").allocatedQty())
                .isEqualByComparingTo("2.0000");
        assertThat(tuned.get(bId + "|b-m").allocatedQty())
                .isEqualByComparingTo("4.0000");
        assertThat(tuned.get(cId + "|c-m").allocatedQty())
                .isEqualByComparingTo("6.0000");
        assertThat(tunedKits.readyByItem().get(cId)).isEqualByComparingTo("6.0000");
    }

    @Test
    void multipleBorrowsFromSameNodeNeverOvershootBaseline() {
        UUID unitId = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID aId = UUID.randomUUID();
        UUID bId = UUID.randomUUID();
        UUID dId = UUID.randomUUID();
        MaterialAnalysisService.BomNode aNode = bomNode(
                aId, material, unitId, "a-m", "6", "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode bNode = bomNode(
                bId, material, unitId, "b-m", "6", "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode dNode = bomNode(
                dId, material, unitId, "d-m", "6", "START", "PER_UNIT", "1", "1", true);
        Map<String, MaterialAnalysisService.NodeAllocation> baseline = Map.of(
                aId + "|a-m", new MaterialAnalysisService.NodeAllocation(bd("6"), bd("0")),
                bId + "|b-m", new MaterialAnalysisService.NodeAllocation(bd("0"), bd("6")),
                dId + "|d-m", new MaterialAnalysisService.NodeAllocation(bd("0"), bd("6")));

        // 同一借出节点两笔各 4 件：第一笔生效 4，第二笔只剩 2 可借，
        // 合计绝不超过基线分配 6。
        MaterialAnalysisService.BorrowPlanOutcome outcome =
                MaterialAnalysisService.BorrowTuning.plan(List.of(
                        borrowRecord(aId, "a-m", bId, "b-m", aNode.dimension(), "4"),
                        borrowRecord(aId, "a-m", dId, "d-m", aNode.dimension(), "4")),
                        baseline);
        List<BigDecimal> effective = List.copyOf(outcome.effectiveByBorrow().values());
        assertThat(effective.get(0)).isEqualByComparingTo("4.0000");
        assertThat(effective.get(1)).isEqualByComparingTo("2.0000");
        assertThat(outcome.tuning().capOrNull(aId + "|a-m"))
                .isEqualByComparingTo("0.0000");
        assertThat(outcome.tuning().earmarkedByDimension().get(aNode.dimension()))
                .isEqualByComparingTo("6.0000");
    }

    @Test
    void exactReceiptPegStaysWithItsOriginalMaterialLineInsideOneAnalysis() {
        UUID unitId = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID olderItemId = UUID.randomUUID();
        UUID receiptOwnerItemId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine older = allocationSource(
                olderItemId, UUID.randomUUID(), unitId, 0, "6");
        MaterialAnalysisService.SourceLine receiptOwner = allocationSource(
                receiptOwnerItemId, UUID.randomUUID(), unitId, 1, "6");
        MaterialAnalysisService.BomNode olderNode = bomNode(
                olderItemId, material, unitId, "older-m", "6",
                "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode receiptOwnerNode = bomNode(
                receiptOwnerItemId, material, unitId, "owner-m", "6",
                "START", "PER_UNIT", "1", "1", true);
        List<MaterialAnalysisService.SourceLine> sources = List.of(older, receiptOwner);
        List<MaterialAnalysisService.BomNode> allNodes = List.of(
                olderNode, receiptOwnerNode);
        Map<UUID, List<MaterialAnalysisService.BomNode>> bySource = Map.of(
                olderItemId, List.of(olderNode),
                receiptOwnerItemId, List.of(receiptOwnerNode));
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> afterSafety =
                Map.of(olderNode.dimension(), bd("6"));

        MaterialAnalysisService.BorrowTuning exact =
                MaterialAnalysisService.planExactPegs(
                        List.of(exactPeg(receiptOwnerItemId, "owner-m",
                                receiptOwnerNode.dimension(), "4")),
                        allNodes, afterSafety);
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> shared = Map.of(
                olderNode.dimension(), afterSafety.get(olderNode.dimension())
                        .subtract(exact.earmarkedByDimension()
                                .get(receiptOwnerNode.dimension())));
        MaterialAnalysisService.StageAllocation kits =
                MaterialAnalysisService.allocateStageReadiness(
                        sources, bySource, shared,
                        Set.of("START", "ASSEMBLY", "FINISH"), exact);
        Map<String, MaterialAnalysisService.NodeAllocation> rows =
                MaterialAnalysisService.allocateDirectMaterials(
                        sources, bySource, kits.remainingPool(),
                        kits.nodeAllocations(), exact);

        assertThat(exact.earmarkedByDimension().get(receiptOwnerNode.dimension()))
                .isEqualByComparingTo("4.0000");
        assertThat(rows.get(olderItemId + "|older-m").allocatedQty())
                .isEqualByComparingTo("2.0000");
        assertThat(rows.get(receiptOwnerItemId + "|owner-m").allocatedQty())
                .isEqualByComparingTo("4.0000");
        assertThat(rows.values().stream()
                .map(MaterialAnalysisService.NodeAllocation::allocatedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("6.0000");
    }

    @Test
    void exactReceiptPegCannotBypassSafetyStock() {
        UUID unitId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        MaterialAnalysisService.BomNode node = bomNode(
                itemId, UUID.randomUUID(), unitId, "safe-m", "10",
                "START", "PER_UNIT", "1", "1", true);

        BigDecimal afterSafety = MaterialAnalysisService
                .availableIncludingOwnAfterSafety(
                        BigDecimal.ZERO, bd("5"), bd("3"));
        MaterialAnalysisService.BorrowTuning exact =
                MaterialAnalysisService.planExactPegs(
                        List.of(exactPeg(itemId, "safe-m", node.dimension(), "5")),
                        List.of(node), Map.of(node.dimension(), afterSafety));

        assertThat(afterSafety).isEqualByComparingTo("2.0000");
        assertThat(exact.earmarkedByDimension().get(node.dimension()))
                .isEqualByComparingTo("2.0000");
    }

    @Test
    void exactReceiptEntitlementTransferredToMakeChildRestoresChildReadiness() {
        UUID unitId = UUID.randomUUID();
        UUID originalItemId = UUID.randomUUID();
        UUID makeChildItemId = UUID.randomUUID();
        UUID makeGoodsId = UUID.randomUUID();
        UUID purchasedGoodsId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine original = allocationSource(
                originalItemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.SourceLine makeChild = allocationSource(
                makeChildItemId, makeGoodsId, unitId, 1, "10");
        MaterialAnalysisService.BomNode makeParent = diagnosticNode(
                originalItemId, makeGoodsId, unitId,
                "make-parent", null, 1, "10", "1", "MAKE", true);
        MaterialAnalysisService.BomNode formerParentChild = diagnosticNode(
                originalItemId, purchasedGoodsId, unitId,
                "make-parent/purchased", "make-parent", 2,
                "10", "1", "BUY", false);
        MaterialAnalysisService.BomNode makeChildDirect = diagnosticNode(
                makeChildItemId, purchasedGoodsId, unitId,
                "purchased", null, 1, "10", "1", "BUY", false);
        List<MaterialAnalysisService.SourceLine> sources =
                List.of(original, makeChild);
        List<MaterialAnalysisService.BomNode> nodes =
                List.of(makeParent, formerParentChild, makeChildDirect);
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> stock =
                Map.of(makeChildDirect.dimension(), bd("10"));

        MaterialAnalysisService.BorrowTuning exact =
                MaterialAnalysisService.planExactPegs(
                        List.of(exactPeg(makeChildItemId, "purchased",
                                makeChildDirect.dimension(), "10")),
                        nodes, stock);
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> shared =
                Map.of(makeChildDirect.dimension(),
                        stock.get(makeChildDirect.dimension()).subtract(
                                exact.earmarkedByDimension()
                                        .get(makeChildDirect.dimension())));
        String parentKey = originalItemId + "|make-parent";
        MaterialAnalysisService.NestedDiagnosticPlan diagnostic =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        sources, nodes, shared, Map.of(parentKey, "MAKE"),
                        Set.of(parentKey), exact);

        assertThat(node(diagnostic, "make-parent/purchased")
                .snapshotRequiredQty()).isEqualByComparingTo("0.0000");
        assertThat(diagnostic.nodeAllocations()
                .get(makeChildItemId + "|purchased").allocatedQty())
                .isEqualByComparingTo("10.0000");
        assertThat(diagnostic.nodeAllocations()
                .get(makeChildItemId + "|purchased").shortageQty())
                .isEqualByComparingTo("0.0000");

        MaterialAnalysisService.StageAllocation readiness =
                MaterialAnalysisService.allocateStageReadiness(
                        sources,
                        Map.of(originalItemId, List.of(makeParent),
                                makeChildItemId, List.of(makeChildDirect)),
                        shared, Set.of("START", "ASSEMBLY", "FINISH"), exact);
        assertThat(readiness.readyByItem().get(makeChildItemId))
                .isEqualByComparingTo("10.0000");
    }

    @Test
    void nodeExactPegProjectionDoesNotCopyOneSiblingReceiptToAnother() {
        EntityManager em = mock(EntityManager.class);
        UUID ownerMaterialId = UUID.randomUUID();
        UUID siblingMaterialId = UUID.randomUUID();
        Query exactRows = query(Collections.singletonList(
                new Object[]{ownerMaterialId, bd("10")}));
        when(em.createNativeQuery(anyString())).thenReturn(exactRows);
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));

        Map<UUID, BigDecimal> exact = invokePrivate(
                service, "exactPeggedByMaterial",
                new Class<?>[]{UUID.class, UUID.class},
                UUID.randomUUID(), UUID.randomUUID());

        assertThat(exact.get(ownerMaterialId)).isEqualByComparingTo("10");
        assertThat(exact.getOrDefault(siblingMaterialId, BigDecimal.ZERO))
                .isEqualByComparingTo("0");
    }

    @Test
    void exactPegRefreshRequiresTheSameCurrentNodeAndPhysicalDimension() {
        UUID itemId = UUID.randomUUID();
        MaterialAnalysisService.MaterialDimension physical =
                new MaterialAnalysisService.MaterialDimension(
                        UUID.randomUUID(), null, UUID.randomUUID());
        MaterialAnalysisService.ExactPegRecord peg =
                exactPeg(itemId, "stable-node", physical, "2");
        String key = itemId + "|stable-node";

        MaterialAnalysisService.requireExactPegRefreshCompatible(
                List.of(peg), Map.of(key, physical));

        ApiException removed = assertThrows(ApiException.class, () ->
                MaterialAnalysisService.requireExactPegRefreshCompatible(
                        List.of(peg), Map.of()));
        ApiException changed = assertThrows(ApiException.class, () ->
                MaterialAnalysisService.requireExactPegRefreshCompatible(
                        List.of(peg), Map.of(key,
                                new MaterialAnalysisService.MaterialDimension(
                                        UUID.randomUUID(), null, physical.unitId()))));

        assertThat(removed.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(changed.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(changed.getMessage()).contains("禁止刷新");
    }

    @Test
    void activeBorrowOnAnExactPegDimensionFailsClosed() {
        UUID unitId = UUID.randomUUID();
        UUID fromItemId = UUID.randomUUID();
        UUID toItemId = UUID.randomUUID();
        MaterialAnalysisService.MaterialDimension dimension =
                new MaterialAnalysisService.MaterialDimension(
                        UUID.randomUUID(), null, unitId);
        MaterialAnalysisService.BorrowRecord borrow = borrowRecord(
                fromItemId, "from", toItemId, "to", dimension, "1");
        // ACTIVE 但本轮实际迁移量为 0 的历史调货不应阻断 IQC/刷新。
        MaterialAnalysisService.ensureExactPegBorrowCompatibility(
                List.of(exactPeg(toItemId, "to", dimension, "2")),
                List.of(borrow), Map.of(borrow.id(), BigDecimal.ZERO));

        ApiException error = assertThrows(ApiException.class, () ->
                MaterialAnalysisService.ensureExactPegBorrowCompatibility(
                        List.of(exactPeg(toItemId, "to", dimension, "2")),
                        List.of(borrow), Map.of(borrow.id(), bd("1"))));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("显式受益方变更");
    }

    @Test
    void supplyNotificationRejectsActiveBorrowBeforeCreatingAnExternalTask()
            throws Exception {
        EntityManager em = mock(EntityManager.class);
        Query conflicts = queryWithSingleResult(1L);
        when(em.createNativeQuery(anyString())).thenReturn(conflicts);
        MaterialAnalysisCommandService commands = mock(
                MaterialAnalysisCommandService.class,
                org.mockito.Answers.CALLS_REAL_METHODS);
        Field entityManager = MaterialAnalysisCommandService.class
                .getDeclaredField("em");
        entityManager.setAccessible(true);
        entityManager.set(commands, em);
        UUID analysisId = UUID.randomUUID();
        Set<UUID> materialIds = Set.of(UUID.randomUUID(), UUID.randomUUID());

        ApiException error = assertThrows(ApiException.class, () ->
                commands.requireNoActiveBorrowForSupplyMaterials(
                        analysisId, materialIds));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.getMessage()).contains("请先撤销调拨");
        verify(conflicts).setParameter("analysisId", analysisId);
        verify(conflicts).setParameter("materialIds", materialIds);
    }

    private static MaterialAnalysisService.ExactPegRecord exactPeg(
            UUID itemId, String nodeKey,
            MaterialAnalysisService.MaterialDimension dimension, String qty) {
        return new MaterialAnalysisService.ExactPegRecord(
                UUID.randomUUID(), UUID.randomUUID(), itemId, nodeKey,
                dimension, bd(qty));
    }

    private static MaterialAnalysisService.BorrowRecord borrowRecord(
            UUID fromItemId, String fromNodeKey, UUID toItemId, String toNodeKey,
            MaterialAnalysisService.MaterialDimension dimension, String qty) {
        return new MaterialAnalysisService.BorrowRecord(
                UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
                fromItemId, fromNodeKey, toItemId, toNodeKey, dimension, bd(qty));
    }

    @Test
    void noProductionMaterialChildrenAreReadyForEntireDemand() {
        assertThat(MaterialAnalysisService.maxReadyExact(
                bd("12.3456"), List.of(), Map.of(),
                MaterialAnalysisService.BorrowTuning.NONE))
                .isEqualByComparingTo("12.3456");
    }

    @Test
    void expectedReadinessUsesWholePackageAndFixedBatchSteps() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.BomNode wholePackage = bomNode(
                itemId, UUID.randomUUID(), unitId, "carton", "4",
                "FINISH", "PER_PACKAGE", "2", "6", false);
        MaterialAnalysisService.MaterialDimension carton = wholePackage.dimension();
        LocalDate inboundDate = LocalDate.of(2026, 8, 20);
        MaterialAnalysisService.TimePhasedPool packagePool =
                new MaterialAnalysisService.TimePhasedPool(
                        Map.of(carton, bd("3")),
                        List.of(new MaterialAnalysisService.InboundLot(
                                carton, inboundDate, bd("1"))));

        assertThat(packagePool.maxReadyExact(
                bd("10"), List.of(wholePackage), inboundDate.minusDays(1)))
                .isEqualByComparingTo("6.0000");
        assertThat(packagePool.maxReadyExact(
                bd("10"), List.of(wholePackage), inboundDate))
                .isEqualByComparingTo("10.0000");
        MaterialAnalysisService.TimePhasedPool incrementalPool =
                new MaterialAnalysisService.TimePhasedPool(
                        Map.of(carton, bd("1")),
                        List.of(new MaterialAnalysisService.InboundLot(
                                carton, inboundDate, bd("1"))));
        assertThat(incrementalPool.maxReadyFromBaseExact(
                bd("6"), bd("10"), List.of(wholePackage), inboundDate.minusDays(1)))
                .isEqualByComparingTo("6.0000");
        assertThat(incrementalPool.maxReadyFromBaseExact(
                bd("6"), bd("10"), List.of(wholePackage), inboundDate))
                .isEqualByComparingTo("10.0000");

        MaterialAnalysisService.BomNode fixedBatch = bomNode(
                itemId, UUID.randomUUID(), unitId, "batch-additive", "0.5000",
                "ASSEMBLY", "FIXED_BATCH", "0.25", "100", true);
        assertThat(MaterialAnalysisService.maxReadyExact(
                bd("101"), List.of(fixedBatch),
                Map.of(fixedBatch.dimension(), bd("0.49"))))
                .isEqualByComparingTo("100.0000");
    }

    @Test
    void nestedDiagnosticExplodesOnlyTheParentsActualShortage() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.BomNode parent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "parent", null,
                1, "10", "1", "MAKE", true);
        MaterialAnalysisService.BomNode child = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "parent/child", "parent",
                2, "10", "1", "BUY", false);

        MaterialAnalysisService.NestedDiagnosticPlan partial =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(parent, child), Map.of(
                                parent.dimension(), bd("8"),
                                child.dimension(), bd("10")));

        assertThat(node(partial, "parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("2.0000");
        assertThat(partial.nodeAllocations().get(itemId + "|parent").shortageQty())
                .isEqualByComparingTo("2.0000");
        assertThat(partial.nodeAllocations().get(itemId + "|parent/child").allocatedQty())
                .isEqualByComparingTo("2.0000");
        assertThat(partial.hasUncoveredDirectChild(parent)).isFalse();

        MaterialAnalysisService.NestedDiagnosticPlan parentFullyAvailable =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(parent, child), Map.of(
                                parent.dimension(), bd("10"),
                                child.dimension(), bd("10")));

        assertThat(node(parentFullyAvailable, "parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("0.0000");
        assertThat(parentFullyAvailable.nodeAllocations()
                .get(itemId + "|parent/child").allocatedQty())
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void nestedDiagnosticSharesStockAcrossMultipleBomPaths() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID sharedChildGoods = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "1");
        MaterialAnalysisService.BomNode firstParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "p1", null,
                1, "1", "1", "MAKE", true);
        MaterialAnalysisService.BomNode secondParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "p2", null,
                1, "1", "1", "MAKE", true);
        MaterialAnalysisService.BomNode firstChild = diagnosticNode(
                itemId, sharedChildGoods, unitId, "p1/c", "p1",
                2, "1", "1", "BUY", false);
        MaterialAnalysisService.BomNode secondChild = diagnosticNode(
                itemId, sharedChildGoods, unitId, "p2/c", "p2",
                2, "1", "1", "BUY", false);

        MaterialAnalysisService.NestedDiagnosticPlan diagnostic =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source),
                        List.of(firstParent, firstChild, secondParent, secondChild),
                        Map.of(firstChild.dimension(), bd("1")));

        BigDecimal allocatedAcrossPaths = List.of("p1/c", "p2/c").stream()
                .map(key -> diagnostic.nodeAllocations().get(
                        itemId + "|" + key).allocatedQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal shortageAcrossPaths = List.of("p1/c", "p2/c").stream()
                .map(key -> diagnostic.nodeAllocations().get(
                        itemId + "|" + key).shortageQty())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        assertThat(allocatedAcrossPaths).isEqualByComparingTo("1.0000");
        assertThat(shortageAcrossPaths).isEqualByComparingTo("1.0000");
    }

    @Test
    void nestedDiagnosticUsesConfirmedMakeOrBuyRouteInBothDirections() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.BomNode buyParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "buy-parent", null,
                1, "10", "1", "BUY", true);
        MaterialAnalysisService.BomNode buyChild = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "buy-parent/child", "buy-parent",
                2, "10", "1", "BUY", false);

        MaterialAnalysisService.NestedDiagnosticPlan suggestedBuy =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(buyParent, buyChild), Map.of());
        assertThat(node(suggestedBuy, "buy-parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("0.0000");

        MaterialAnalysisService.BomNode reviewParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "review-parent", null,
                1, "10", "1", "REVIEW", true);
        MaterialAnalysisService.BomNode reviewChild = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "review-parent/child", "review-parent",
                2, "10", "1", "BUY", false);
        MaterialAnalysisService.NestedDiagnosticPlan confirmedMake =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(reviewParent, reviewChild), Map.of(
                                reviewParent.dimension(), bd("8"),
                                reviewChild.dimension(), bd("10")),
                        Map.of(itemId + "|review-parent", "MAKE"));
        assertThat(node(confirmedMake, "review-parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("2.0000");

        MaterialAnalysisService.BomNode makeParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "make-parent", null,
                1, "10", "1", "MAKE", true);
        MaterialAnalysisService.BomNode makeChild = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "make-parent/child", "make-parent",
                2, "10", "1", "BUY", false);
        MaterialAnalysisService.NestedDiagnosticPlan confirmedBuy =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(makeParent, makeChild), Map.of(),
                        Map.of(itemId + "|make-parent", "BUY"));
        assertThat(node(confirmedBuy, "make-parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void nestedDiagnosticExplodesMaterialsForSuppliedSubcontract() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.BomNode subcontractParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "subcontract-parent", null,
                1, "10", "1", "SUBCONTRACT", true);
        MaterialAnalysisService.BomNode suppliedChild = diagnosticNode(
                itemId, UUID.randomUUID(), unitId,
                "subcontract-parent/child", "subcontract-parent",
                2, "10", "2", "BUY", false);

        MaterialAnalysisService.NestedDiagnosticPlan diagnostic =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(subcontractParent, suppliedChild), Map.of());

        assertThat(node(diagnostic, "subcontract-parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("20.0000");
        assertThat(diagnostic.nodeAllocations()
                .get(itemId + "|subcontract-parent/child").shortageQty())
                .isEqualByComparingTo("20.0000");
        assertThat(diagnostic.hasUncoveredDirectChild(subcontractParent)).isTrue();
    }

    @Test
    void subcontractPreparationTakeoverReducesOnlyItsParentOutputShare() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.BomNode parent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "subcontract-parent", null,
                1, "10", "1", "SUBCONTRACT", true);
        MaterialAnalysisService.BomNode child = diagnosticNode(
                itemId, UUID.randomUUID(), unitId,
                "subcontract-parent/child", "subcontract-parent",
                2, "10", "2", "BUY", false);
        String parentKey = itemId + "|subcontract-parent";

        MaterialAnalysisService.NestedDiagnosticPlan partial =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(parent, child), Map.of(),
                        Map.of(parentKey, "SUBCONTRACT"), Set.of(),
                        Map.of(parentKey, bd("4")),
                        MaterialAnalysisService.BorrowTuning.NONE);
        assertThat(node(partial, "subcontract-parent/child")
                .snapshotRequiredQty()).isEqualByComparingTo("12.0000");

        MaterialAnalysisService.NestedDiagnosticPlan complete =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(parent, child), Map.of(),
                        Map.of(parentKey, "SUBCONTRACT"), Set.of(),
                        Map.of(parentKey, bd("10")),
                        MaterialAnalysisService.BorrowTuning.NONE);
        assertThat(node(complete, "subcontract-parent/child")
                .snapshotRequiredQty()).isEqualByComparingTo("0.0000");
        assertThat(complete.hasUncoveredDirectChild(parent)).isFalse();
    }

    @Test
    void delegatedMakeMovesDescendantDemandToTheChildAnalysisItem() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.BomNode makeParent = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "make-parent", null,
                1, "10", "1", "MAKE", true);
        MaterialAnalysisService.BomNode child = diagnosticNode(
                itemId, UUID.randomUUID(), unitId, "make-parent/child", "make-parent",
                2, "10", "1", "BUY", false);
        String parentKey = itemId + "|make-parent";

        MaterialAnalysisService.NestedDiagnosticPlan delegated =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(source), List.of(makeParent, child), Map.of(),
                        Map.of(parentKey, "MAKE"), Set.of(parentKey));

        assertThat(node(delegated, "make-parent/child").snapshotRequiredQty())
                .isEqualByComparingTo("0.0000");
        assertThat(delegated.hasUncoveredDirectChild(makeParent)).isFalse();
    }

    @Test
    void requirementProjectionUsesExactMakeChildOwnerPerBomPath() {
        UUID analysisItemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID repeatedMakeGoodsId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                analysisItemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.MaterialRow delegatedParent = requirementRow(
                analysisItemId, "make-a", null, 1,
                "10", "10", "MAKE", "MAKE", "START", repeatedMakeGoodsId);
        MaterialAnalysisService.MaterialRow delegatedDescendant = requirementRow(
                analysisItemId, "make-a/part", "make-a", 2,
                "0", "0", "BUY", null, "START");
        MaterialAnalysisService.MaterialRow delegatedGrandchild = requirementRow(
                analysisItemId, "make-a/part/deep", "make-a/part", 3,
                "0", "0", "BUY", null, "START");
        MaterialAnalysisService.MaterialRow coveredSiblingParent = requirementRow(
                analysisItemId, "make-b", null, 1,
                "10", "0", "MAKE", "MAKE", "START", repeatedMakeGoodsId);
        MaterialAnalysisService.MaterialRow coveredSiblingDescendant = requirementRow(
                analysisItemId, "make-b/part", "make-b", 2,
                "0", "0", "BUY", null, "START");
        UUID otherAnalysisItemId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine otherSource = allocationSource(
                otherAnalysisItemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.MaterialRow sameNodeOtherItemParent = requirementRow(
                otherAnalysisItemId, "make-a", null, 1,
                "10", "0", "MAKE", "MAKE", "START", repeatedMakeGoodsId);
        MaterialAnalysisService.MaterialRow sameNodeOtherItemChild = requirementRow(
                otherAnalysisItemId, "make-a/part", "make-a", 2,
                "0", "0", "BUY", null, "START");
        Map<MaterialAnalysisService.MaterialNodeIdentity,
                MaterialAnalysisService.MaterialRow> rows = Map.of(
                delegatedParent.nodeIdentity(), delegatedParent,
                delegatedDescendant.nodeIdentity(), delegatedDescendant,
                delegatedGrandchild.nodeIdentity(), delegatedGrandchild,
                coveredSiblingParent.nodeIdentity(), coveredSiblingParent,
                coveredSiblingDescendant.nodeIdentity(), coveredSiblingDescendant,
                sameNodeOtherItemParent.nodeIdentity(), sameNodeOtherItemParent,
                sameNodeOtherItemChild.nodeIdentity(), sameNodeOtherItemChild);
        UUID childAnalysisLineId = UUID.randomUUID();
        MaterialAnalysisService.DelegatedRequirementOwner owner =
                new MaterialAnalysisService.DelegatedRequirementOwner(
                        delegatedParent.id(), childAnalysisLineId,
                        "自制备料 2026-08-30 abcd", bd("10"));
        Map<MaterialAnalysisService.MaterialNodeIdentity,
                MaterialAnalysisService.DelegatedRequirementOwner> owners = Map.of(
                delegatedParent.nodeIdentity(), owner);

        MaterialAnalysisService.RequirementProjection delegated =
                MaterialAnalysisService.requirementProjection(
                        delegatedDescendant, rows, owners, source);
        MaterialAnalysisService.RequirementProjection sibling =
                MaterialAnalysisService.requirementProjection(
                        coveredSiblingDescendant, rows, owners, source);
        MaterialAnalysisService.RequirementProjection deep =
                MaterialAnalysisService.requirementProjection(
                        delegatedGrandchild, rows, owners, source);
        MaterialAnalysisService.RequirementProjection otherItem =
                MaterialAnalysisService.requirementProjection(
                        sameNodeOtherItemChild, rows, owners, otherSource);
        MaterialAnalysisService.RequirementProjection positiveParent =
                MaterialAnalysisService.requirementProjection(
                        delegatedParent, rows, owners, source);

        assertThat(delegated.state())
                .isEqualTo(REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD);
        assertThat(delegated.delegatedToAnalysisLineId())
                .isEqualTo(childAnalysisLineId);
        assertThat(delegated.delegatedToSourceRef())
                .isEqualTo("自制备料 2026-08-30 abcd");
        assertThat(delegated.delegatedToRequestedQty())
                .isEqualByComparingTo("10");
        assertThat(sibling.state())
                .isEqualTo(REQUIREMENT_STATE_INACTIVE_PARENT_COVERED);
        assertThat(sibling.delegatedToAnalysisLineId()).isNull();
        assertThat(deep.state())
                .isEqualTo(REQUIREMENT_STATE_DELEGATED_TO_MAKE_CHILD);
        assertThat(deep.delegatedToAnalysisLineId()).isEqualTo(childAnalysisLineId);
        assertThat(otherItem.state())
                .isEqualTo(REQUIREMENT_STATE_INACTIVE_PARENT_COVERED);
        assertThat(otherItem.delegatedToAnalysisLineId()).isNull();
        assertThat(positiveParent.state()).isEqualTo(REQUIREMENT_STATE_ACTIVE);
    }

    @Test
    void zeroDescendantExplainsSubcontractPreparationOwnership() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.MaterialRow parent = requirementRow(
                itemId, "subcontract-parent", null, 1,
                "10", "10", "SUBCONTRACT", "SUBCONTRACT", "START");
        MaterialAnalysisService.MaterialRow child = requirementRow(
                itemId, "subcontract-parent/child", "subcontract-parent", 2,
                "0", "0", "BUY", null, "START");
        Map<MaterialAnalysisService.MaterialNodeIdentity,
                MaterialAnalysisService.MaterialRow> rows = Map.of(
                parent.nodeIdentity(), parent, child.nodeIdentity(), child);

        MaterialAnalysisService.RequirementProjection projection =
                MaterialAnalysisService.requirementProjection(
                        child, rows, Map.of(), Set.of(parent.nodeIdentity()), source);

        assertThat(projection.state()).isEqualTo(
                REQUIREMENT_STATE_DELEGATED_TO_SUBCONTRACT_PREPARATION);
        assertThat(projection.delegatedToAnalysisLineId()).isNull();
    }

    @Test
    void requirementProjectionExplainsRouteReferencePlanAndNeutralZero() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine activeSource = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.SourceLine transferredSource = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "10", "10", "0");
        MaterialAnalysisService.MaterialRow buyParent = requirementRow(
                itemId, "buy-parent", null, 1,
                "10", "10", "BUY", "BUY", "START");
        MaterialAnalysisService.MaterialRow buyChild = requirementRow(
                itemId, "buy-parent/child", "buy-parent", 2,
                "0", "0", "MAKE", null, "START");
        Map<MaterialAnalysisService.MaterialNodeIdentity,
                MaterialAnalysisService.MaterialRow> routedRows = Map.of(
                buyParent.nodeIdentity(), buyParent,
                buyChild.nodeIdentity(), buyChild);
        MaterialAnalysisService.MaterialRow referenceParent = requirementRow(
                itemId, "reference-parent", null, 1,
                "10", "10", "MAKE", "MAKE", "REFERENCE");
        MaterialAnalysisService.MaterialRow referenceChild = requirementRow(
                itemId, "reference-parent/child", "reference-parent", 2,
                "0", "0", "BUY", null, "START");
        Map<MaterialAnalysisService.MaterialNodeIdentity,
                MaterialAnalysisService.MaterialRow> referenceRows = Map.of(
                referenceParent.nodeIdentity(), referenceParent,
                referenceChild.nodeIdentity(), referenceChild);
        MaterialAnalysisService.MaterialRow transferred = requirementRow(
                itemId, "transferred", null, 1,
                "0", "0", "BUY", null, "START");
        MaterialAnalysisService.MaterialRow neutral = requirementRow(
                itemId, "neutral", null, 1,
                "0", "0", "BUY", null, "START");

        assertThat(MaterialAnalysisService.requirementProjection(
                buyChild, routedRows, Map.of(), activeSource).state())
                .isEqualTo(REQUIREMENT_STATE_INACTIVE_PARENT_ROUTE);
        assertThat(MaterialAnalysisService.requirementProjection(
                referenceChild, referenceRows,
                Map.of(), activeSource).state())
                .isEqualTo(REQUIREMENT_STATE_INACTIVE_REFERENCE);
        assertThat(MaterialAnalysisService.requirementProjection(
                transferred, Map.of(transferred.nodeIdentity(), transferred),
                Map.of(), transferredSource).state())
                .isEqualTo(REQUIREMENT_STATE_TRANSFERRED_TO_PLAN);
        assertThat(MaterialAnalysisService.requirementProjection(
                neutral, Map.of(neutral.nodeIdentity(), neutral),
                Map.of(), activeSource).state())
                .isEqualTo(REQUIREMENT_STATE_INACTIVE);
    }

    @Test
    void actionGroupKeyKeepsIdenticalMaterialDimensionsIndependentPerBomPath() {
        UUID analysisItemId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.MaterialRow leftPath = materialRow(
                analysisItemId, goodsId, unitId, "assembly-left/shared-part");
        MaterialAnalysisService.MaterialRow rightPath = materialRow(
                analysisItemId, goodsId, unitId, "assembly-right/shared-part");
        MaterialAnalysisService.MaterialRow refreshedLeftPath = materialRow(
                analysisItemId, goodsId, unitId, "assembly-left/shared-part");
        MaterialAnalysisService.MaterialRow coveredDepthOne = materialRow(
                analysisItemId, goodsId, unitId, "covered-direct-part",
                1, BigDecimal.ZERO);

        assertThat(leftPath.materialKey()).isEqualTo(rightPath.materialKey());
        assertThat(leftPath.actionGroupKey()).isNotEqualTo(rightPath.actionGroupKey());
        assertThat(leftPath.actionGroupKey()).isEqualTo(refreshedLeftPath.actionGroupKey());
        assertThat(leftPath.actionable()).isTrue();
        assertThat(coveredDepthOne.actionable()).isFalse();
    }

    @Test
    void warningReferenceRowsCannotConsumeStockBeforeMakeDependencies() {
        UUID unitId = UUID.randomUUID();
        UUID sharedGoods = UUID.randomUUID();
        UUID warningItemId = UUID.randomUUID();
        UUID makeItemId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine warningSource = allocationSource(
                warningItemId, UUID.randomUUID(), unitId, 0, "1");
        MaterialAnalysisService.SourceLine makeSource = allocationSource(
                makeItemId, UUID.randomUUID(), unitId, 1, "1");
        MaterialAnalysisService.BomNode warning = diagnosticNode(
                warningItemId, sharedGoods, unitId, "warning", null,
                1, "1", "1", "BUY", false, "REFERENCE", false);
        MaterialAnalysisService.BomNode makeParent = diagnosticNode(
                makeItemId, UUID.randomUUID(), unitId, "make", null,
                1, "1", "1", "MAKE", true);
        MaterialAnalysisService.BomNode makeChild = diagnosticNode(
                makeItemId, sharedGoods, unitId, "make/child", "make",
                2, "1", "1", "BUY", false);

        MaterialAnalysisService.NestedDiagnosticPlan diagnostic =
                MaterialAnalysisService.allocateNestedDiagnostics(
                        List.of(warningSource, makeSource),
                        List.of(warning, makeParent, makeChild),
                        Map.of(warning.dimension(), bd("1")));

        assertThat(diagnostic.nodeAllocations()
                .get(makeItemId + "|make/child").allocatedQty())
                .isEqualByComparingTo("1.0000");
        assertThat(diagnostic.nodeAllocations()
                .get(warningItemId + "|warning").allocatedQty())
                .isEqualByComparingTo("0.0000");
    }

    @Test
    void shippingReferenceDoesNotReserveStockOrBlockProduction() {
        UUID unitId = UUID.randomUUID();
        UUID shared = UUID.randomUUID();
        UUID shipping = UUID.randomUUID();
        UUID highId = UUID.randomUUID();
        UUID lowId = UUID.randomUUID();
        MaterialAnalysisService.SourceLine high = allocationSource(
                highId, UUID.randomUUID(), unitId, 0, "10");
        MaterialAnalysisService.SourceLine low = allocationSource(
                lowId, UUID.randomUUID(), unitId, 1, "10");
        MaterialAnalysisService.BomNode highStart = bomNode(
                highId, shared, unitId, "high-start", "10",
                "START", "PER_UNIT", "1", "1", true);
        MaterialAnalysisService.BomNode highShip = diagnosticNode(
                highId, shipping, unitId, "high-ship", null, 1,
                "10", "1", "BUY", false, "SHIP", false);
        MaterialAnalysisService.BomNode lowStart = bomNode(
                lowId, shared, unitId, "low-start", "10",
                "START", "PER_UNIT", "1", "1", true);
        Map<UUID, List<MaterialAnalysisService.BomNode>> nodes = Map.of(
                highId, List.of(highStart, highShip), lowId, List.of(lowStart));
        Map<MaterialAnalysisService.MaterialDimension, BigDecimal> stock = Map.of(
                highStart.dimension(), bd("10"),
                highShip.dimension(), BigDecimal.ZERO);

        MaterialAnalysisService.StagePlan stages =
                MaterialAnalysisService.allocateNestedStages(
                        List.of(high, low), nodes, stock, Map.of());
        MaterialAnalysisService.StageAllocation finish = stages.finish();
        MaterialAnalysisService.StageExtension ship = stages.ship();
        MaterialAnalysisService.StageExtension start = stages.start();

        assertThat(finish.readyByItem().get(highId)).isEqualByComparingTo("10");
        assertThat(ship.readyByItem().get(highId)).isEqualByComparingTo("10");
        assertThat(start.readyByItem().get(highId)).isEqualByComparingTo("10");
        assertThat(finish.readyByItem().get(lowId)).isEqualByComparingTo("0");
        assertThat(ship.nodeAllocations())
                .doesNotContainKey(highId + "|high-ship");
        assertThat(ship.readyByItem().get(highId))
                .isLessThanOrEqualTo(finish.readyByItem().get(highId));
        assertThat(finish.readyByItem().get(highId))
                .isLessThanOrEqualTo(start.readyByItem().get(highId));
        BigDecimal allocatedShared = finish.nodeAllocations().values().stream()
                .map(MaterialAnalysisService.NodeAllocation::allocatedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .add(start.nodeAllocations().values().stream()
                        .map(MaterialAnalysisService.NodeAllocation::allocatedQty)
                        .reduce(BigDecimal.ZERO, BigDecimal::add));
        assertThat(allocatedShared).isLessThanOrEqualTo(bd("10"));
    }

    @Test
    void externalProductionCommitmentUsesThePhysicalPoolBeforeCurrentProduction() {
        UUID itemId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID sharedMaterial = UUID.randomUUID();
        MaterialAnalysisService.SourceLine source = allocationSource(
                itemId, UUID.randomUUID(), unitId, 0, "1");
        MaterialAnalysisService.BomNode startGate = bomNode(
                itemId, sharedMaterial, unitId, "start-gate", "1",
                "START", "PER_UNIT", "1", "1", true);

        MaterialAnalysisService.StagePlan stages =
                MaterialAnalysisService.allocateNestedStages(
                        List.of(source), Map.of(itemId, List.of(startGate)),
                        Map.of(startGate.dimension(), bd("1")),
                        Map.of(startGate.dimension(), bd("1")));

        assertThat(stages.finish().readyByItem().get(itemId))
                .isEqualByComparingTo("0.0000");
        assertThat(stages.ship().readyByItem().get(itemId))
                .isEqualByComparingTo("0.0000");
        assertThat(stages.start().readyByItem().get(itemId))
                .isEqualByComparingTo("0.0000");
        assertThat(stages.finish().nodeAllocations().values())
                .allSatisfy(allocation -> assertThat(allocation.allocatedQty())
                        .isEqualByComparingTo("0.0000"));
    }

    @Test
    void softCommitmentSqlForA6B4CNetsByBeneficiaryWithoutOwnerDoubleCount() {
        UUID thirdAnalysisId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        MaterialAnalysisService.MaterialDimension dimension =
                new MaterialAnalysisService.MaterialDimension(
                        goodsId, null, unitId);
        Query query = query(List.<Object[]>of(new Object[]{
                goodsId, null, unitId, BigDecimal.ZERO
        }));
        List<String> statements = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0, String.class));
            return query;
        });
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));

        // SQL contract only; dynamic A/B/C quantities remain a PostgreSQL gate.
        invokePrivate(
                        service, "softCommittedStock",
                        new Class<?>[]{
                                UUID.class, UUID.class, Set.class, Set.class
                        },
                        thirdAnalysisId, warehouseId,
                        Set.of(dimension), Set.of("START"));

        assertThat(statements).hasSize(1);
        String nettingSql = statements.getFirst()
                .replaceAll("\\s+", " ");
        assertThat(nettingSql)
                .contains("preplan_stock_entitlement_events tracked")
                .contains(
                        "v_preplan_stock_entitlement_beneficiary_balance")
                .contains(
                        "balance.beneficiary_analysis_id = c.claim_analysis_id")
                .contains("WHEN r.owner_id = c.claim_analysis_id")
                .contains("r.warehouse_id = :warehouseId")
                .doesNotContain(
                        "AND r.owner_id = c.claim_analysis_id AND r.goods_id");
        verify(query).setParameter("warehouseId", warehouseId);
    }

    @Test
    void planExecutionProgressRatioClampsAndUsesFourDecimalScale() {
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                bd("10"), bd("4"))).isEqualByComparingTo("0.4000");
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                bd("10"), null)).isEqualByComparingTo("0.0000");
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                bd("10"), bd("-1"))).isEqualByComparingTo("0.0000");
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                bd("10"), bd("12"))).isEqualByComparingTo("1.0000");
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                BigDecimal.ZERO, bd("1"))).isNull();
        assertThat(MaterialAnalysisService.planExecutionProgressRatio(
                null, bd("1"))).isNull();
    }

    @Test
    void planExecutionProjectionPreaggregatesItemsAndSegmentsBeforeSumming()
            throws Exception {
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        Query query = query(List.<Object[]>of(new Object[]{
                analysisItemId, planId, "PP-001", "IN_PROGRESS",
                bd("10"), bd("4")
        }));
        List<String> statements = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0, String.class));
            return query;
        });
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));

        Map<UUID, MaterialAnalysisService.ProductPlanState> projections =
                invokePrivate(service, "productPlanStates",
                        new Class<?>[]{UUID.class}, analysisId);

        MaterialAnalysisService.ProductPlanState projection =
                projections.get(analysisItemId);
        assertThat(projection.status()).isEqualTo("IN_PROGRESS");
        assertThat(projection.planId()).isEqualTo(planId);
        assertThat(projection.plannedQty()).isEqualByComparingTo("10");
        assertThat(projection.inboundQty()).isEqualByComparingTo("4");
        assertThat(projection.progressRatio()).isEqualByComparingTo("0.4000");

        String sql = statements.getFirst().replaceAll("\\s+", " ");
        assertThat(sql)
                .contains("WITH active_links AS")
                .contains("plan_ids AS")
                .contains("SELECT DISTINCT plan_id")
                .contains("item_rollup AS")
                .contains("segment_rollup AS")
                .contains("FILTER (WHERE link.approved AND plan.status = 1)");
        verify(query).setParameter("analysisId", analysisId);
    }

    @Test
    void currentEffectiveSqlAndProjectionIgnoreFormalizeRestoreButCountTargetRelease()
            throws Exception {
        UUID analysisId = UUID.randomUUID();
        UUID sourceAnalysisId = UUID.randomUUID();
        UUID sourceMaterialId = UUID.randomUUID();
        UUID formalizedMaterialId = UUID.randomUUID();
        UUID restoredMaterialId = UUID.randomUUID();
        UUID releasedMaterialId = UUID.randomUUID();
        java.util.function.BiFunction<UUID, BigDecimal, Object[]> row =
                (targetMaterialId, currentEffective) -> new Object[]{
                        UUID.randomUUID(),
                        sourceAnalysisId, sourceMaterialId,
                        analysisId, targetMaterialId,
                        new BigDecimal("4"), new BigDecimal("4"),
                        "FULFILLED", "让料",
                        3L, "a".repeat(64),
                        7L, "b".repeat(64),
                        "SRC-A", "P-A", "产品A",
                        "SRC-B", "P-B", "产品B",
                        false, currentEffective
                };
        Object[] formalized = row.apply(
                formalizedMaterialId, new BigDecimal("4"));
        formalized[19] = true;
        Object[] restored = row.apply(
                restoredMaterialId, new BigDecimal("4"));
        Object[] targetReleased = row.apply(
                releasedMaterialId, BigDecimal.ZERO);
        targetReleased[7] = "CANCELLED";

        Query headers = query(List.of(
                formalized, restored, targetReleased));
        Query replenishments = query(List.of());
        List<String> statements = new ArrayList<>();
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0, String.class));
            return statements.size() == 1 ? headers : replenishments;
        });
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));

        // Pure projection mapping: row[20] mocks the SQL expression output.
        // The SQL assertions below are static evidence, not a PostgreSQL quantity proof.
        Map<UUID, ?> projections = invokePrivate(
                service, "crossReallocationProjections",
                new Class<?>[]{UUID.class}, analysisId);
        Object formalizedProjection = projections.get(formalizedMaterialId);
        Method incoming = formalizedProjection.getClass()
                .getDeclaredMethod("incomingQty");
        incoming.setAccessible(true);

        assertThat((BigDecimal) incoming.invoke(formalizedProjection))
                .as("FORMALIZE does not consume target entitlement")
                .isEqualByComparingTo("4");
        assertThat((BigDecimal) incoming.invoke(
                projections.get(restoredMaterialId)))
                .as("RESTORE keeps target entitlement")
                .isEqualByComparingTo("4");
        assertThat((BigDecimal) incoming.invoke(
                projections.get(releasedMaterialId)))
                .as("target beneficiary RELEASE removes entitlement")
                .isEqualByComparingTo("0");

        String projectionSql = statements.getFirst()
                .replaceAll("\\s+", " ");
        int currentStart = projectionSql.indexOf(
                "GREATEST(reallocation.qty - COALESCE((");
        int currentEnd = projectionSql.indexOf(
                "AS current_effective_qty", currentStart);
        String currentSql = projectionSql.substring(
                currentStart, currentEnd);
        assertThat(currentSql)
                .contains("released_event.event_type = 'RELEASE'")
                .contains(
                        "released_event.beneficiary_analysis_id = reallocation.to_analysis_id")
                .contains(
                        "released_event.beneficiary_analysis_material_id = reallocation.to_analysis_material_id")
                .doesNotContain("FORMALIZE")
                .doesNotContain("RESTORE");
    }

    @Test
    void softCommitmentsExcludeShippingAndReferenceStages() {
        EntityManager em = mock(EntityManager.class);
        Query query = query(List.of());
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            statements.add(invocation.getArgument(0));
            return query;
        });
        MaterialAnalysisService service = service(
                em, mock(ProductionDocumentAccessPolicy.class));
        UUID goodsId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        Set<String> requestedStages = Set.of(
                "START", "ASSEMBLY", "FINISH", "SHIP", "REFERENCE");
        Set<String> productionStages = Set.of("START", "ASSEMBLY", "FINISH");

        invokePrivate(service, "softCommittedStock",
                new Class<?>[]{UUID.class, UUID.class, Set.class, Set.class},
                UUID.randomUUID(), UUID.randomUUID(),
                Set.of(new MaterialAnalysisService.MaterialDimension(
                        goodsId, null, unitId)), requestedStages);

        assertThat(statements).singleElement().satisfies(statement -> {
            assertThat(statement).contains(
                    "material.hard_gate = TRUE",
                    "material.control_stage IN (:includedStages)",
                    "fn_material_analysis_edge_required(",
                    "link.id AS link_id",
                    "draft.submitted_qty",
                    "* material.parent_per_product_qty");
            assertThat(statement).doesNotContain("SUM(link.submitted_qty)");
        });
        verify(query).setParameter("includedStages", productionStages);
        assertThat(MaterialAnalysisService.HARD_COMMITMENT_STAGES)
                .containsExactlyInAnyOrderElementsOf(productionStages)
                .doesNotContain("SHIP", "REFERENCE");
    }

    private static MaterialAnalysisService service(
            EntityManager em, ProductionDocumentAccessPolicy access) {
        return new MaterialAnalysisService(
                em, mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class),
                access, mock(com.uten.imp.application.port.SubcontractPreparationPort.class));
    }

    private static MaterialAnalysisService.SourceLine allocationSource(
            UUID itemId, UUID goodsId, UUID unitId, int priority, String demand) {
        return allocationSource(
                itemId, goodsId, unitId, priority, demand, "0", "0");
    }

    private static MaterialAnalysisService.SourceLine allocationSource(
            UUID itemId, UUID goodsId, UUID unitId, int priority,
            String requested, String submitted, String approved) {
        Object[] row = sourceRow(itemId, goodsId, unitId);
        row[17] = bd(requested);
        row[18] = bd(submitted);
        row[19] = bd(approved);
        row[35] = priority;
        return MaterialAnalysisService.SourceLine.from(row);
    }

    private static MaterialAnalysisService.BomNode bomNode(
            UUID analysisItemId, UUID goodsId, UUID unitId, String nodeKey,
            String snapshotRequired, String stage, String basis, String bomQty,
            String basisOutputQty, boolean allowPartialPackage) {
        return new MaterialAnalysisService.BomNode(
                analysisItemId, UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, unitId, 1, nodeKey, null,
                BigDecimal.ONE, bd(bomQty), BigDecimal.ONE,
                bd(snapshotRequired), "M-" + nodeKey, nodeKey, null,
                null, "piece", BigDecimal.ZERO, "BUY", false,
                stage, basis, bd(basisOutputQty), allowPartialPackage, true);
    }

    private static MaterialAnalysisService.BomNode diagnosticNode(
            UUID analysisItemId, UUID goodsId, UUID unitId,
            String nodeKey, String parentNodeKey, int depth,
            String snapshotRequired, String bomQty,
            String suggestion, boolean hasChildren) {
        return diagnosticNode(
                analysisItemId, goodsId, unitId, nodeKey, parentNodeKey, depth,
                snapshotRequired, bomQty, suggestion, hasChildren, "START", true);
    }

    private static MaterialAnalysisService.BomNode diagnosticNode(
            UUID analysisItemId, UUID goodsId, UUID unitId,
            String nodeKey, String parentNodeKey, int depth,
            String snapshotRequired, String bomQty,
            String suggestion, boolean hasChildren,
            String controlStage, boolean hardGate) {
        return new MaterialAnalysisService.BomNode(
                analysisItemId, UUID.randomUUID(), UUID.randomUUID(),
                goodsId, null, unitId, depth, nodeKey, parentNodeKey,
                BigDecimal.ONE, bd(bomQty), BigDecimal.ONE,
                bd(snapshotRequired), "M-" + nodeKey, nodeKey, null,
                null, "piece", BigDecimal.ZERO, suggestion, hasChildren,
                controlStage, "PER_UNIT", BigDecimal.ONE, true, hardGate);
    }

    private static MaterialAnalysisService.BomNode node(
            MaterialAnalysisService.NestedDiagnosticPlan plan, String nodeKey) {
        return plan.nodes().stream()
                .filter(node -> node.nodeKey().equals(nodeKey))
                .findFirst().orElseThrow();
    }

    private static PreviewItem manualItem(String sourceRef) {
        return new PreviewItem(
                "OTHER", null, UUID.fromString("10000000-0000-0000-0000-000000000001"),
                null, UUID.fromString("20000000-0000-0000-0000-000000000001"),
                sourceRef, "manual production demand", LocalDate.of(2026, 8, 20),
                bd("100"));
    }

    private static Object[] sourceRow(UUID itemId, UUID goodsId, UUID unitId) {
        return new Object[]{
                itemId, "OTHER", null, null, null, null,
                LocalDate.of(2026, 8, 20), null,
                goodsId, "FG-01", "Finished good", null, null, null,
                unitId, "piece", BigDecimal.ONE, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, null, false, false, false, false,
                "REQ-BOM-001", "BOM signature test", 1, bd("10"), bd("10"),
                bd("10"), bd("10"), bd("10"),
                null, null,
                // V294：SourceLine 新增 orderFinanceConfirmed（row[43]），
                // 测试夹具默认财务已确认，不改变既有用例语义。
                true
        };
    }

    private static MaterialView material(
            UUID materialId, boolean routeConfirmed, String confirmedRoute) {
        return material(materialId, "group-1", routeConfirmed, confirmedRoute);
    }

    private static MaterialView material(
            UUID materialId, String groupKey,
            boolean routeConfirmed, String confirmedRoute) {
        UUID itemId = UUID.randomUUID();
        return new MaterialView(
                materialId, itemId, "node-1", groupKey, "material-1",
                UUID.randomUUID(), "M-01", "Material", null, null, null,
                UUID.randomUUID(), "piece", 1, List.of("Material"), null, null, null,
                "START", "PER_UNIT", BigDecimal.ONE, true, true,
                BigDecimal.ONE, BigDecimal.ONE,
                BigDecimal.ONE, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, bd("90"), bd("90"),
                BigDecimal.ZERO, null,
                "BUY", confirmedRoute, routeConfirmed, null,
                true, false, REQUIREMENT_STATE_ACTIVE,
                null, null, null,
                BigDecimal.ZERO, BigDecimal.ZERO, List.of(),
                List.of(),
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                List.of(), List.of(), List.of());
    }

    private static MaterialAnalysisService.MaterialRow materialRow(
            UUID analysisItemId, UUID goodsId, UUID unitId, String path) {
        return materialRow(analysisItemId, goodsId, unitId, path, 2, bd("10"));
    }

    private static MaterialAnalysisService.MaterialRow materialRow(
            UUID analysisItemId, UUID goodsId, UUID unitId, String path,
            int depth, BigDecimal shortage) {
        return new MaterialAnalysisService.MaterialRow(
                UUID.randomUUID(), analysisItemId, path, goodsId, "M-01",
                "Shared material", null, null, null, unitId, "piece",
                depth, path, "parent", UUID.randomUUID(), "START", "PER_UNIT",
                BigDecimal.ONE, true, true, BigDecimal.ONE, BigDecimal.ONE,
                BigDecimal.ONE, bd("10"), BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, shortage, null,
                "BUY", "BUY", null,
                false);
    }

    private static MaterialAnalysisService.MaterialRow requirementRow(
            UUID analysisItemId, String nodeKey, String parentNodeKey, int depth,
            String required, String shortage, String suggestion,
            String confirmedRoute, String controlStage) {
        return requirementRow(
                analysisItemId, nodeKey, parentNodeKey, depth,
                required, shortage, suggestion, confirmedRoute, controlStage,
                UUID.randomUUID());
    }

    private static MaterialAnalysisService.MaterialRow requirementRow(
            UUID analysisItemId, String nodeKey, String parentNodeKey, int depth,
            String required, String shortage, String suggestion,
            String confirmedRoute, String controlStage, UUID goodsId) {
        return new MaterialAnalysisService.MaterialRow(
                UUID.randomUUID(), analysisItemId, nodeKey,
                goodsId, "M-" + nodeKey, nodeKey, null,
                null, null, UUID.randomUUID(), "piece", depth, nodeKey,
                parentNodeKey, null, controlStage, "PER_UNIT", BigDecimal.ONE,
                true, true, BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ONE,
                bd(required), BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, bd(shortage), null,
                suggestion, confirmedRoute, null, false);
    }

    private static Query query(List<?> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        org.mockito.Mockito.doReturn(rows).when(query).getResultList();
        return query;
    }

    private static Query queryWithSingleResult(Object value) {
        Query query = query(List.of());
        when(query.getSingleResult()).thenReturn(value);
        return query;
    }

    @SuppressWarnings("unchecked")
    private static <T> T invokePrivate(
            Object target, String methodName, Class<?>[] parameterTypes, Object... arguments) {
        try {
            Method method = target.getClass().getDeclaredMethod(methodName, parameterTypes);
            method.setAccessible(true);
            return (T) method.invoke(target, arguments);
        } catch (InvocationTargetException error) {
            if (error.getCause() instanceof RuntimeException runtime) {
                throw runtime;
            }
            throw new AssertionError(error.getCause());
        } catch (ReflectiveOperationException error) {
            throw new AssertionError(error);
        }
    }

    private static GeneratePlanRequest generateRequest(
            UUID analysisLineId, UUID warehouseId, String productNo) {
        PlanQuantity item = new PlanQuantity(
                analysisLineId, bd("5"), null, null, null, null, null, null,
                productNo);
        return new GeneratePlanRequest(
                3L, "a".repeat(64), "b".repeat(64), "product-no-0001",
                warehouseId, LocalDate.of(2026, 8, 14), null, null, null, null,
                false, List.of(item), List.of());
    }

    private static String generateHash(UUID analysisId, GeneratePlanRequest request) {
        try {
            Method method = MaterialAnalysisCommandService.class.getDeclaredMethod(
                    "generateHash", UUID.class, GeneratePlanRequest.class);
            method.setAccessible(true);
            return (String) method.invoke(null, analysisId, request);
        } catch (InvocationTargetException error) {
            throw new AssertionError(error.getCause());
        } catch (ReflectiveOperationException error) {
            throw new AssertionError(error);
        }
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
