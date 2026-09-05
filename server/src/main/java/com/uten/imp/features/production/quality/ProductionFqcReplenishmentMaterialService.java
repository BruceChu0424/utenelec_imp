package com.uten.imp.features.production.quality;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService;
import com.uten.imp.features.production.mrp.CompleteKitAllocator;
import com.uten.imp.features.production.fulfillment.PlanningPackageFingerprint;
import com.uten.imp.features.production.mrp.ProductionExecutionPlanningService;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Planner-owned physical material closure for SCRAP/REJECT replacement work.
 *
 * <p>The cycle reuses the original confirmed package and plan, but persists
 * independent material demands with no execution-segment id. This lets a
 * shortage remain an honest durable task while the original segment is already
 * IN_PROGRESS. Only a fully reserved DRAW, actually issued by warehouse and
 * reconciled to FULFILLED demands, opens the recovery authorization.</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFqcReplenishmentMaterialService {

    private static final String VIEW = "production_fqc_replenishment:view";
    private static final String CONFIRM = "production_fqc_replenishment:confirm";

    private final EntityManager em;
    private final ProductionExecutionPlanningService planning;
    private final ProductionMaterialAllocationFacade stockAllocation;
    private final ProductionFulfillmentLedgerService ledger;
    private final StockDocumentRepository documentRepository;
    private final StockDocumentItemRepository itemRepository;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionDocumentAccessPolicy productionAccess;
    private final ChainNoticeService chainNotice;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')")
    public PageResponse<MaterialTaskView> list(
            int requestedPage, int requestedSize) {
        PageRequest pageable = Pageables.of(requestedPage, requestedSize);
        int page = pageable.getPageNumber() + 1;
        int size = pageable.getPageSize();
        var scope = productionAccess.nativeReadScope(
                "report.maker_id", "fqcMaterialOwners", VIEW);
        String sql = taskSql(scope.predicate()
                + " AND auth_cancellation.id IS NULL");
        var countQuery = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + sql + ") fqc_material_tasks");
        scope.bind(countQuery);
        long total = ((Number) countQuery.getSingleResult()).longValue();
        var query = em.createNativeQuery(sql
                + " ORDER BY task.created_at, task.id OFFSET :offset LIMIT :limit");
        scope.bind(query);
        query.setParameter("offset", pageable.getOffset());
        query.setParameter("limit", size);
        List<MaterialTaskView> items = NativeQueryResults.objectArrayRows(query).stream()
                .map(ProductionFqcReplenishmentMaterialService::taskView)
                .toList();
        int totalPages = total == 0 ? 0 : (int) ((total + size - 1) / size);
        return new PageResponse<>(items, page, size, total, totalPages);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')")
    public long countPending() {
        var scope = productionAccess.nativeReadScope(
                "report.maker_id", "fqcMaterialCountOwners", VIEW);
        String sql = taskSql(scope.predicate()
                + " AND auth_cancellation.id IS NULL");
        var query = em.createNativeQuery("""
                SELECT COUNT(*) FROM (
                """ + sql + """
                ) fqc_material_tasks
                WHERE task_status NOT IN ('READY','CANCELLED')
                """);
        scope.bind(query);
        return ((Number) query.getSingleResult()).longValue();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('production_fqc_replenishment:view')")
    public MaterialTaskView detail(UUID authorizationId) {
        MaterialTaskView task = detailInternal(authorizationId);
        productionAccess.requireReadable(
                task.reportMakerId(), "FQC 补产物料任务不存在", VIEW);
        return task;
    }

    /**
     * First call freezes the current BOM into exact demands. Later calls with a
     * new key retry only the unreserved balance after stock has been replenished.
     */
    @Transactional
    @PreAuthorize("hasAuthority('production_fqc_replenishment:confirm')")
    public MaterialTaskView confirm(
            UUID authorizationId, ConfirmRequest request) {
        tx.bind();
        String key = normalizeKey(request == null ? null : request.idempotencyKey());
        String requestHash = CanonicalFingerprint.sha256(List.of(
                "FQC-REPLENISHMENT-MATERIAL-CONFIRM-V1",
                Objects.toString(authorizationId, "")));

        LockedAuthorization locked = lockAuthorization(authorizationId);
        productionAccess.requireScopedOperationWritable(
                locked.reportMakerId(), "无权确认此 FQC 补产物料任务", CONFIRM);
        requirePlannerAnalysis(locked);

        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT attempt.request_hash
                        FROM production_fqc_replenishment_attempts attempt
                        WHERE attempt.idempotency_key = :key
                        """).setParameter("key", key));
        if (!replay.isEmpty()) {
            if (!Objects.equals(replay.getFirst()[0], requestHash)) {
                throw conflict("相同幂等键已用于另一补产物料确认请求");
            }
            return detailInternal(authorizationId);
        }

        UUID cycleId = activeCycle(authorizationId);
        if (cycleId == null) {
            cycleId = createCycleAndDemands(locked, key, requestHash);
        }
        attemptAllocation(locked, cycleId, key, requestHash);
        return detailInternal(authorizationId);
    }

    /**
     * Called from the V414 source-report reversal before the authorization
     * cancellation fact is appended. Unissued reservations are released and an
     * unissued DRAW becomes reversed history; physically issued material must
     * first follow reverse-issue / good-return.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeAuthorizationCancellation(UUID authorizationId) {
        if (authorizationId == null) return;
        List<UUID> cycleIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT cycle.id
                        FROM production_fqc_replenishment_cycles cycle
                        WHERE cycle.authorization_id = :authorizationId
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_fqc_replenishment_cycle_cancellations cancellation
                              WHERE cancellation.cycle_id = cycle.id)
                        ORDER BY cycle.generation, cycle.id
                        FOR UPDATE
                        """, UUID.class).setParameter(
                        "authorizationId", authorizationId), UUID.class);
        UUID actorId = currentUser.requireId();
        for (UUID cycleId : cycleIds) {
            List<UUID> demandIds = recoveryDemandIds(cycleId);
            Number consumed = (Number) em.createNativeQuery("""
                            SELECT COALESCE(SUM(reservation.consumed_qty), 0)
                            FROM stock_reservations reservation
                            WHERE reservation.demand_id IN (:demandIds)
                              AND reservation.is_deleted = FALSE
                            """)
                    .setParameter("demandIds", demandIds)
                    .getSingleResult();
            if (decimal(consumed).signum() > 0) {
                throw conflict("补产物料已实发，请先取消出库或按原领料行退料");
            }
            stockAllocation.releaseByDemands(
                    demandIds, "FQC补产授权取消释放未领物料");
            em.createNativeQuery("""
                            UPDATE production_material_demands
                            SET released_qty = required_qty,
                                status = 'REVERSED',
                                lock_version = lock_version + 1,
                                updated_at = now(), updated_by = :actorId
                            WHERE id IN (:demandIds)
                              AND is_deleted = FALSE
                            """)
                    .setParameter("actorId", actorId)
                    .setParameter("demandIds", demandIds)
                    .executeUpdate();
            reverseUnissuedDraw(cycleId, actorId);
            revokeActiveReady(cycleId, "AUTH_CANCELLED", actorId);
            em.createNativeQuery("""
                            INSERT INTO production_fqc_replenishment_cycle_cancellations(
                                id, cycle_id, authorization_id,
                                reason_code, created_by)
                            VALUES (
                                gen_random_uuid(), :cycleId, :authorizationId,
                                'AUTH_CANCELLED', :actorId)
                            ON CONFLICT (cycle_id) DO NOTHING
                            """)
                    .setParameter("cycleId", cycleId)
                    .setParameter("authorizationId", authorizationId)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
        }
    }

    @Transactional(readOnly = true, propagation = Propagation.MANDATORY)
    public boolean isMaterialReady(UUID authorizationId) {
        if (authorizationId == null) return false;
        return Boolean.TRUE.equals(em.createNativeQuery("""
                        SELECT fn_fqc_replenishment_material_ready(
                            CAST(:authorizationId AS uuid))
                        """)
                .setParameter("authorizationId", authorizationId)
                .getSingleResult());
    }

    private UUID createCycleAndDemands(
            LockedAuthorization authorization,
            String key,
            String requestHash) {
        ProductionExecutionPlanningService.Snapshot snapshot =
                planning.lockedSnapshot(
                        authorization.planId(),
                        authorization.warehouseId(),
                        Map.of());
        CompleteKitAllocator.ProductLine productLine = snapshot.productLines()
                .stream()
                .filter(line -> line.sourcePlanItemId()
                        .equals(authorization.sourcePlanItemId()))
                .findFirst()
                .orElseThrow(() -> conflict(
                        "原生产计划行没有可冻结的当前 BOM"));
        if (!Objects.equals(productLine.productGoodsId(), authorization.goodsId())
                || !Objects.equals(productLine.productColorId(), authorization.colorId())
                || !Objects.equals(productLine.productUnitId(), authorization.unitId())
                || productLine.productUnitRate()
                        .compareTo(authorization.unitRate()) != 0) {
            throw conflict("补产授权与当前生产计划产品身份或单位不一致");
        }
        CompleteKitAllocator.Allocation allocation =
                new CompleteKitAllocator().allocateRequested(
                        List.of(new CompleteKitAllocator.RequestedSegment(
                                "FQC-RECOVERY-" + authorization.authorizationId(),
                                productLine,
                                "WAITING",
                                authorization.authorizedQty(),
                                false)),
                        snapshot.availability());
        if (allocation.segments().size() != 1
                || allocation.segments().getFirst().materials().isEmpty()) {
            throw conflict("SCRAP/REJECT 补产没有可证明的 BOM 物料需求，禁止假定可生产");
        }
        Number generationValue = (Number) em.createNativeQuery(
                        "SELECT COALESCE(MAX(generation), 0) + 1 "
                                + "FROM production_fqc_replenishment_cycles "
                                + "WHERE authorization_id = :authorizationId")
                .setParameter(
                        "authorizationId", authorization.authorizationId())
                .getSingleResult();
        int generation = generationValue.intValue();
        UUID cycleId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_replenishment_cycles(
                            id, replenishment_task_id, authorization_id,
                            generation, package_id, plan_id,
                            source_plan_item_id, source_execution_segment_id,
                            warehouse_id, product_qty,
                            planning_snapshot_fingerprint, bom_fingerprint,
                            initial_idempotency_key, request_hash, created_by)
                        VALUES (
                            :id, :taskId, :authorizationId,
                            :generation, :packageId, :planId,
                            :planItemId, :segmentId,
                            :warehouseId, :productQty,
                            :snapshotFingerprint, :bomFingerprint,
                            :key, :requestHash, :actorId)
                        """)
                .setParameter("id", cycleId)
                .setParameter("taskId", authorization.taskId())
                .setParameter("authorizationId", authorization.authorizationId())
                .setParameter("generation", generation)
                .setParameter("packageId", authorization.packageId())
                .setParameter("planId", authorization.planId())
                .setParameter("planItemId", authorization.sourcePlanItemId())
                .setParameter("segmentId", authorization.executionSegmentId())
                .setParameter("warehouseId", authorization.warehouseId())
                .setParameter("productQty", authorization.authorizedQty())
                .setParameter("snapshotFingerprint", snapshot.fingerprint())
                .setParameter("bomFingerprint", productLine.bomFingerprint())
                .setParameter("key", key)
                .setParameter("requestHash", requestHash)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();

        int sequence = 0;
        for (CompleteKitAllocator.MaterialAllocation material
                : allocation.segments().getFirst().materials().stream()
                .sorted(Comparator
                        .comparing(CompleteKitAllocator.MaterialAllocation::goodsId)
                        .thenComparing(value -> Objects.toString(
                                value.colorId(), "")))
                .toList()) {
            sequence++;
            String fingerprint = PlanningPackageFingerprint.sha256(List.of(
                    "FQC-RECOVERY-MATERIAL-DEMAND-V1",
                    authorization.authorizationId().toString(),
                    cycleId.toString(), productLine.bomFingerprint(),
                    material.goodsId().toString(),
                    Objects.toString(material.colorId(), ""),
                    material.unitId().toString(),
                    material.requiredQty().stripTrailingZeros().toPlainString(),
                    authorization.authorizedQty()
                            .stripTrailingZeros().toPlainString(),
                    material.supplyRoute()));
            UUID demandId = UUID.randomUUID();
            em.createNativeQuery("""
                            INSERT INTO production_material_demands(
                                id, package_id, plan_id, execution_segment_id,
                                fqc_recovery_authorization_id,
                                fqc_replenishment_cycle_id,
                                source_plan_item_id, warehouse_id,
                                goods_id, color_id, unit_id,
                                required_qty, per_product_qty,
                                requirement_mode, required_for_product_qty,
                                requirement_fingerprint, released_qty,
                                need_date, supply_route, status,
                                idempotency_key, lock_version,
                                created_by, updated_by)
                            VALUES (
                                :id, :packageId, :planId, NULL,
                                :authorizationId, :cycleId,
                                :planItemId, :warehouseId,
                                :goodsId, :colorId, :unitId,
                                :requiredQty, :perProductQty,
                                'EXACT_SNAPSHOT', :productQty,
                                :fingerprint, 0,
                                :needDate, :route, 'OPEN',
                                :demandKey, 0, :actorId, :actorId)
                            """)
                    .setParameter("id", demandId)
                    .setParameter("packageId", authorization.packageId())
                    .setParameter("planId", authorization.planId())
                    .setParameter("authorizationId", authorization.authorizationId())
                    .setParameter("cycleId", cycleId)
                    .setParameter("planItemId", authorization.sourcePlanItemId())
                    .setParameter("warehouseId", authorization.warehouseId())
                    .setParameter("goodsId", material.goodsId())
                    .setParameter("colorId", material.colorId())
                    .setParameter("unitId", material.unitId())
                    .setParameter("requiredQty", material.requiredQty())
                    .setParameter("perProductQty", material.perProductQty())
                    .setParameter("productQty", authorization.authorizedQty())
                    .setParameter("fingerprint", fingerprint)
                    .setParameter("needDate", BusinessTime.today())
                    .setParameter("route", material.supplyRoute())
                    .setParameter("demandKey",
                            "FQC-MATERIAL:" + cycleId + ":" + sequence)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        return cycleId;
    }

    private void attemptAllocation(
            LockedAuthorization authorization,
            UUID cycleId,
            String key,
            String requestHash) {
        UUID attemptId = UUID.randomUUID();
        List<DemandRow> demands = demandRows(cycleId, true);
        List<ProductionMaterialAllocationFacade.AllocationRequest> requests =
                new ArrayList<>();
        for (DemandRow demand : demands) {
            BigDecimal remaining = demand.requiredQty()
                    .subtract(demand.committedQty()).max(BigDecimal.ZERO);
            if (remaining.signum() > 0) {
                requests.add(new ProductionMaterialAllocationFacade
                        .AllocationRequest(
                        authorization.packageId(), demand.id(),
                        demand.goodsId(), demand.colorId(),
                        authorization.warehouseId(), remaining,
                        "FQC-MATERIAL-ALLOCATE:" + attemptId + ":" + demand.id(),
                        currentUser.requireId()));
            }
        }
        stockAllocation.allocate(requests);
        ledger.refreshDemandStatuses(demands.stream()
                .map(DemandRow::id).toList());
        List<DemandRow> refreshed = demandRows(cycleId, true);
        List<DemandRow> shortages = refreshed.stream()
                .filter(demand -> demand.committedQty()
                        .compareTo(demand.requiredQty()) < 0)
                .toList();
        String outcome = shortages.isEmpty() ? "DRAW_PENDING" : "BLOCKED";
        em.createNativeQuery("""
                        INSERT INTO production_fqc_replenishment_attempts(
                            id, cycle_id, authorization_id,
                            idempotency_key, request_hash,
                            outcome, created_by)
                        VALUES (
                            :id, :cycleId, :authorizationId,
                            :key, :requestHash, :outcome, :actorId)
                        """)
                .setParameter("id", attemptId)
                .setParameter("cycleId", cycleId)
                .setParameter("authorizationId", authorization.authorizationId())
                .setParameter("key", key)
                .setParameter("requestHash", requestHash)
                .setParameter("outcome", outcome)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        for (DemandRow shortage : shortages) {
            BigDecimal missing = shortage.requiredQty()
                    .subtract(shortage.committedQty());
            String reason = switch (shortage.supplyRoute()) {
                case "BUY" -> "外购物料库存不足；采购到货入库后使用新幂等键重试";
                case "MAKE" -> "自制物料库存不足；须先完成独立上游生产并入库，当前不自动伪造子计划";
                case "SUBCONTRACT" -> "委外物料库存不足；须先完成独立委外供应并入库";
                default -> "物料库存不足";
            };
            em.createNativeQuery("""
                            INSERT INTO production_fqc_replenishment_supply_gaps(
                                id, attempt_id, demand_id, supply_route,
                                required_qty, allocated_qty, shortage_qty,
                                blocked_reason, created_by)
                            VALUES (
                                gen_random_uuid(), :attemptId, :demandId, :route,
                                :requiredQty, :allocatedQty, :shortageQty,
                                :reason, :actorId)
                            """)
                    .setParameter("attemptId", attemptId)
                    .setParameter("demandId", shortage.id())
                    .setParameter("route", shortage.supplyRoute())
                    .setParameter("requiredQty", shortage.requiredQty())
                    .setParameter("allocatedQty", shortage.committedQty())
                    .setParameter("shortageQty", missing)
                    .setParameter("reason", reason)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        if (shortages.isEmpty() && drawId(cycleId) == null) {
            createDraw(authorization, cycleId, refreshed);
        }
    }

    private void createDraw(
            LockedAuthorization authorization,
            UUID cycleId,
            List<DemandRow> demands) {
        StockDocument document = new StockDocument();
        document.setDocType("DRAW");
        document.setBillNo(docNumberService.nextNumber(DocNumberPrefix.STOCK_DRAW));
        document.setBillDate(BusinessTime.today());
        document.setWarehouseId(authorization.warehouseId());
        document.setPlanNo(authorization.planNo());
        document.setSourceDocNo(authorization.sourceReportNo());
        document.setRemark("FQC " + authorization.dispositionCode()
                + " 补产物料 · 授权 " + authorization.authorizationId());
        document.setDepartmentId(authorization.workshopDepartmentId());
        document.setWorkerId(authorization.responsibleEmployeeId());
        document.setMakerId(currentUser.requireEmployeeId());
        document.setStatus((short) 0);
        documentRepository.saveAndFlush(document);

        Map<UUID, StockGoodsSnapshot> snapshots = StockGoodsSnapshot.fromMaster(
                em, demands.stream().map(DemandRow::goodsId).toList(),
                StockGoodsSnapshot.MASTER_AT_SAVE);
        int lineNo = 0;
        for (DemandRow demand : demands.stream()
                .sorted(Comparator.comparing(DemandRow::goodsId)
                        .thenComparing(value -> Objects.toString(
                                value.colorId(), "")))
                .toList()) {
            StockDocumentItem item = new StockDocumentItem();
            item.setDocId(document.getId());
            item.setBillType("DRAW");
            item.setBillNo(document.getBillNo());
            item.setBillDate(document.getBillDate());
            item.setLineNo(++lineNo);
            item.setGoodsId(demand.goodsId());
            StockGoodsSnapshot.require(
                            snapshots, demand.goodsId(), "FQC补产领料明细")
                    .applyTo(item, null);
            item.setColorId(demand.colorId());
            item.setUnitId(demand.unitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(demand.requiredQty());
            item.setBaseQty(demand.requiredQty());
            item.setSourceDocNo(authorization.sourceReportNo());
            item.setRemark("FQC补产需求 " + demand.id());
            itemRepository.saveAndFlush(item);
            em.createNativeQuery("""
                            INSERT INTO production_planning_package_document_items(
                                package_id, demand_id, document_type,
                                document_id, document_item_id, created_by)
                            VALUES (
                                :packageId, :demandId, 'DRAW',
                                :documentId, :itemId, :actorId)
                            """)
                    .setParameter("packageId", authorization.packageId())
                    .setParameter("demandId", demand.id())
                    .setParameter("documentId", document.getId())
                    .setParameter("itemId", item.getId())
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        ledger.recordDocument(
                authorization.packageId(), null, "DRAW",
                document.getId(), document.getBillNo(), currentUser.requireId());
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(plan_id, draw_id, created_by)
                        VALUES (:planId, :drawId, :actorId)
                        """)
                .setParameter("planId", authorization.planId())
                .setParameter("drawId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        em.createNativeQuery("""
                        INSERT INTO production_fqc_replenishment_draw_links(
                            cycle_id, authorization_id,
                            stock_document_id, created_by)
                        VALUES (:cycleId, :authorizationId, :drawId, :actorId)
                        """)
                .setParameter("cycleId", cycleId)
                .setParameter("authorizationId", authorization.authorizationId())
                .setParameter("drawId", document.getId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        chainNotice.notifyProductionDrawPending(document.getId());
    }

    private LockedAuthorization lockAuthorization(UUID authorizationId) {
        if (authorizationId == null) throw notFound("FQC 补产物料任务不存在");
        List<UUID> identity = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT recovery_auth.execution_segment_id
                        FROM production_fqc_recovery_authorizations recovery_auth
                        WHERE recovery_auth.id = :authorizationId
                        """, UUID.class)
                        .setParameter("authorizationId", authorizationId),
                UUID.class);
        if (identity.size() != 1) throw notFound("FQC 补产物料任务不存在");
        UUID segmentId = identity.getFirst();
        em.createNativeQuery("""
                        SELECT id FROM production_execution_segments
                        WHERE id = :segmentId AND is_deleted = FALSE
                        FOR UPDATE
                        """).setParameter("segmentId", segmentId)
                .getSingleResult();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT task.id, recovery_auth.id,
                               recovery_auth.disposition_code,
                               recovery_auth.authorized_qty,
                               recovery_auth.warehouse_id,
                               recovery_auth.goods_id, recovery_auth.color_id,
                               recovery_auth.unit_id, recovery_auth.unit_rate,
                               recovery_auth.source_plan_item_id,
                               recovery_auth.execution_segment_id,
                               segment.package_id, segment.plan_id,
                               segment.workshop_department_id,
                               segment.responsible_employee_id,
                               plan.maker_id, plan.bill_no,
                               report.bill_no
                        FROM production_fqc_replenishment_tasks task
                        JOIN production_fqc_recovery_authorizations recovery_auth
                          ON recovery_auth.id = task.authorization_id
                        JOIN production_execution_segments segment
                          ON segment.id = recovery_auth.execution_segment_id
                         AND segment.is_deleted = FALSE
                        JOIN production_plans plan ON plan.id = segment.plan_id
                         AND plan.is_deleted = FALSE
                        JOIN production_daily_report_items source_item
                          ON source_item.id = recovery_auth.source_report_item_id
                        JOIN production_daily_reports report
                          ON report.id = source_item.report_id
                        JOIN v_production_fqc_recovery_balance balance
                          ON balance.authorization_id = recovery_auth.id
                        WHERE recovery_auth.id = :authorizationId
                          AND recovery_auth.disposition_code IN ('SCRAP','REJECT')
                          AND balance.cancelled = FALSE
                        FOR UPDATE OF task, recovery_auth, segment, plan
                        """).setParameter("authorizationId", authorizationId));
        if (rows.size() != 1) throw notFound("FQC 补产物料任务不存在");
        Object[] row = rows.getFirst();
        return new LockedAuthorization(
                (UUID) row[0], (UUID) row[1], (String) row[2],
                decimal(row[3]), (UUID) row[4], (UUID) row[5],
                (UUID) row[6], (UUID) row[7], decimal(row[8]),
                (UUID) row[9], (UUID) row[10], (UUID) row[11],
                (UUID) row[12], (UUID) row[13], (UUID) row[14],
                (UUID) row[15], (String) row[16], (String) row[17]);
    }

    private void requirePlannerAnalysis(LockedAuthorization authorization) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_fqc_replenishment_analysis_links link
                        WHERE link.replenishment_task_id = :taskId
                          AND link.authorization_id = :authorizationId
                        """)
                .setParameter("taskId", authorization.taskId())
                .setParameter("authorizationId", authorization.authorizationId())
                .getSingleResult();
        if (count.longValue() != 1) {
            throw conflict("计划员须先登记该 FQC 补产物料分析任务");
        }
    }

    private UUID activeCycle(UUID authorizationId) {
        List<UUID> rows = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT cycle.id
                        FROM production_fqc_replenishment_cycles cycle
                        WHERE cycle.authorization_id = :authorizationId
                          AND NOT EXISTS (
                              SELECT 1 FROM production_fqc_replenishment_cycle_cancellations c
                              WHERE c.cycle_id = cycle.id)
                        ORDER BY cycle.generation DESC, cycle.id DESC
                        LIMIT 1 FOR UPDATE
                        """, UUID.class).setParameter(
                        "authorizationId", authorizationId), UUID.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private List<DemandRow> demandRows(UUID cycleId, boolean lock) {
        String suffix = lock ? " FOR UPDATE OF demand" : "";
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, demand.goods_id, demand.color_id,
                               demand.unit_id, demand.required_qty,
                               demand.supply_route,
                               COALESCE((
                                   SELECT SUM(reservation.qty - reservation.released_qty)
                                   FROM stock_reservations reservation
                                   WHERE reservation.demand_id = demand.id
                                     AND reservation.is_deleted = FALSE), 0)
                        FROM production_material_demands demand
                        WHERE demand.fqc_replenishment_cycle_id = :cycleId
                          AND demand.is_deleted = FALSE
                        ORDER BY demand.goods_id, demand.color_id NULLS FIRST,
                                 demand.id
                        """ + suffix).setParameter("cycleId", cycleId))
                .stream().map(row -> new DemandRow(
                        (UUID) row[0], (UUID) row[1], (UUID) row[2],
                        (UUID) row[3], decimal(row[4]), (String) row[5],
                        decimal(row[6]))).toList();
    }

    private List<UUID> recoveryDemandIds(UUID cycleId) {
        List<UUID> ids = demandRows(cycleId, true).stream()
                .map(DemandRow::id).toList();
        if (ids.isEmpty()) throw conflict("FQC 补产周期缺少正式物料需求");
        return ids;
    }

    private UUID drawId(UUID cycleId) {
        List<UUID> rows = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT stock_document_id
                        FROM production_fqc_replenishment_draw_links
                        WHERE cycle_id = :cycleId
                        """, UUID.class).setParameter("cycleId", cycleId),
                UUID.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private void reverseUnissuedDraw(UUID cycleId, UUID actorId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT document.id, document.status,
                               COALESCE(SUM(item.issued_qty), 0)
                        FROM production_fqc_replenishment_draw_links link
                        JOIN stock_documents document
                          ON document.id = link.stock_document_id
                        LEFT JOIN stock_document_items item
                          ON item.doc_id = document.id AND item.is_deleted = FALSE
                        WHERE link.cycle_id = :cycleId
                          AND document.is_deleted = FALSE
                        GROUP BY document.id, document.status
                        FOR UPDATE OF document
                        """).setParameter("cycleId", cycleId));
        if (rows.isEmpty()) return;
        UUID drawId = (UUID) rows.getFirst()[0];
        if (decimal(rows.getFirst()[2]).signum() > 0) {
            throw conflict("补产领料单已有实发数量，请先完成取消出库或退料");
        }
        em.createNativeQuery("""
                        UPDATE stock_documents
                        SET status = -1, updated_at = now(), updated_by = :actorId
                        WHERE id = :drawId AND status IN (0,1)
                        """)
                .setParameter("actorId", actorId)
                .setParameter("drawId", drawId)
                .executeUpdate();
    }

    private void revokeActiveReady(
            UUID cycleId, String reasonCode, UUID actorId) {
        em.createNativeQuery("""
                        INSERT INTO production_fqc_replenishment_ready_reversals(
                            id, ready_event_id, reason_code, created_by)
                        SELECT gen_random_uuid(), ready.id, :reason, :actorId
                        FROM production_fqc_replenishment_ready_events ready
                        WHERE ready.cycle_id = :cycleId
                          AND NOT EXISTS (
                              SELECT 1 FROM production_fqc_replenishment_ready_reversals reversal
                              WHERE reversal.ready_event_id = ready.id)
                        ON CONFLICT (ready_event_id) DO NOTHING
                        """)
                .setParameter("reason", reasonCode)
                .setParameter("actorId", actorId)
                .setParameter("cycleId", cycleId)
                .executeUpdate();
    }

    private MaterialTaskView detailInternal(UUID authorizationId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(taskSql(
                        "recovery_auth.id = :authorizationId"))
                        .setParameter("authorizationId", authorizationId));
        if (rows.size() != 1) throw notFound("FQC 补产物料任务不存在");
        return taskView(rows.getFirst());
    }

    private static String taskSql(String predicate) {
        return """
                SELECT task.id, recovery_auth.id,
                       recovery_auth.disposition_code,
                       recovery_auth.authorized_qty,
                       recovery_auth.warehouse_id,
                       recovery_auth.source_plan_item_id,
                       recovery_auth.execution_segment_id,
                       segment.plan_id, plan.bill_no,
                       report.maker_id, report.bill_no,
                       analysis.material_analysis_id,
                       cycle.id,
                       draw.stock_document_id, document.bill_no,
                       document.status, document.issue_status,
                       CASE
                         WHEN auth_cancellation.id IS NOT NULL
                              OR cancellation.id IS NOT NULL THEN 'CANCELLED'
                         WHEN ready.authorization_id IS NOT NULL THEN 'READY'
                         WHEN draw.stock_document_id IS NOT NULL THEN 'AWAITING_WAREHOUSE'
                         WHEN attempt.outcome = 'BLOCKED' THEN 'BLOCKED'
                         WHEN cycle.id IS NOT NULL THEN 'AWAITING_STOCK'
                         WHEN analysis.id IS NOT NULL THEN 'AWAITING_CONFIRMATION'
                         ELSE 'AWAITING_ANALYSIS'
                       END AS task_status,
                       gap.blocked_reason
                FROM production_fqc_replenishment_tasks task
                JOIN production_fqc_recovery_authorizations recovery_auth
                  ON recovery_auth.id = task.authorization_id
                JOIN production_execution_segments segment
                  ON segment.id = recovery_auth.execution_segment_id
                JOIN production_plans plan ON plan.id = segment.plan_id
                JOIN production_daily_report_items source_item
                  ON source_item.id = recovery_auth.source_report_item_id
                JOIN production_daily_reports report
                  ON report.id = source_item.report_id
                LEFT JOIN production_fqc_replenishment_analysis_links analysis
                  ON analysis.replenishment_task_id = task.id
                LEFT JOIN LATERAL (
                    SELECT c.* FROM production_fqc_replenishment_cycles c
                    WHERE c.authorization_id = recovery_auth.id
                    ORDER BY c.generation DESC, c.id DESC LIMIT 1
                ) cycle ON TRUE
                LEFT JOIN production_fqc_replenishment_cycle_cancellations cancellation
                  ON cancellation.cycle_id = cycle.id
                LEFT JOIN production_fqc_recovery_cancellation_events auth_cancellation
                  ON auth_cancellation.authorization_id = recovery_auth.id
                LEFT JOIN production_fqc_replenishment_draw_links draw
                  ON draw.cycle_id = cycle.id
                LEFT JOIN stock_documents document
                  ON document.id = draw.stock_document_id
                LEFT JOIN v_production_fqc_replenishment_material_ready ready
                  ON ready.authorization_id = recovery_auth.id
                LEFT JOIN LATERAL (
                    SELECT a.id, a.outcome
                    FROM production_fqc_replenishment_attempts a
                    WHERE a.cycle_id = cycle.id
                    ORDER BY a.created_at DESC, a.id DESC LIMIT 1
                ) attempt ON TRUE
                LEFT JOIN LATERAL (
                    SELECT string_agg(g.blocked_reason, '；' ORDER BY g.id)
                               AS blocked_reason
                    FROM production_fqc_replenishment_supply_gaps g
                    WHERE g.attempt_id = attempt.id
                ) gap ON TRUE
                WHERE %s
                """.formatted(predicate);
    }

    private static MaterialTaskView taskView(Object[] row) {
        return new MaterialTaskView(
                (UUID) row[0], (UUID) row[1], (String) row[2],
                decimal(row[3]), (UUID) row[4], (UUID) row[5],
                (UUID) row[6], (UUID) row[7], (String) row[8],
                (UUID) row[9], (String) row[10], (UUID) row[11],
                (UUID) row[12], (UUID) row[13], (String) row[14],
                row[15] == null ? null : ((Number) row[15]).shortValue(),
                row[16] == null ? null : ((Number) row[16]).shortValue(),
                (String) row[17], (String) row[18]);
    }

    private static String normalizeKey(String raw) {
        String value = raw == null ? "" : raw.strip();
        if (value.length() < 8 || value.length() > 128
                || !value.matches("[A-Za-z0-9._:-]+")) {
            throw validation("幂等键必须为 8 到 128 位字母、数字或 ._:-");
        }
        return value;
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO.setScale(4);
        return value instanceof BigDecimal number
                ? number : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException notFound(String message) {
        return new ApiException(ErrorCode.NOT_FOUND, message);
    }

    public record ConfirmRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            String idempotencyKey) {
    }

    public record MaterialTaskView(
            UUID taskId,
            UUID authorizationId,
            String dispositionCode,
            BigDecimal quantity,
            UUID warehouseId,
            UUID sourcePlanItemId,
            UUID executionSegmentId,
            UUID planId,
            String planNo,
            UUID reportMakerId,
            String sourceReportNo,
            UUID materialAnalysisId,
            UUID cycleId,
            UUID drawId,
            String drawNo,
            Short drawStatus,
            Short drawIssueStatus,
            String status,
            String blockedReason) {
    }

    private record LockedAuthorization(
            UUID taskId,
            UUID authorizationId,
            String dispositionCode,
            BigDecimal authorizedQty,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            UUID sourcePlanItemId,
            UUID executionSegmentId,
            UUID packageId,
            UUID planId,
            UUID workshopDepartmentId,
            UUID responsibleEmployeeId,
            UUID reportMakerId,
            String planNo,
            String sourceReportNo) {
    }

    private record DemandRow(
            UUID id,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requiredQty,
            String supplyRoute,
            BigDecimal committedQty) {
    }
}
