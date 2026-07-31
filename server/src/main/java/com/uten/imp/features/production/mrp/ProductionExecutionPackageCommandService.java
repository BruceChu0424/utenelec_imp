package com.uten.imp.features.production.mrp;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import com.uten.imp.features.production.fulfillment.ProductionExecutionSegmentRepository;
import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import com.uten.imp.features.production.fulfillment.ProductionPlanningPackage;
import com.uten.imp.features.production.fulfillment.ProductionSubcontractApplicationCoordinator;
import com.uten.imp.features.purchase.request.ProductionPurchaseRequestFacade;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** Atomic command path for V155 finished-product execution segments. */
@Service
@RequiredArgsConstructor
public class ProductionExecutionPackageCommandService {

    private final EntityManager em;
    private final ProductionExecutionPlanningService planning;
    private final ProductionFulfillmentLedgerService ledger;
    private final ProductionExecutionSegmentRepository segmentRepo;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionPurchaseRequestFacade purchaseFacade;
    private final ProductionSubcontractApplicationCoordinator
            subcontractCoordinator;
    private final SecurityContextCurrentUser currentUser;
    private final StockDocumentRepository stockDocumentRepo;
    private final StockDocumentItemRepository stockDocumentItemRepo;
    private final DocNumberService docNumberService;

    @Transactional
    public PlanningPackageResult confirm(
            UUID planId,
            GeneratePlanningPackageRequest request) {
        PlanHeader plan = lockPlan(planId);
        validateRequest(request);
        ProductionExecutionPlanningService.Snapshot initial =
                planning.preview(planId, request.getWarehouseId());
        Map<CompleteKitAllocator.MaterialKey, String> routes =
                authoritativeRoutes(request, initial);

        requireNoActiveLegacyPackage(planId);
        ProductionFulfillmentLedgerService.BeginConfirmation begin =
                ledger.beginConfirmation(
                        planId,
                        request.getWarehouseId(),
                        request.getIdempotencyKey(),
                        requestHash(request),
                        request.getPreviewFingerprint());
        if (begin.replayed()) {
            return replay(begin.planningPackage());
        }
        requireNoLegacyExecutionFacts(loadLegacyExecutionFacts(
                planId,
                begin.planningPackage().getId()));

        begin.planningPackage().setExecutionModelVersion((short) 1);
        em.createNativeQuery("""
                        UPDATE production_planning_packages
                        SET execution_model_version = 1, updated_at = now()
                        WHERE id = :id
                        """)
                .setParameter("id", begin.planningPackage().getId())
                .executeUpdate();

        List<ProductionPurchaseRequestFacade.MaterialDimension> dimensions =
                initial.productLines().stream()
                        .flatMap(line -> line.materials().stream())
                        .map(material ->
                                new ProductionPurchaseRequestFacade.MaterialDimension(
                                        material.goodsId(), material.colorId()))
                        .distinct()
                        .sorted()
                        .toList();
        stockAllocation.lockMaterialDimensions(dimensions.stream()
                .map(dimension ->
                        new ProductionMaterialAllocationFacade.MaterialDimension(
                                dimension.goodsId(), dimension.colorId()))
                .toList());
        purchaseFacade.lockOpenSupply(dimensions);

        ProductionExecutionPlanningService.Snapshot locked =
                planning.lockedSnapshot(
                        planId, request.getWarehouseId(), routes);
        if (!locked.fingerprint().equalsIgnoreCase(
                request.getPreviewFingerprint())) {
            throw conflict(
                    "排产预览已过期：目标仓库存、占用、计划行或 BOM 已变化");
        }
        CompleteKitAllocator.Allocation allocation =
                planning.applyRequested(locked, request.getSegments());
        List<SegmentDraft> segmentDrafts = persistSegments(
                plan, begin.planningPackage(), allocation);
        persistSalesAllocations(segmentDrafts);

        List<ProductionFulfillmentLedgerService.DemandDraft> demandDrafts =
                new ArrayList<>();
        for (SegmentDraft segment : segmentDrafts) {
            for (CompleteKitAllocator.MaterialAllocation material
                    : segment.proposal().materials()) {
                demandDrafts.add(
                        new ProductionFulfillmentLedgerService.DemandDraft(
                                segment.segment().getId(),
                                segment.segment().getSourcePlanItemId(),
                                material.goodsId(),
                                material.colorId(),
                                material.unitId(),
                                material.perProductQty(),
                                material.requiredQty(),
                                segment.segment().getPlanBeginDate(),
                                material.supplyRoute(),
                                segment.segment().getId() + ":"
                                        + material.goodsId() + ":"
                                        + Objects.toString(
                                                material.colorId(), "NONE")));
            }
        }
        List<ProductionMaterialDemand> demands =
                ledger.createDemands(begin.planningPackage(), demandDrafts);
        Map<UUID, List<ProductionMaterialDemand>> demandsBySegment =
                demands.stream().collect(Collectors.groupingBy(
                        ProductionMaterialDemand::getExecutionSegmentId,
                        LinkedHashMap::new,
                        Collectors.toList()));

        Map<UUID, BigDecimal> allocatedByDemand =
                allocateReady(
                        begin.planningPackage(),
                        segmentDrafts,
                        demandsBySegment);
        assertAllocationMatchesProposal(
                segmentDrafts, demandsBySegment, allocatedByDemand);

        Map<UUID, MrpGenerateResult> draws = new LinkedHashMap<>();
        for (SegmentDraft segment : segmentDrafts) {
            if (!ProductionExecutionSegment.STATUS_READY.equals(
                    segment.segment().getStatus())) {
                continue;
            }
            MrpGenerateResult draw = createDraw(
                    plan,
                    begin.planningPackage(),
                    segment.segment(),
                    demandsBySegment.getOrDefault(
                            segment.segment().getId(), List.of()),
                    allocatedByDemand);
            draws.put(segment.segment().getId(), draw);
        }

        Map<DemandMaterialKey, BigDecimal> purchaseShortage =
                proposedPurchaseShortage(segmentDrafts);
        List<ProductionPurchaseRequestFacade.DraftLine> purchaseLines =
                demands.stream()
                        .map(demand -> {
                            BigDecimal qty = purchaseShortage.getOrDefault(
                                    new DemandMaterialKey(
                                            demand.getExecutionSegmentId(),
                                            demand.getGoodsId(),
                                            demand.getColorId()),
                                    BigDecimal.ZERO);
                            return new ProductionPurchaseRequestFacade.DraftLine(
                                    demand.getId(),
                                    demand.getGoodsId(),
                                    demand.getColorId(),
                                    demand.getUnitId(),
                                    qty,
                                    demand.getNeedDate(),
                                    "执行分段 " + demand.getExecutionSegmentId());
                        })
                        .filter(line -> line.qty().signum() > 0)
                        .toList();
        requirePurchaseRequestForBuyShortage(
                request.isGeneratePurchaseRequest(), purchaseLines);
        MrpGenerateResult purchaseResult =
                request.isGeneratePurchaseRequest()
                        ? createPurchase(
                                plan, begin.planningPackage(),
                                request.getWarehouseId(),
                                demands, purchaseLines)
                        : null;

        Map<DemandMaterialKey, BigDecimal> subcontractShortage =
                proposedShortage(
                        segmentDrafts,
                        ProductionMaterialDemand.ROUTE_SUBCONTRACT);
        List<ProductionSubcontractRequestPort.DraftLine> subcontractLines =
                demands.stream()
                        .map(demand -> {
                            BigDecimal qty =
                                    subcontractShortage.getOrDefault(
                                            new DemandMaterialKey(
                                                    demand.getExecutionSegmentId(),
                                                    demand.getGoodsId(),
                                                    demand.getColorId()),
                                            BigDecimal.ZERO);
                            return new ProductionSubcontractRequestPort.DraftLine(
                                    demand.getId(),
                                    demand.getGoodsId(),
                                    demand.getColorId(),
                                    demand.getUnitId(),
                                    qty,
                                    demand.getNeedDate(),
                                    "Execution segment "
                                            + demand.getExecutionSegmentId());
                        })
                        .filter(line -> line.qty().signum() > 0)
                        .toList();
        MrpGenerateResult subcontractResult =
                subcontractCoordinator.create(
                        plan.billNo(),
                        plan.deliveryDate(),
                        request.getWarehouseId(),
                        begin.planningPackage(),
                        demands,
                        subcontractLines);

        ledger.refreshDemandStatuses(
                demands.stream().map(ProductionMaterialDemand::getId).toList());
        List<ExecutionSegmentResult> results = results(
                segmentDrafts, demandsBySegment, allocatedByDemand, draws);
        List<MrpGenerateResult> drawResults =
                List.copyOf(draws.values());
        return new PlanningPackageResult(
                begin.planningPackage().getId(),
                begin.planningPackage().getStatus(),
                false,
                List.of(),
                purchaseResult,
                subcontractResult,
                drawResults.isEmpty() ? null : drawResults.getFirst(),
                results,
                drawResults);
    }

    private List<SegmentDraft> persistSegments(
            PlanHeader plan,
            ProductionPlanningPackage planningPackage,
            CompleteKitAllocator.Allocation allocation) {
        List<SegmentDraft> result = new ArrayList<>();
        int no = 0;
        for (CompleteKitAllocator.SegmentAllocation proposal
                : allocation.segments()) {
            no++;
            ProductionExecutionSegment segment =
                    new ProductionExecutionSegment();
            segment.setPackageId(planningPackage.getId());
            segment.setPlanId(planningPackage.getPlanId());
            segment.setSourcePlanItemId(
                    proposal.line().sourcePlanItemId());
            segment.setSegmentNo(no);
            segment.setSegmentCode(
                    segmentCode(plan.billNo(), planningPackage.getId(), no));
            segment.setClientSegmentKey(proposal.clientSegmentKey());
            segment.setProductGoodsId(
                    proposal.line().productGoodsId());
            segment.setProductColorId(
                    proposal.line().productColorId());
            segment.setProductUnitId(
                    proposal.line().productUnitId());
            segment.setProductUnitRate(
                    proposal.line().productUnitRate());
            segment.setPlannedQty(proposal.plannedQty());
            segment.setStatus(proposal.status());
            segment.setWorkshopDepartmentId(
                    proposal.line().defaultWorkshopDepartmentId());
            segment.setTeamDepartmentId(
                    proposal.line().defaultTeamDepartmentId());
            segment.setResponsibleEmployeeId(
                    proposal.line().defaultResponsibleEmployeeId());
            segment.setPlanBeginDate(proposal.line().planBeginDate());
            segment.setPlanEndDate(proposal.line().planEndDate());
            segment.setBomFingerprint(
                    proposal.line().bomFingerprint().toLowerCase());
            segment.setIdempotencyKey(
                    planningPackage.getId() + ":SEG:"
                            + proposal.clientSegmentKey());
            segmentRepo.save(segment);
            result.add(new SegmentDraft(segment, proposal));
        }
        segmentRepo.flush();
        return List.copyOf(result);
    }

    /**
     * Freezes the exact sales ownership of every execution segment.
     *
     * <p>Both candidate sets use a stable order. Segments follow their
     * persisted segment number. Sales links follow source-plan-item,
     * requested delivery date, order date/id, order line/id and link id.
     * A sales-backed plan item must be partitioned in full; an internal plan
     * item has no allocation rows.
     */
    private void persistSalesAllocations(List<SegmentDraft> segments) {
        List<UUID> planItemIds = segments.stream()
                .map(segment -> segment.segment().getSourcePlanItemId())
                .distinct()
                .sorted()
                .toList();
        if (planItemIds.isEmpty()) {
            return;
        }

        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT link.id, link.plan_item_id,
                                       link.order_item_id, link.allocated_qty
                                FROM plan_order_item_links link
                                JOIN sales_order_items order_item
                                  ON order_item.id = link.order_item_id
                                JOIN sales_orders sales_order
                                  ON sales_order.id = order_item.order_id
                                WHERE link.plan_item_id IN (:planItemIds)
                                  AND link.is_deleted = FALSE
                                  AND order_item.is_deleted = FALSE
                                  AND sales_order.is_deleted = FALSE
                                ORDER BY link.plan_item_id,
                                         COALESCE(
                                             order_item.deliver_date,
                                             sales_order.deliver_date)
                                             ASC NULLS LAST,
                                         sales_order.bill_date ASC NULLS LAST,
                                         sales_order.id,
                                         order_item.line_no ASC NULLS LAST,
                                         order_item.id,
                                         link.id
                                FOR UPDATE OF link
                                """)
                        .setParameter("planItemIds", planItemIds));

        Map<UUID, List<SalesLinkSlice>> linksByPlanItem =
                new LinkedHashMap<>();
        for (Object[] row : rows) {
            BigDecimal quantity = decimal(row[3]);
            if (quantity.signum() <= 0) {
                throw conflict(
                        "Sales-backed production link has a non-positive allocation");
            }
            linksByPlanItem.computeIfAbsent(
                            (UUID) row[1], ignored -> new ArrayList<>())
                    .add(new SalesLinkSlice(
                            (UUID) row[0],
                            (UUID) row[2],
                            quantity));
        }

        Map<UUID, List<SegmentDraft>> segmentsByPlanItem =
                segments.stream()
                        .sorted(Comparator.comparingInt(
                                segment ->
                                        segment.segment().getSegmentNo()))
                        .collect(Collectors.groupingBy(
                                segment -> segment.segment()
                                        .getSourcePlanItemId(),
                                LinkedHashMap::new,
                                Collectors.toList()));

        for (Map.Entry<UUID, List<SegmentDraft>> entry :
                segmentsByPlanItem.entrySet()) {
            List<SalesLinkSlice> links =
                    linksByPlanItem.getOrDefault(
                            entry.getKey(), List.of());
            if (links.isEmpty()) {
                continue;
            }
            BigDecimal segmentTotal = entry.getValue().stream()
                    .map(segment -> segment.segment().getPlannedQty())
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            BigDecimal linkTotal = links.stream()
                    .map(SalesLinkSlice::remaining)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (segmentTotal.compareTo(linkTotal) != 0) {
                throw conflict(
                        "Execution segment total does not match its sales allocation total");
            }

            int linkIndex = 0;
            for (SegmentDraft segment : entry.getValue()) {
                BigDecimal remaining =
                        segment.segment().getPlannedQty();
                while (remaining.signum() > 0) {
                    if (linkIndex >= links.size()) {
                        throw conflict(
                                "Execution segment sales allocation is incomplete");
                    }
                    SalesLinkSlice link = links.get(linkIndex);
                    BigDecimal quantity =
                            remaining.min(link.remaining());
                    em.createNativeQuery("""
                                    INSERT INTO
                                      execution_segment_sales_allocations(
                                        execution_segment_id,
                                        plan_order_item_link_id,
                                        sales_order_item_id,
                                        allocated_qty,
                                        created_by
                                      )
                                    VALUES (
                                      :segmentId, :linkId, :orderItemId,
                                      :quantity, :createdBy
                                    )
                                    """)
                            .setParameter(
                                    "segmentId",
                                    segment.segment().getId())
                            .setParameter("linkId", link.linkId())
                            .setParameter(
                                    "orderItemId", link.orderItemId())
                            .setParameter("quantity", quantity)
                            .setParameter(
                                    "createdBy", currentUser.requireId())
                            .executeUpdate();
                    remaining = remaining.subtract(quantity);
                    link.consume(quantity);
                    if (link.remaining().signum() == 0) {
                        linkIndex++;
                    }
                }
            }
            if (links.stream().anyMatch(
                    link -> link.remaining().signum() != 0)) {
                throw conflict(
                        "Production sales allocation was not consumed exactly");
            }
        }
    }

    /**
     * WAITING never holds partial stock. READY demands are allocated in a
     * separate first pass and must be covered exactly.
     */
    private Map<UUID, BigDecimal> allocateReady(
            ProductionPlanningPackage planningPackage,
            List<SegmentDraft> segments,
            Map<UUID, List<ProductionMaterialDemand>> demandsBySegment) {
        List<ProductionMaterialAllocationFacade.AllocationRequest> requests =
                segments.stream()
                        .filter(segment ->
                                ProductionExecutionSegment.STATUS_READY.equals(
                                        segment.segment().getStatus()))
                        .flatMap(segment -> demandsBySegment
                                .getOrDefault(
                                        segment.segment().getId(), List.of())
                                .stream())
                        .map(demand ->
                                new ProductionMaterialAllocationFacade
                                        .AllocationRequest(
                                        planningPackage.getId(),
                                        demand.getId(),
                                        demand.getGoodsId(),
                                        demand.getColorId(),
                                        planningPackage.getWarehouseId(),
                                        demand.getRequiredQty(),
                                        planningPackage.getId()
                                                + ":STOCK:" + demand.getId(),
                                        currentUser.requireId()))
                        .toList();
        Map<UUID, BigDecimal> result = new HashMap<>();
        stockAllocation.allocate(requests).forEach(allocation ->
                result.put(
                        allocation.demandId(),
                        allocation.allocatedQty()));
        return result;
    }

    private void assertAllocationMatchesProposal(
            List<SegmentDraft> segments,
            Map<UUID, List<ProductionMaterialDemand>> demandsBySegment,
            Map<UUID, BigDecimal> allocatedByDemand) {
        for (SegmentDraft segment : segments) {
            Map<CompleteKitAllocator.MaterialKey, BigDecimal> expected =
                    segment.proposal().materials().stream()
                            .collect(Collectors.toMap(
                                    material ->
                                            new CompleteKitAllocator.MaterialKey(
                                                    material.goodsId(),
                                                    material.colorId()),
                                    CompleteKitAllocator.MaterialAllocation
                                            ::candidateAllocatedQty));
            for (ProductionMaterialDemand demand :
                    demandsBySegment.getOrDefault(
                            segment.segment().getId(), List.of())) {
                BigDecimal planned = expected.getOrDefault(
                        new CompleteKitAllocator.MaterialKey(
                                demand.getGoodsId(), demand.getColorId()),
                        BigDecimal.ZERO);
                BigDecimal actual = allocatedByDemand.getOrDefault(
                        demand.getId(), BigDecimal.ZERO);
                if (planned.compareTo(actual) != 0) {
                    throw conflict(
                            "库存分配与齐套方案不一致，事务已回滚，请刷新后重试");
                }
            }
        }
    }

    private MrpGenerateResult createDraw(
            PlanHeader plan,
            ProductionPlanningPackage planningPackage,
            ProductionExecutionSegment segment,
            List<ProductionMaterialDemand> demands,
            Map<UUID, BigDecimal> allocatedByDemand) {
        if (demands.isEmpty()
                || demands.stream().anyMatch(demand ->
                        allocatedByDemand.getOrDefault(
                                        demand.getId(), BigDecimal.ZERO)
                                .compareTo(demand.getRequiredQty()) != 0)) {
            throw conflict("READY 执行分段必须由完整库存支持");
        }
        StockDocument document = new StockDocument();
        document.setDocType("DRAW");
        document.setBillNo(
                docNumberService.nextNumber(DocNumberPrefix.STOCK_DRAW));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(planningPackage.getWarehouseId());
        document.setPlanNo(plan.billNo());
        document.setSourceDocNo(plan.billNo());
        document.setRemark(
                "执行分段 " + segment.getSegmentCode() + " 自动备料");
        document.setWorkerId(currentUser.requireId());
        document.setMakerId(currentUser.requireEmployeeId());
        document.setStatus((short) 0);
        stockDocumentRepo.save(document);

        int lineNo = 0;
        for (ProductionMaterialDemand demand : demands.stream()
                .sorted(Comparator
                        .comparing(ProductionMaterialDemand::getGoodsId)
                        .thenComparing(value ->
                                Objects.toString(value.getColorId(), "")))
                .toList()) {
            lineNo++;
            StockDocumentItem item = new StockDocumentItem();
            item.setDocId(document.getId());
            item.setBillType("DRAW");
            item.setBillNo(document.getBillNo());
            item.setBillDate(document.getBillDate());
            item.setLineNo(lineNo);
            item.setGoodsId(demand.getGoodsId());
            item.setColorId(demand.getColorId());
            item.setUnitId(demand.getUnitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(demand.getRequiredQty());
            item.setBaseQty(demand.getRequiredQty());
            item.setSourceDocNo(plan.billNo());
            item.setRemark("执行分段需求 " + demand.getId());
            stockDocumentItemRepo.save(item);
            em.createNativeQuery("""
                            INSERT INTO
                                production_planning_package_document_items (
                                    package_id, demand_id, document_type,
                                    document_id, document_item_id, created_by
                                )
                            VALUES (
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
                segment.getId(),
                "DRAW",
                document.getId(),
                document.getBillNo(),
                currentUser.requireId());
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(
                            plan_id, draw_id, created_by)
                        VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", planningPackage.getPlanId())
                .setParameter("drawId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return new MrpGenerateResult(
                document.getId(), document.getBillNo(), lineNo, List.of());
    }

    private MrpGenerateResult createPurchase(
            PlanHeader plan,
            ProductionPlanningPackage planningPackage,
            UUID warehouseId,
            List<ProductionMaterialDemand> demands,
            List<ProductionPurchaseRequestFacade.DraftLine> lines) {
        ProductionPurchaseRequestFacade.DraftResult purchase =
                purchaseFacade.createProductionDraft(
                        plan.billNo(),
                        plan.deliveryDate(),
                        warehouseId,
                        lines,
                        currentUser.requireId(),
                        currentUser.requireEmployeeId());
        if (purchase == null) {
            return null;
        }
        ledger.attachPurchaseRequest(
                planningPackage, purchase.requestId());
        ledger.recordDocument(
                planningPackage.getId(),
                "PURCHASE_REQUEST",
                purchase.requestId(),
                purchase.billNo(),
                currentUser.requireId());
        Map<UUID, ProductionMaterialDemand> demandById =
                demands.stream().collect(Collectors.toMap(
                        ProductionMaterialDemand::getId,
                        demand -> demand));
        for (ProductionPurchaseRequestFacade.DraftLineResult line
                : purchase.lines()) {
            ledger.createSupplyPeg(
                    demandById.get(line.demandId()),
                    "PURCHASE_REQUEST_ITEM",
                    line.requestItemId(),
                    line.qty(),
                    line.expectedDate());
        }
        return new MrpGenerateResult(
                purchase.requestId(),
                purchase.billNo(),
                purchase.lines().size(),
                List.of());
    }

    static void requirePurchaseRequestForBuyShortage(
            boolean generatePurchaseRequest,
            List<?> purchaseLines) {
        if (!generatePurchaseRequest
                && purchaseLines != null
                && !purchaseLines.isEmpty()) {
            throw validation(
                    "BUY shortage requires purchase-request generation");
        }
    }

    private static Map<DemandMaterialKey, BigDecimal>
            proposedPurchaseShortage(List<SegmentDraft> segments) {
        return proposedShortage(
                segments, ProductionMaterialDemand.ROUTE_BUY);
    }

    private static Map<DemandMaterialKey, BigDecimal> proposedShortage(
            List<SegmentDraft> segments,
            String supplyRoute) {
        Map<DemandMaterialKey, BigDecimal> result = new HashMap<>();
        for (SegmentDraft segment : segments) {
            for (CompleteKitAllocator.MaterialAllocation material
                    : segment.proposal().materials()) {
                if (!supplyRoute.equals(material.supplyRoute())
                        || material.shortageQty().signum() <= 0) {
                    continue;
                }
                result.put(
                        new DemandMaterialKey(
                                segment.segment().getId(),
                                material.goodsId(),
                                material.colorId()),
                        material.shortageQty());
            }
        }
        return result;
    }

    private List<ExecutionSegmentResult> results(
            List<SegmentDraft> segments,
            Map<UUID, List<ProductionMaterialDemand>> demandsBySegment,
            Map<UUID, BigDecimal> allocatedByDemand,
            Map<UUID, MrpGenerateResult> draws) {
        return segments.stream().map(draft -> {
            ProductionExecutionSegment segment = draft.segment();
            List<ExecutionSegmentResult.Material> materials =
                    demandsBySegment.getOrDefault(segment.getId(), List.of())
                            .stream()
                            .map(demand -> {
                                BigDecimal allocated =
                                        allocatedByDemand.getOrDefault(
                                                demand.getId(), BigDecimal.ZERO);
                                return new ExecutionSegmentResult.Material(
                                        demand.getId(),
                                        demand.getGoodsId(),
                                        demand.getColorId(),
                                        demand.getUnitId(),
                                        demand.getPerProductQty(),
                                        demand.getRequiredQty(),
                                        allocated,
                                        demand.getRequiredQty()
                                                .subtract(allocated)
                                                .max(BigDecimal.ZERO),
                                        demand.getSupplyRoute());
                            })
                            .toList();
            return new ExecutionSegmentResult(
                    segment.getId(),
                    segment.getSegmentCode(),
                    segment.getClientSegmentKey(),
                    segment.getSourcePlanItemId(),
                    segment.getProductGoodsId(),
                    segment.getProductColorId(),
                    segment.getPlannedQty(),
                    segment.getStatus(),
                    segment.getWorkshopDepartmentId(),
                    segment.getTeamDepartmentId(),
                    segment.getResponsibleEmployeeId(),
                    segment.getPlanBeginDate(),
                    segment.getPlanEndDate(),
                    materials,
                    draws.get(segment.getId()));
        }).toList();
    }

    private PlanningPackageResult replay(
            ProductionPlanningPackage planningPackage) {
        List<ProductionExecutionSegment> segments =
                segmentRepo.findByPackageIdAndDeletedFalseOrderBySegmentNoAsc(
                        planningPackage.getId());
        Map<UUID, MrpGenerateResult> draws = new LinkedHashMap<>();
        List<Object[]> drawRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT h.execution_segment_id,
                                       h.document_id,
                                       h.document_no,
                                       COUNT(i.id)
                                FROM production_planning_package_documents h
                                LEFT JOIN stock_document_items i
                                  ON i.doc_id = h.document_id
                                 AND i.is_deleted = FALSE
                                WHERE h.package_id = :packageId
                                  AND h.document_type = 'DRAW'
                                  AND h.execution_segment_id IS NOT NULL
                                GROUP BY h.execution_segment_id,
                                         h.document_id, h.document_no,
                                         h.created_at
                                ORDER BY h.created_at, h.document_id
                                """)
                        .setParameter(
                                "packageId", planningPackage.getId()));
        for (Object[] row : drawRows) {
            draws.putIfAbsent(
                    (UUID) row[0],
                    new MrpGenerateResult(
                            (UUID) row[1],
                            (String) row[2],
                            ((Number) row[3]).intValue(),
                            List.of()));
        }
        List<SegmentDraft> drafts = segments.stream()
                .map(segment -> new SegmentDraft(segment, null))
                .toList();
        Map<UUID, List<ProductionMaterialDemand>> demandsBySegment =
                em.createQuery("""
                                SELECT d
                                FROM ProductionMaterialDemand d
                                WHERE d.packageId = :packageId
                                  AND d.executionSegmentId IS NOT NULL
                                  AND d.deleted = FALSE
                                ORDER BY d.executionSegmentId, d.goodsId
                                """, ProductionMaterialDemand.class)
                        .setParameter(
                                "packageId", planningPackage.getId())
                        .getResultList()
                        .stream()
                        .collect(Collectors.groupingBy(
                                ProductionMaterialDemand::getExecutionSegmentId,
                                LinkedHashMap::new,
                                Collectors.toList()));
        Map<UUID, BigDecimal> allocated = allocationTotals(
                demandsBySegment.values().stream()
                        .flatMap(List::stream)
                        .map(ProductionMaterialDemand::getId)
                        .toList());
        MrpGenerateResult purchase = replayPurchase(planningPackage);
        MrpGenerateResult subcontract = replaySubcontract(planningPackage);
        List<ExecutionSegmentResult> executionResults =
                replayResults(drafts, demandsBySegment, allocated, draws);
        List<MrpGenerateResult> drawResults =
                List.copyOf(draws.values());
        return new PlanningPackageResult(
                planningPackage.getId(),
                planningPackage.getStatus(),
                true,
                List.of(),
                purchase,
                subcontract,
                drawResults.isEmpty() ? null : drawResults.getFirst(),
                executionResults,
                drawResults);
    }

    private List<ExecutionSegmentResult> replayResults(
            List<SegmentDraft> drafts,
            Map<UUID, List<ProductionMaterialDemand>> demandsBySegment,
            Map<UUID, BigDecimal> allocated,
            Map<UUID, MrpGenerateResult> draws) {
        return drafts.stream().map(draft -> {
            ProductionExecutionSegment segment = draft.segment();
            List<ExecutionSegmentResult.Material> materials =
                    demandsBySegment.getOrDefault(segment.getId(), List.of())
                            .stream()
                            .map(demand -> {
                                BigDecimal stock = allocated.getOrDefault(
                                        demand.getId(), BigDecimal.ZERO);
                                return new ExecutionSegmentResult.Material(
                                        demand.getId(),
                                        demand.getGoodsId(),
                                        demand.getColorId(),
                                        demand.getUnitId(),
                                        demand.getPerProductQty(),
                                        demand.getRequiredQty(),
                                        stock,
                                        demand.getRequiredQty()
                                                .subtract(stock)
                                                .max(BigDecimal.ZERO),
                                        demand.getSupplyRoute());
                            })
                            .toList();
            return new ExecutionSegmentResult(
                    segment.getId(), segment.getSegmentCode(),
                    segment.getClientSegmentKey(),
                    segment.getSourcePlanItemId(),
                    segment.getProductGoodsId(),
                    segment.getProductColorId(),
                    segment.getPlannedQty(), segment.getStatus(),
                    segment.getWorkshopDepartmentId(),
                    segment.getTeamDepartmentId(),
                    segment.getResponsibleEmployeeId(),
                    segment.getPlanBeginDate(),
                    segment.getPlanEndDate(),
                    materials, draws.get(segment.getId()));
        }).toList();
    }

    private Map<UUID, BigDecimal> allocationTotals(List<UUID> demandIds) {
        if (demandIds.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT demand_id,
                                       COALESCE(SUM(
                                           qty - released_qty), 0)
                                FROM stock_reservations
                                WHERE demand_id IN (:ids)
                                  AND is_deleted = FALSE
                                GROUP BY demand_id
                                """)
                        .setParameter("ids", demandIds));
        Map<UUID, BigDecimal> result = new HashMap<>();
        rows.forEach(row -> result.put(
                (UUID) row[0], decimal(row[1])));
        return result;
    }

    private MrpGenerateResult replayPurchase(
            ProductionPlanningPackage planningPackage) {
        if (planningPackage.getPurchaseRequestId() == null) return null;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT r.bill_no, COUNT(i.id)
                                FROM purchase_requests r
                                LEFT JOIN purchase_request_items i
                                  ON i.request_id = r.id
                                 AND i.is_deleted = FALSE
                                WHERE r.id = :id
                                GROUP BY r.id
                                """)
                        .setParameter(
                                "id",
                                planningPackage.getPurchaseRequestId()));
        if (rows.isEmpty()) return null;
        return new MrpGenerateResult(
                planningPackage.getPurchaseRequestId(),
                (String) rows.getFirst()[0],
                ((Number) rows.getFirst()[1]).intValue(),
                List.of());
    }

    private MrpGenerateResult replaySubcontract(
            ProductionPlanningPackage planningPackage) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT application.id,
                                       application.bill_no,
                                       COUNT(item.id)
                                FROM production_planning_package_documents doc
                                JOIN subcontract_applications application
                                  ON application.id = doc.document_id
                                 AND application.is_deleted = FALSE
                                LEFT JOIN subcontract_application_items item
                                  ON item.application_id = application.id
                                 AND item.is_deleted = FALSE
                                WHERE doc.package_id = :packageId
                                  AND doc.document_type =
                                      'SUBCONTRACT_APPLICATION'
                                GROUP BY application.id,
                                         application.bill_no,
                                         doc.created_at
                                ORDER BY doc.created_at, application.id
                                LIMIT 1
                                """)
                        .setParameter(
                                "packageId", planningPackage.getId()));
        if (rows.isEmpty()) {
            return null;
        }
        return new MrpGenerateResult(
                (UUID) rows.getFirst()[0],
                (String) rows.getFirst()[1],
                ((Number) rows.getFirst()[2]).intValue(),
                List.of());
    }

    private Map<CompleteKitAllocator.MaterialKey, String> authoritativeRoutes(
            GeneratePlanningPackageRequest request,
            ProductionExecutionPlanningService.Snapshot snapshot) {
        Map<CompleteKitAllocator.MaterialKey, String> result =
                new LinkedHashMap<>();
        snapshot.productLines().stream()
                .flatMap(line -> line.materials().stream())
                .forEach(material -> {
                    CompleteKitAllocator.MaterialKey key =
                            new CompleteKitAllocator.MaterialKey(
                                    material.goodsId(), material.colorId());
                    String previous = result.putIfAbsent(
                            key, material.supplyRoute());
                    if (previous != null
                            && !previous.equals(material.supplyRoute())) {
                        throw conflict(
                                "The same material dimension has conflicting authoritative supply routes");
                    }
                });
        if (request.getRoutes() == null) {
            return result;
        }
        for (GeneratePlanningPackageRequest.MaterialRoute route
                : request.getRoutes()) {
            CompleteKitAllocator.MaterialKey key =
                    new CompleteKitAllocator.MaterialKey(
                            route.getGoodsId(), route.getColorId());
            if (!result.containsKey(key)) {
                throw validation(
                        "Supply route does not belong to the current BOM");
            }
            String requested = route.getSupplyRoute() == null
                    ? ""
                    : route.getSupplyRoute()
                            .strip()
                            .toUpperCase(Locale.ROOT);
            if (!ProductionMaterialDemand.ROUTE_BUY.equals(requested)
                    && !ProductionMaterialDemand.ROUTE_SUBCONTRACT.equals(
                            requested)) {
                throw validation(
                        "Supply route must be BUY or SUBCONTRACT");
            }
            if (!result.get(key).equals(requested)) {
                throw conflict(
                        "Supply route conflicts with the material master");
            }
        }
        return result;
    }

    private Map<CompleteKitAllocator.MaterialKey, String> routes(
            GeneratePlanningPackageRequest request,
            ProductionExecutionPlanningService.Snapshot snapshot) {
        Map<CompleteKitAllocator.MaterialKey, String> result =
                new LinkedHashMap<>();
        snapshot.productLines().stream()
                .flatMap(line -> line.materials().stream())
                .forEach(material -> result.put(
                        new CompleteKitAllocator.MaterialKey(
                                material.goodsId(), material.colorId()),
                        ProductionMaterialDemand.ROUTE_BUY));
        if (request.getRoutes() == null) return result;
        for (GeneratePlanningPackageRequest.MaterialRoute route
                : request.getRoutes()) {
            CompleteKitAllocator.MaterialKey key =
                    new CompleteKitAllocator.MaterialKey(
                            route.getGoodsId(), route.getColorId());
            if (!result.containsKey(key)) {
                throw validation("供给路线不属于当前 BOM 物料");
            }
            if (!ProductionMaterialDemand.ROUTE_BUY.equals(
                    route.getSupplyRoute())) {
                throw conflict(
                        "委外/自制供给尚未接通可追溯申请与挂接，禁止确认");
            }
            result.put(key, ProductionMaterialDemand.ROUTE_BUY);
        }
        return result;
    }

    private void validateRequest(GeneratePlanningPackageRequest request) {
        if (request == null
                || request.getWarehouseId() == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getPreviewFingerprint() == null
                || !request.getPreviewFingerprint()
                        .matches("(?i)[0-9a-f]{64}")) {
            throw validation("计划包缺少仓库、幂等键或有效预览指纹");
        }
        if (request.getItems() != null && !request.getItems().isEmpty()) {
            throw conflict(
                    "items 是旧自制子计划字段，不能用于成品执行分段");
        }
        long warehouse = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM warehouses
                        WHERE id = :id AND is_deleted = FALSE
                        """)
                .setParameter("id", request.getWarehouseId())
                .getSingleResult()).longValue();
        if (warehouse != 1) {
            throw new ApiException(
                    ErrorCode.NOT_FOUND, "目标仓库不存在或已停用");
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
            throw new ApiException(
                    ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        Object[] row = rows.getFirst();
        if (((Number) row[2]).shortValue() == -1
                || Boolean.TRUE.equals(row[4])
                || Boolean.TRUE.equals(row[5])) {
            throw conflict("终态生产计划不能生成执行分段");
        }
        return new PlanHeader(
                (String) row[0], date(row[1]));
    }

    private void requireNoActiveLegacyPackage(UUID planId) {
        Object value = em.createNativeQuery("""
                        SELECT EXISTS (
                            SELECT 1
                            FROM production_planning_packages package
                            WHERE package.plan_id = :planId
                              AND package.execution_model_version = 0
                              AND package.status = 'CONFIRMED'
                              AND package.is_deleted = FALSE
                        )
                        """)
                .setParameter("planId", planId)
                .getSingleResult();
        if (Boolean.TRUE.equals(value)) {
            requireNoLegacyExecutionFacts(new LegacyExecutionFacts(
                    false, false, false, false, true));
        }
    }

    private LegacyExecutionFacts loadLegacyExecutionFacts(
            UUID planId,
            UUID currentPackageId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT
                                  EXISTS (
                                    SELECT 1
                                    FROM production_plan_items item
                                    WHERE item.plan_id = :planId
                                      AND item.is_deleted = FALSE
                                      AND (
                                        COALESCE(item.fqty, 0) > 0
                                        OR COALESCE(item.iqty, 0) > 0
                                      )
                                  ),
                                  EXISTS (
                                    SELECT 1
                                    FROM mrp_generations link
                                    JOIN purchase_requests request
                                      ON request.id = link.request_id
                                    WHERE link.plan_id = :planId
                                      AND link.is_deleted = FALSE
                                      AND request.is_deleted = FALSE
                                      AND request.status <> -1
                                  ),
                                  EXISTS (
                                    SELECT 1
                                    FROM plan_draw_links link
                                    JOIN stock_documents draw
                                      ON draw.id = link.draw_id
                                    WHERE link.plan_id = :planId
                                      AND link.is_deleted = FALSE
                                      AND draw.doc_type = 'DRAW'
                                      AND draw.is_deleted = FALSE
                                      AND draw.status <> -1
                                  ),
                                  EXISTS (
                                    SELECT 1
                                    FROM subplan_links link
                                    JOIN production_plans subplan
                                      ON subplan.id = link.subplan_id
                                    WHERE link.plan_id = :planId
                                      AND link.is_deleted = FALSE
                                      AND subplan.is_deleted = FALSE
                                      AND subplan.status <> -1
                                  ),
                                  EXISTS (
                                    SELECT 1
                                    FROM production_planning_packages package
                                    WHERE package.plan_id = :planId
                                      AND package.id <> :currentPackageId
                                      AND package.execution_model_version = 0
                                      AND package.status = 'CONFIRMED'
                                      AND package.is_deleted = FALSE
                                  )
                                """)
                        .setParameter("planId", planId)
                        .setParameter(
                                "currentPackageId", currentPackageId));
        Object[] row = rows.getFirst();
        return new LegacyExecutionFacts(
                Boolean.TRUE.equals(row[0]),
                Boolean.TRUE.equals(row[1]),
                Boolean.TRUE.equals(row[2]),
                Boolean.TRUE.equals(row[3]),
                Boolean.TRUE.equals(row[4]));
    }

    static void requireNoLegacyExecutionFacts(
            LegacyExecutionFacts facts) {
        if (facts == null || !facts.any()) {
            return;
        }
        throw conflict(
                "该生产计划仍有旧执行事实或旧版计划包；请先完成/反向旧链，或新建生产计划后再生成执行子计划");
    }

    private static String requestHash(
            GeneratePlanningPackageRequest request) {
        List<String> parts = new ArrayList<>();
        parts.add("WAREHOUSE|" + request.getWarehouseId());
        parts.add("PURCHASE|" + request.isGeneratePurchaseRequest());
        if (request.getRoutes() != null) {
            request.getRoutes().forEach(route -> parts.add(String.join("|",
                    "ROUTE",
                    Objects.toString(route.getGoodsId(), ""),
                    Objects.toString(route.getColorId(), ""),
                    Objects.toString(route.getSupplyRoute(), ""))));
        }
        if (request.getSegments() != null) {
            request.getSegments().forEach(segment -> parts.add(String.join("|",
                    "SEGMENT",
                    Objects.toString(segment.getClientSegmentKey(), ""),
                    Objects.toString(segment.getSourcePlanItemId(), ""),
                    Objects.toString(segment.getRequestedStatus(), ""),
                    decimalText(segment.getPlannedQty()),
                    Objects.toString(
                            segment.getWorkshopDepartmentId(), ""),
                    Objects.toString(segment.getTeamDepartmentId(), ""),
                    Objects.toString(
                            segment.getResponsibleEmployeeId(), ""),
                    Objects.toString(segment.getPlanBeginDate(), ""),
                    Objects.toString(segment.getPlanEndDate(), ""),
                    Objects.toString(segment.getBomFingerprint(), ""))));
        }
        return PlanningPackageFingerprint.sha256(parts);
    }

    private static String segmentCode(
            String planNo, UUID packageId, int segmentNo) {
        String prefix = planNo == null || planNo.isBlank()
                ? "PLAN" : planNo.strip();
        String value = prefix + "-E-"
                + packageId.toString().substring(0, 8)
                + "-" + String.format("%03d", segmentNo);
        return value.substring(0, Math.min(value.length(), 80));
    }

    private static BigDecimal decimal(Object value) {
        return value == null
                ? BigDecimal.ZERO
                : new BigDecimal(value.toString());
    }

    private static String decimalText(BigDecimal value) {
        return value == null
                ? "0"
                : value.stripTrailingZeros().toPlainString();
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate localDate) return localDate;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record PlanHeader(String billNo, LocalDate deliveryDate) {
    }

    private record SegmentDraft(
            ProductionExecutionSegment segment,
            CompleteKitAllocator.SegmentAllocation proposal) {
    }

    private static final class SalesLinkSlice {
        private final UUID linkId;
        private final UUID orderItemId;
        private BigDecimal remaining;

        private SalesLinkSlice(
                UUID linkId, UUID orderItemId, BigDecimal remaining) {
            this.linkId = linkId;
            this.orderItemId = orderItemId;
            this.remaining = remaining;
        }

        UUID linkId() { return linkId; }
        UUID orderItemId() { return orderItemId; }
        BigDecimal remaining() { return remaining; }
        void consume(BigDecimal quantity) {
            remaining = remaining.subtract(quantity);
        }
    }

    record LegacyExecutionFacts(
            boolean reportedOrInbounded,
            boolean activeMrpGeneration,
            boolean activeDraw,
            boolean activeSubplan,
            boolean activeModelZeroPackage) {

        boolean any() {
            return reportedOrInbounded
                    || activeMrpGeneration
                    || activeDraw
                    || activeSubplan
                    || activeModelZeroPackage;
        }
    }

    private record DemandMaterialKey(
            UUID executionSegmentId,
            UUID goodsId,
            UUID colorId) {
    }
}
