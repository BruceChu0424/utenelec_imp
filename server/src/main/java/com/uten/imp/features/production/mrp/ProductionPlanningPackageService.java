package com.uten.imp.features.production.mrp;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegmentRepository;
import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Atomic production planning-package command service.
 *
 * <p>Lock order: parent plan/package, purchase source headers/items, inventory
 * dimensions, then demand/allocation rows. Matching goods never implies an
 * allocation: only persisted stock reservations and supply pegs do.
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanningPackageService {

    private final EntityManager em;
    private final ProductionExecutionPackageCommandService executionCommand;
    private final MrpService mrpService;
    private final ProductionExecutionPlanningService executionPlanning;
    private final ProductionFulfillmentLedgerService ledger;
    private final ProductionExecutionSegmentRepository executionSegmentRepo;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionPurchaseRequestFacade purchaseFacade;
    private final ProductionSubcontractRequestPort subcontractRequests;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.features.stock.StockDocumentRepository stockDocumentRepo;
    private final com.uten.imp.features.stock.StockDocumentItemRepository stockDocumentItemRepo;
    private final com.uten.imp.common.docnumber.DocNumberService docNumberService;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PlanningPreviewResult preview(UUID planId, UUID warehouseId) {
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "必须选择目标仓库");
        }
        requireWarehouse(warehouseId);
        List<MrpRow> rows = mrpService.preview(planId);
        ProductionExecutionPlanningService.Snapshot snapshot =
                executionPlanning.preview(planId, warehouseId);
        CompleteKitAllocator.Allocation proposal =
                executionPlanning.propose(snapshot);
        Map<MaterialKey, BigDecimal> targetWarehouseAvailable =
                warehouseAvailability(warehouseId, rows);
        return new PlanningPreviewResult(
                planId,
                warehouseId,
                snapshot.fingerprint(),
                rows,
                targetWarehouseMaterials(rows, targetWarehouseAvailable),
                isBalancedKitCoverage(rows, targetWarehouseAvailable),
                true,
                executionPlanning.toPreview(proposal));
    }

    @Transactional
    public PlanningPackageResult confirm(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        tx.bind();
        return executionCommand.confirm(planId, request);
    }

    @SuppressWarnings("unused")
    private PlanningPackageResult confirmLegacy(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        PlanHeader plan = lockPlan(planId);
        validateRequest(request);
        List<MrpRow> initialRows = mrpService.packageRows(planId);
        if (initialRows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "计划没有可持久化的 BOM 物料需求");
        }

        String requestHash = requestHash(request);
        ProductionFulfillmentLedgerService.BeginConfirmation begin =
                ledger.beginConfirmation(
                        planId,
                        request.getWarehouseId(),
                        request.getIdempotencyKey(),
                        requestHash,
                        request.getPreviewFingerprint());
        if (begin.replayed()) {
            return replay(begin.planningPackage());
        }

        List<ProductionPurchaseRequestFacade.MaterialDimension> purchaseDimensions =
                initialRows.stream()
                        .map(row -> new ProductionPurchaseRequestFacade.MaterialDimension(
                                row.goodsId(), row.colorId()))
                        .distinct()
                        .sorted()
                        .toList();
        purchaseFacade.lockOpenSupply(purchaseDimensions);
        stockAllocation.lockMaterialDimensions(initialRows.stream()
                .map(row -> new ProductionMaterialAllocationFacade.MaterialDimension(
                        row.goodsId(), row.colorId()))
                .toList());

        List<MrpRow> lockedRows = mrpService.packageRows(planId);
        String actualFingerprint =
                fingerprint(planId, request.getWarehouseId(), lockedRows);
        if (!actualFingerprint.equalsIgnoreCase(request.getPreviewFingerprint())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "排产预览已过期：库存、在途或 BOM 已变化，请刷新后重新确认");
        }

        Map<MaterialKey, String> routes = routeMap(request, lockedRows);
        List<ProductionFulfillmentLedgerService.DemandDraft> drafts =
                lockedRows.stream()
                        .map(row -> new ProductionFulfillmentLedgerService.DemandDraft(
                                row.goodsId(),
                                row.colorId(),
                                row.unitId(),
                                row.gross(),
                                row.needDate(),
                                routes.get(new MaterialKey(row.goodsId(), row.colorId())),
                                stableMaterialKey(row)))
                        .toList();
        List<ProductionMaterialDemand> demands =
                ledger.createDemands(begin.planningPackage(), drafts);
        Map<MaterialKey, ProductionMaterialDemand> demandByMaterial =
                demands.stream().collect(Collectors.toMap(
                        demand -> new MaterialKey(
                                demand.getGoodsId(), demand.getColorId()),
                        demand -> demand));

        List<GenerateSubplansRequest.Created> subplans = List.of();

        List<ProductionMaterialAllocationFacade.AllocationRequest> allocations =
                demands.stream()
                        .map(demand -> new ProductionMaterialAllocationFacade.AllocationRequest(
                                begin.planningPackage().getId(),
                                demand.getId(),
                                demand.getGoodsId(),
                                demand.getColorId(),
                                request.getWarehouseId(),
                                demand.getRequiredQty(),
                                begin.planningPackage().getId() + ":STOCK:" + demand.getId(),
                                currentUser.requireId()))
                        .toList();
        Map<UUID, BigDecimal> allocatedByDemand = stockAllocation.allocate(allocations)
                .stream()
                .collect(Collectors.toMap(
                        ProductionMaterialAllocationFacade.AllocationResult::demandId,
                        ProductionMaterialAllocationFacade.AllocationResult::allocatedQty));
        requireBalancedKitCoverage(demands, allocatedByDemand);
        MrpGenerateResult drawResult = createDraw(
                plan,
                begin.planningPackage(),
                demands,
                allocatedByDemand);


        MrpGenerateResult purchaseResult = null;
        if (request.isGeneratePurchaseRequest()) {
            List<ProductionPurchaseRequestFacade.DraftLine> purchaseLines =
                    lockedRows.stream()
                            .filter(row -> ProductionMaterialDemand.ROUTE_BUY.equals(
                                    routes.get(new MaterialKey(row.goodsId(), row.colorId()))))
                            .map(row -> {
                                ProductionMaterialDemand demand = demandByMaterial.get(
                                        new MaterialKey(row.goodsId(), row.colorId()));
                                BigDecimal uncovered = demand.getRequiredQty()
                                        .subtract(allocatedByDemand.getOrDefault(
                                                demand.getId(), BigDecimal.ZERO));
                                return new ProductionPurchaseRequestFacade.DraftLine(
                                        demand.getId(),
                                        row.goodsId(),
                                        row.colorId(),
                                        row.unitId(),
                                        uncovered,
                                        row.needDate(),
                                        "计划包 " + begin.planningPackage().getId());
                            })
                            .filter(line -> line.qty().signum() > 0)
                            .toList();
            ProductionPurchaseRequestFacade.DraftResult purchase =
                    purchaseFacade.createProductionDraft(
                            plan.billNo(),
                            plan.deliveryDate(),
                            request.getWarehouseId(),
                            purchaseLines,
                            currentUser.requireId(),
                            currentUser.requireEmployeeId());
            if (purchase != null) {
                ledger.attachPurchaseRequest(
                        begin.planningPackage(), purchase.requestId());
                ledger.recordDocument(
                        begin.planningPackage().getId(),
                        "PURCHASE_REQUEST",
                        purchase.requestId(),
                        purchase.billNo(),
                        currentUser.requireId());
                for (ProductionPurchaseRequestFacade.DraftLineResult line : purchase.lines()) {
                    ledger.createSupplyPeg(
                            demands.stream()
                                    .filter(demand -> demand.getId().equals(line.demandId()))
                                    .findFirst()
                                    .orElseThrow(),
                            "PURCHASE_REQUEST_ITEM",
                            line.requestItemId(),
                            line.qty(),
                            line.expectedDate());
                }
                purchaseResult = new MrpGenerateResult(
                        purchase.requestId(),
                        purchase.billNo(),
                        purchase.lines().size(),
                        List.of());
            }
        }
        ledger.refreshDemandStatuses(
                demands.stream().map(ProductionMaterialDemand::getId).toList());
        return new PlanningPackageResult(
                begin.planningPackage().getId(),
                begin.planningPackage().getStatus(),
                false,
                subplans,
                purchaseResult,
                drawResult);
    }

    private MrpGenerateResult createDraw(
            PlanHeader plan,
            ProductionPlanningPackage planningPackage,
            List<ProductionMaterialDemand> demands,
            Map<UUID, BigDecimal> allocatedByDemand) {
        List<ProductionMaterialDemand> allocated = demands.stream()
                .filter(demand -> allocatedByDemand
                        .getOrDefault(demand.getId(), BigDecimal.ZERO)
                        .signum() > 0)
                .sorted(java.util.Comparator
                        .comparing(ProductionMaterialDemand::getGoodsId)
                        .thenComparing(demand -> Objects.toString(
                                demand.getColorId(), "")))
                .toList();
        if (allocated.isEmpty()) {
            return null;
        }

        com.uten.imp.features.stock.StockDocument document =
                new com.uten.imp.features.stock.StockDocument();
        document.setDocType("DRAW");
        document.setBillNo(docNumberService.nextNumber(
                com.uten.imp.common.docnumber.DocNumberPrefix.STOCK_DRAW));
        document.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        document.setWarehouseId(planningPackage.getWarehouseId());
        document.setPlanNo(plan.billNo());
        document.setSourceDocNo(plan.billNo());
        document.setRemark("计划包 " + planningPackage.getId() + " 自动备料");
        document.setWorkerId(currentUser.requireId());
        document.setMakerId(currentUser.requireEmployeeId());
        document.setStatus((short) 0);
        stockDocumentRepo.save(document);

        int lineNo = 0;
        for (ProductionMaterialDemand demand : allocated) {
            lineNo++;
            BigDecimal qty = allocatedByDemand.get(demand.getId());
            com.uten.imp.features.stock.StockDocumentItem item =
                    new com.uten.imp.features.stock.StockDocumentItem();
            item.setDocId(document.getId());
            item.setBillType("DRAW");
            item.setBillNo(document.getBillNo());
            item.setBillDate(document.getBillDate());
            item.setLineNo(lineNo);
            item.setGoodsId(demand.getGoodsId());
            item.setColorId(demand.getColorId());
            item.setUnitId(demand.getUnitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(qty);
            item.setBaseQty(qty);
            item.setSourceDocNo(plan.billNo());
            item.setRemark("需求 " + demand.getId());
            stockDocumentItemRepo.save(item);
            em.createNativeQuery("""
                            INSERT INTO production_planning_package_document_items (
                                package_id, demand_id, document_type,
                                document_id, document_item_id, created_by
                            ) VALUES (
                                :packageId, :demandId, 'DRAW',
                                :documentId, :itemId, :actorId
                            )
                            """)
                    .setParameter("packageId", planningPackage.getId())
                    .setParameter("demandId", demand.getId())
                    .setParameter("documentId", document.getId())
                    .setParameter("itemId", item.getId())
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        stockDocumentItemRepo.flush();
        stockDocumentRepo.flush();
        ledger.recordDocument(
                planningPackage.getId(),
                "DRAW",
                document.getId(),
                document.getBillNo(),
                currentUser.requireId());
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(plan_id, draw_id, created_by)
                        VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", planningPackage.getPlanId())
                .setParameter("drawId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return new MrpGenerateResult(
                document.getId(),
                document.getBillNo(),
                lineNo,
                List.of());
    }

    @Transactional
    public PlanningPackageLifecycleResult cancel(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request) {
        tx.bind();
        return lifecycle(
                planId,
                packageId,
                request,
                ProductionFulfillmentLedgerService.LifecycleAction.CANCEL);
    }

    @Transactional
    public PlanningPackageLifecycleResult reverse(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request) {
        tx.bind();
        return lifecycle(
                planId,
                packageId,
                request,
                ProductionFulfillmentLedgerService.LifecycleAction.REVERSE);
    }

    private PlanningPackageLifecycleResult lifecycle(
            UUID planId,
            UUID packageId,
            PlanningPackageLifecycleRequest request,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "缺少计划包生命周期请求");
        }
        lockPlan(planId);
        ProductionFulfillmentLedgerService.LifecycleHandle handle =
                ledger.lockForLifecycle(
                        planId, packageId, action, request.idempotencyKey());
        if (handle.replayed()) {
            return new PlanningPackageLifecycleResult(
                    packageId, handle.planningPackage().getStatus(), true);
        }
        List<ProductionFulfillmentLedgerService.PackageDocument> documents =
                ledger.lockPackageDocuments(packageId);

        ProductionFulfillmentLedgerService.PackageDocument purchase = documents.stream()
                .filter(document -> "PURCHASE_REQUEST".equals(document.documentType()))
                .findFirst()
                .orElse(null);
        if (purchase != null) {
            purchaseFacade.cancelGeneratedDraft(
                    purchase.documentId(),
                    action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL
                            ? ProductionPurchaseRequestFacade.LifecycleAction.CANCEL
                            : ProductionPurchaseRequestFacade.LifecycleAction.REVERSE);
        }
        ProductionFulfillmentLedgerService.PackageDocument subcontract =
                documents.stream()
                        .filter(document ->
                                "SUBCONTRACT_APPLICATION".equals(
                                        document.documentType()))
                        .findFirst()
                        .orElse(null);
        if (subcontract != null) {
            subcontractRequests.closeGeneratedDraft(
                    subcontract.documentId(),
                    action == ProductionFulfillmentLedgerService
                                    .LifecycleAction.CANCEL
                            ? ProductionSubcontractRequestPort
                                    .LifecycleAction.CANCEL
                            : ProductionSubcontractRequestPort
                                    .LifecycleAction.REVERSE);
        }
        closeExecutionSegments(packageId, action);
        closeSubplans(documents, action);
        closeDraw(documents, action);
        ledger.releaseLocked(
                handle, action, request.idempotencyKey(), request.reason());
        return new PlanningPackageLifecycleResult(
                packageId, handle.planningPackage().getStatus(), false);
    }

    private void closeExecutionSegments(
            UUID packageId,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status
                                FROM production_execution_segments
                                WHERE package_id = :packageId
                                  AND is_deleted = FALSE
                                ORDER BY id
                                FOR UPDATE
                                """)
                        .setParameter("packageId", packageId));
        if (rows.isEmpty()) {
            return;
        }
        if (rows.stream().anyMatch(row ->
                !Set.of(
                                ProductionExecutionSegment.STATUS_READY,
                                ProductionExecutionSegment.STATUS_WAITING)
                        .contains((String) row[1]))) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Only unstarted READY/WAITING segments can be closed with a package");
        }
        int updated = em.createNativeQuery("""
                        UPDATE production_execution_segments
                        SET status = :status,
                            updated_at = now(),
                            updated_by = :actorId
                        WHERE package_id = :packageId
                          AND is_deleted = FALSE
                          AND status IN ('READY', 'WAITING')
                        """)
                .setParameter(
                        "status",
                        action == ProductionFulfillmentLedgerService
                                        .LifecycleAction.CANCEL
                                ? ProductionExecutionSegment.STATUS_CANCELLED
                                : ProductionExecutionSegment.STATUS_REVERSED)
                .setParameter("actorId", currentUser.requireId())
                .setParameter("packageId", packageId)
                .executeUpdate();
        if (updated != rows.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "Execution segment changed concurrently");
        }
    }

    private void closeDraw(
            List<ProductionFulfillmentLedgerService.PackageDocument> documents,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        List<UUID> ids = documents.stream()
                .filter(document -> "DRAW".equals(document.documentType()))
                .map(ProductionFulfillmentLedgerService.PackageDocument::documentId)
                .sorted()
                .toList();
        for (UUID id : ids) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT status, is_deleted
                                    FROM stock_documents
                                    WHERE id = :id AND doc_type = 'DRAW'
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            @SuppressWarnings("unchecked")
            List<Object> issueRows = em.createNativeQuery("""
                            SELECT issued_qty
                            FROM stock_document_items
                            WHERE doc_id = :id
                            ORDER BY id
                            FOR UPDATE
                            """)
                    .setParameter("id", id)
                    .getResultList();
            BigDecimal issuedQty = issueRows.stream()
                    .map(ProductionPlanningPackageService::decimal)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (rows.isEmpty()
                    || Boolean.TRUE.equals(rows.getFirst()[1])
                    || ((Number) rows.getFirst()[0]).shortValue() != 0
                    || issuedQty.signum() > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "备料单已审核、发料或删除，必须先完成退料/红冲链路");
            }
            ledger.authorizeDraftDrawCleanup(id);
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL) {
                em.createNativeQuery("""
                                UPDATE stock_documents
                                SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            } else {
                em.createNativeQuery("""
                                UPDATE stock_documents
                                SET status = -1, updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            }
            em.createNativeQuery("""
                            UPDATE plan_draw_links
                            SET is_deleted = TRUE, deleted_at = now()
                            WHERE draw_id = :id AND is_deleted = FALSE
                            """)
                    .setParameter("id", id)
                    .executeUpdate();
        }
    }

    private void closeSubplans(
            List<ProductionFulfillmentLedgerService.PackageDocument> documents,
            ProductionFulfillmentLedgerService.LifecycleAction action) {
        List<UUID> ids = documents.stream()
                .filter(document -> "SUBPLAN".equals(document.documentType()))
                .map(ProductionFulfillmentLedgerService.PackageDocument::documentId)
                .sorted()
                .toList();
        for (UUID id : ids) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT status, is_deleted
                                    FROM production_plans
                                    WHERE id = :id
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            if (rows.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "计划包子计划不存在");
            }
            Object[] row = rows.getFirst();
            short status = ((Number) row[0]).shortValue();
            List<Object[]> itemRows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT fqty, iqty
                                    FROM production_plan_items
                                    WHERE plan_id = :id AND is_deleted = FALSE
                                    ORDER BY id
                                    FOR UPDATE
                                    """)
                            .setParameter("id", id));
            BigDecimal finishedQty = itemRows.stream()
                    .map(item -> decimal(item[0]))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal inboundQty = itemRows.stream()
                    .map(item -> decimal(item[1]))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (Boolean.TRUE.equals(row[1])
                    || finishedQty.signum() > 0
                    || inboundQty.signum() > 0
                    || hasActiveSubplanDownstream(id)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "子计划已有执行或下游单据，必须先完成反向链路");
            }
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL
                    && status != 0) {
                throw new ApiException(ErrorCode.CONFLICT, "仅草稿子计划可随计划包取消");
            }
            if (action == ProductionFulfillmentLedgerService.LifecycleAction.CANCEL) {
                em.createNativeQuery("""
                                UPDATE production_plans
                                SET is_deleted = TRUE, deleted_at = now(), updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            } else {
                em.createNativeQuery("""
                                UPDATE production_plans
                                SET status = -1, updated_at = now()
                                WHERE id = :id
                                """)
                        .setParameter("id", id)
                        .executeUpdate();
            }
            em.createNativeQuery("""
                            UPDATE subplan_links
                            SET is_deleted = TRUE, deleted_at = now()
                            WHERE subplan_id = :id AND is_deleted = FALSE
                            """)
                    .setParameter("id", id)
                    .executeUpdate();
        }
    }

    private boolean hasActiveSubplanDownstream(UUID subplanId) {
        Object count = em.createNativeQuery("""
                        SELECT
                            (SELECT COUNT(*)
                             FROM plan_draw_links l
                             JOIN stock_documents d ON d.id = l.draw_id
                             WHERE l.plan_id = :id
                               AND l.is_deleted = FALSE
                               AND d.is_deleted = FALSE
                               AND d.status <> -1)
                          + (SELECT COUNT(*)
                             FROM mrp_generations g
                             JOIN purchase_requests r ON r.id = g.request_id
                             WHERE g.plan_id = :id
                               AND g.is_deleted = FALSE
                               AND r.is_deleted = FALSE
                               AND r.status <> -1)
                          + (SELECT COUNT(*)
                             FROM subplan_links l
                             JOIN production_plans p ON p.id = l.subplan_id
                             WHERE l.plan_id = :id
                               AND l.is_deleted = FALSE
                               AND p.is_deleted = FALSE
                               AND p.status <> -1)
                        """)
                .setParameter("id", subplanId)
                .getSingleResult();
        return ((Number) count).longValue() > 0;
    }

    private PlanningPackageResult replay(ProductionPlanningPackage planningPackage) {
        List<ProductionFulfillmentLedgerService.PackageDocument> documents =
                ledger.lockPackageDocuments(planningPackage.getId());
        List<GenerateSubplansRequest.Created> subplans = new ArrayList<>();
        for (ProductionFulfillmentLedgerService.PackageDocument document : documents) {
            if (!"SUBPLAN".equals(document.documentType())) {
                continue;
            }
            Object count = em.createNativeQuery("""
                            SELECT COUNT(*)
                            FROM production_plan_items
                            WHERE plan_id = :id AND is_deleted = FALSE
                            """)
                    .setParameter("id", document.documentId())
                    .getSingleResult();
            Object workshop = em.createNativeQuery("""
                            SELECT workshop_name
                            FROM production_plans
                            WHERE id = :id
                            """)
                    .setParameter("id", document.documentId())
                    .getSingleResult();
            subplans.add(new GenerateSubplansRequest.Created(
                    document.documentId(),
                    document.documentNo(),
                    ((Number) count).intValue(),
                    workshop == null ? null : workshop.toString()));
        }
        MrpGenerateResult purchase = null;
        if (planningPackage.getPurchaseRequestId() != null) {
            List<Object[]> rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT r.bill_no, COUNT(i.id)
                                    FROM purchase_requests r
                                    LEFT JOIN purchase_request_items i
                                      ON i.request_id = r.id AND i.is_deleted = FALSE
                                    WHERE r.id = :id
                                    GROUP BY r.id
                                    """)
                            .setParameter("id", planningPackage.getPurchaseRequestId()));
            if (!rows.isEmpty()) {
                purchase = new MrpGenerateResult(
                        planningPackage.getPurchaseRequestId(),
                        (String) rows.getFirst()[0],
                        ((Number) rows.getFirst()[1]).intValue(),
                        List.of());
            }
        }
        MrpGenerateResult draw = documents.stream()
                .filter(document -> "DRAW".equals(document.documentType()))
                .findFirst()
                .map(document -> {
                    Object count = em.createNativeQuery("""
                                    SELECT COUNT(*)
                                    FROM stock_document_items
                                    WHERE doc_id = :id
                                    """)
                            .setParameter("id", document.documentId())
                            .getSingleResult();
                    return new MrpGenerateResult(
                            document.documentId(),
                            document.documentNo(),
                            ((Number) count).intValue(),
                            List.of());
                })
                .orElse(null);
        return new PlanningPackageResult(
                planningPackage.getId(),
                planningPackage.getStatus(),
                true,
                List.copyOf(subplans),
                purchase,
                draw);
    }

    private Map<MaterialKey, String> routeMap(
            GeneratePlanningPackageRequest request,
            List<MrpRow> rows) {
        Map<MaterialKey, String> routes = new LinkedHashMap<>();
        rows.forEach(row -> routes.put(
                new MaterialKey(row.goodsId(), row.colorId()),
                row.selfMade()
                        ? ProductionMaterialDemand.ROUTE_MAKE
                        : ProductionMaterialDemand.ROUTE_BUY));
        if (request.getRoutes() == null) {
            return routes;
        }
        for (GeneratePlanningPackageRequest.MaterialRoute route : request.getRoutes()) {
            MaterialKey key = new MaterialKey(route.getGoodsId(), route.getColorId());
            if (!routes.containsKey(key)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "供给路线不属于当前 MRP 行");
            }
            if (!Set.of(
                            ProductionMaterialDemand.ROUTE_BUY,
                            ProductionMaterialDemand.ROUTE_SUBCONTRACT)
                    .contains(route.getSupplyRoute())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "执行分段上线前仅支持外购或委外供给路线");
            }
            routes.put(key, route.getSupplyRoute());
        }
        return routes;
    }

    private String fingerprint(UUID planId, UUID warehouseId, List<MrpRow> rows) {
        return fingerprint(
                planId, warehouseId, rows, warehouseAvailability(warehouseId, rows));
    }

    private String fingerprint(
            UUID planId,
            UUID warehouseId,
            List<MrpRow> rows,
            Map<MaterialKey, BigDecimal> warehouseAvailable) {
        List<String> parts = new ArrayList<>();
        parts.add("PLAN|" + planId);
        parts.add("WAREHOUSE|" + warehouseId);
        for (MrpRow row : rows) {
            MaterialKey key = new MaterialKey(row.goodsId(), row.colorId());
            parts.add(String.join("|",
                    "MATERIAL",
                    row.goodsId().toString(),
                    Objects.toString(row.colorId(), ""),
                    decimalText(row.gross()),
                    decimalText(row.bookStock()),
                    decimalText(row.salesReserved()),
                    decimalText(row.safetyStock()),
                    decimalText(row.openPoTotal()),
                    decimalText(row.openPoOnTime()),
                    Objects.toString(row.needDate(), ""),
                    Objects.toString(row.earliestArrivalDate(), ""),
                    decimalText(warehouseAvailable.getOrDefault(key, BigDecimal.ZERO))));
        }
        return PlanningPackageFingerprint.sha256(parts);
    }

    private Map<MaterialKey, BigDecimal> warehouseAvailability(
            UUID warehouseId,
            List<MrpRow> rows) {
        if (rows.isEmpty()) {
            return Map.of();
        }
        List<UUID> goodsIds = rows.stream()
                .map(MrpRow::goodsId)
                .distinct()
                .sorted()
                .toList();
        List<Object[]> values = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT a.goods_id, a.color_id,
                                       GREATEST(a.available_qty
                                                - GREATEST(COALESCE(g.min_qty, 0), 0), 0)
                                FROM v_stock_available a
                                JOIN goods g ON g.id = a.goods_id
                                WHERE a.warehouse_id = :warehouseId
                                  AND a.goods_id IN (:goodsIds)
                                """)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("goodsIds", goodsIds));
        Map<MaterialKey, BigDecimal> result = new HashMap<>();
        values.forEach(row -> result.put(
                new MaterialKey((UUID) row[0], (UUID) row[1]),
                decimal(row[2])));
        return result;
    }

    private static List<PlanningPreviewResult.TargetWarehouseMaterial>
            targetWarehouseMaterials(
                    List<MrpRow> rows,
                    Map<MaterialKey, BigDecimal> warehouseAvailable) {
        return rows.stream()
                .map(row -> {
                    BigDecimal required = row.gross();
                    BigDecimal available = warehouseAvailable.getOrDefault(
                            new MaterialKey(row.goodsId(), row.colorId()),
                            BigDecimal.ZERO);
                    BigDecimal candidate = required.min(available);
                    return new PlanningPreviewResult.TargetWarehouseMaterial(
                            row.goodsId(),
                            row.colorId(),
                            required,
                            available,
                            candidate,
                            required.subtract(candidate).max(BigDecimal.ZERO));
                })
                .toList();
    }

    private static boolean isBalancedKitCoverage(
            List<MrpRow> rows,
            Map<MaterialKey, BigDecimal> warehouseAvailable) {
        return hasCommonCoverageRatio(rows.stream()
                .filter(row -> row.gross().signum() > 0)
                .map(row -> new CoverageQuantity(
                        row.gross(),
                        warehouseAvailable
                                .getOrDefault(
                                        new MaterialKey(row.goodsId(), row.colorId()),
                                        BigDecimal.ZERO)
                                .min(row.gross())))
                .toList());
    }

    private static String requestHash(GeneratePlanningPackageRequest request) {
        List<String> parts = new ArrayList<>();
        parts.add("WAREHOUSE|" + request.getWarehouseId());
        parts.add("PURCHASE|" + request.isGeneratePurchaseRequest());
        if (request.getItems() != null) {
            request.getItems().forEach(line -> parts.add(String.join("|",
                    "SUBPLAN",
                    Objects.toString(line.getGoodsId(), ""),
                    Objects.toString(line.getColorId(), ""),
                    decimalText(line.getQty()),
                    Objects.toString(line.getDepartmentId(), ""),
                    Objects.toString(line.getWorkerId(), ""),
                    Objects.toString(line.getPlanBeginDate(), ""),
                    Objects.toString(line.getPlanEndDate(), ""))));
        }
        if (request.getRoutes() != null) {
            request.getRoutes().forEach(route -> parts.add(String.join("|",
                    "ROUTE",
                    Objects.toString(route.getGoodsId(), ""),
                    Objects.toString(route.getColorId(), ""),
                    Objects.toString(route.getSupplyRoute(), ""))));
        }
        return PlanningPackageFingerprint.sha256(parts);
    }

    /**
     * A planning package currently has one aggregated material-demand set and
     * no persisted execution-segment identity. Until segment rows exist, only
     * a common coverage ratio is safe: e.g. A 10/10 with B 6/10 must roll back
     * instead of leaving an apparent six-kit plan backed by mismatched stock.
     */
    private static void requireBalancedKitCoverage(
            List<ProductionMaterialDemand> demands,
            Map<UUID, BigDecimal> allocatedByDemand) {
        boolean balanced = hasCommonCoverageRatio(demands.stream()
                .filter(demand -> demand.getRequiredQty().signum() > 0)
                .map(demand -> new CoverageQuantity(
                        demand.getRequiredQty(),
                        allocatedByDemand.getOrDefault(
                                demand.getId(), BigDecimal.ZERO)))
                .toList());
        if (!balanced) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "目标仓各物料可支持的齐套比例不一致；执行分段尚未持久化，已回滚本次计划包以避免错配占料");
        }
    }

    static boolean hasCommonCoverageRatio(List<CoverageQuantity> quantities) {
        if (quantities.isEmpty()) {
            return true;
        }
        CoverageQuantity reference = quantities.getFirst();
        if (reference.requiredQty().signum() <= 0) {
            throw new IllegalArgumentException("required quantity must be positive");
        }
        return quantities.stream().allMatch(quantity -> {
            if (quantity.requiredQty().signum() <= 0
                    || quantity.allocatedQty().signum() < 0
                    || quantity.allocatedQty().compareTo(quantity.requiredQty()) > 0) {
                throw new IllegalArgumentException("invalid coverage quantity");
            }
            return quantity.allocatedQty().multiply(reference.requiredQty())
                    .compareTo(reference.allocatedQty().multiply(
                            quantity.requiredQty())) == 0;
        });
    }

    private static String stableMaterialKey(MrpRow row) {
        return row.goodsId() + ":" + Objects.toString(row.colorId(), "NONE")
                + ":" + Objects.toString(row.needDate(), "NONE");
    }

    private static String decimalText(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private void validateRequest(GeneratePlanningPackageRequest request) {
        if (request == null
                || request.getWarehouseId() == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getPreviewFingerprint() == null
                || !request.getPreviewFingerprint().matches("(?i)[0-9a-f]{64}")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "计划包请求缺少仓库、幂等键或有效预览指纹");
        }
        if (request.getItems() != null && !request.getItems().isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "当前 items 仅表示旧版自制件子计划，不是成品执行分段；为避免误排产，计划包暂不接受该字段");
        }
        requireWarehouse(request.getWarehouseId());
    }

    private void requireWarehouse(UUID warehouseId) {
        Object count = em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM warehouses
                        WHERE id = :id AND is_deleted = FALSE
                        """)
                .setParameter("id", warehouseId)
                .getSingleResult();
        if (((Number) count).longValue() != 1) {
            throw new ApiException(ErrorCode.NOT_FOUND, "目标仓库不存在或已停用");
        }
    }

    private PlanHeader lockPlan(UUID planId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT bill_no, delivery_date, status,
                                       is_deleted, is_canceled, is_stopped
                                FROM production_plans
                                WHERE id = :id
                                FOR UPDATE
                                """)
                        .setParameter("id", planId));
        if (rows.isEmpty() || Boolean.TRUE.equals(rows.getFirst()[3])) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        Object[] row = rows.getFirst();
        if (((Number) row[2]).shortValue() == -1
                || Boolean.TRUE.equals(row[4])
                || Boolean.TRUE.equals(row[5])) {
            throw new ApiException(ErrorCode.CONFLICT, "终态生产计划不能操作计划包");
        }
        return new PlanHeader(
                (String) row[0],
                row[1] == null ? null : ((java.sql.Date) row[1]).toLocalDate());
    }

    private record PlanHeader(String billNo, LocalDate deliveryDate) {
    }

    private record MaterialKey(UUID goodsId, UUID colorId) {
    }

    record CoverageQuantity(BigDecimal requiredQty, BigDecimal allocatedQty) {
    }
}
