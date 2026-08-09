package com.uten.imp.features.production.analysis;

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
    void manualSourceRequiresAStableReference() {
        MaterialAnalysisService service = service(mock(EntityManager.class),
                mock(ProductionDocumentAccessPolicy.class));
        PreviewItem missingReference = manualItem("   ");

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                service, "normalizePreviewItems", new Class<?>[]{List.class},
                List.of(missingReference)));

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
                List.of(), List.of(), List.of());
        NotifyRequest request = new NotifyRequest(
                1L, "a".repeat(64), "notify-0001", null,
                List.of(materialId), List.of());

        ApiException error = assertThrows(ApiException.class, () -> invokePrivate(
                commands, "selectedGroups",
                new Class<?>[]{AnalysisView.class, NotifyRequest.class}, view, request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
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
                List.of(item), List.of(), List.of());

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
                em, mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class), access);
    }

    private static MaterialAnalysisService.SourceLine allocationSource(
            UUID itemId, UUID goodsId, UUID unitId, int priority, String demand) {
        Object[] row = sourceRow(itemId, goodsId, unitId);
        row[17] = bd(demand);
        row[37] = priority;
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
                BigDecimal.ZERO, "BOM_REQUIRED", true, bd("100"), BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, null, false, false, false, false,
                "REQ-BOM-001", "BOM signature test", 1, bd("10"), bd("10"),
                bd("10"), bd("10"), bd("10")
        };
    }

    private static MaterialView material(
            UUID materialId, boolean routeConfirmed, String confirmedRoute) {
        UUID itemId = UUID.randomUUID();
        return new MaterialView(
                materialId, itemId, "node-1", "group-1", "material-1",
                UUID.randomUUID(), "M-01", "Material", null, null, null,
                UUID.randomUUID(), "piece", 1, List.of("Material"), null, null, null,
                "START", "PER_UNIT", BigDecimal.ONE, true, true,
                BigDecimal.ONE, BigDecimal.ONE,
                BigDecimal.ONE, bd("100"), BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, bd("90"), null,
                "BUY", confirmedRoute, routeConfirmed, null, "BOM_REQUIRED", false,
                true, false, List.of(), List.of(), List.of());
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

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
